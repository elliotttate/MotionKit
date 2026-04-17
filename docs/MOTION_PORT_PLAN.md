# MotionKit Port Plan

This document turns the SpliceKit codebase into a staged Apple Motion port instead of a rename. The goal is to preserve the useful platform pieces, isolate the FCP-only assumptions, and bring over the command palette and MCP server in layers that can be validated against a live Motion process.

## What Transfers Cleanly

- The injected dylib structure in [`Sources/SpliceKit.m`](/Users/briantate/Documents/GitHub/MotionKit/Sources/SpliceKit.m)
- The JSON-RPC transport, handle system, and runtime reflection in [`Sources/SpliceKitServer.m`](/Users/briantate/Documents/GitHub/MotionKit/Sources/SpliceKitServer.m)
- The floating palette UI shell and fuzzy search UI in [`Sources/SpliceKitCommandPalette.m`](/Users/briantate/Documents/GitHub/MotionKit/Sources/SpliceKitCommandPalette.m)
- Menu walking, dialog automation, KVC helpers, and generic `call_method*` escape hatches
- The Lua embedding and log/debug infrastructure

## What Does Not Transfer Cleanly

- Anything wired to `FF*`, `PE*`, library/event/project abstractions, or the FCP timeline spine model
- FCPXML import/export workflows
- Transcript and caption pipelines that assume timeline media editing
- Montage, FlexMusic, scene-detect, and batch-export flows
- The static command registry in [`Sources/SpliceKitCommandPalette.m`](/Users/briantate/Documents/GitHub/MotionKit/Sources/SpliceKitCommandPalette.m) because it is hard-coded to FCP action ids and categories

## Motion Surface We Can Already Lean On

Local Motion 6.0 ships useful metadata we can mine immediately:

- `NSPrincipalClass = MGApplication`
- `NSDocumentClass = OZObjCDocument`
- Command metadata in `/Applications/Motion.app/Contents/Resources/NSProCommands.plist`
- Command grouping in `/Applications/Motion.app/Contents/Resources/NSProCommandGroups.plist`

Representative Motion runtime classes visible in the local app binary:

- `MGApplication`
- `MGApplicationController`
- `MGDocumentController`
- `MGMainWindowModule`
- `OZCommandsController`
- `OZCanvasModule`
- `OZLibraryModule`
- `LKCommandsController`
- `LKWindowModule`

Representative bundled command ids already exposed by Motion:

- `Play`
- `PlayfromStart`
- `Stop`
- `Markers/AddMarker`
- `Markers/DeleteMarker`
- `GoTo/NextMarker`
- `GoTo/PreviousMarker`
- `AddKeyframe`
- `3DPositionTool`
- `TextTool`
- `BezierTool`
- `Alignment/AlignLeftEdges`
- `ZoomIn`
- `ZoomOut`
- `Audio Timeline`

## Architecture Changes

### Phase 1: Host Abstraction

Create a host profile layer and move every hard-coded FCP assumption behind it.

- Product name, log path, cache path, app support path, framework bundle id
- Host app name, executable, bundle id, source app path, modded app path
- Host runtime metadata keys returned from `system.version`

Concrete target:

- `SpliceKit_handleSystemVersion` should report generic host fields first
- Build and deploy scripts should only reference Motion-specific constants through a host profile
- The original FCP server should remain in this copy as reference, but Motion-facing tooling should use `mcp/motion_server.py`

### Phase 2: Command Discovery Pipeline

Replace the static command list with a generated Motion registry.

- Use [`tools/extract_motion_surface.py`](/Users/briantate/Documents/GitHub/MotionKit/tools/extract_motion_surface.py) and [`mcp/motion_surface.py`](/Users/briantate/Documents/GitHub/MotionKit/mcp/motion_surface.py) to load Motion's command ids, selectors, and groups
- Add a runtime adapter that converts Motion command ids into `SpliceKitCommand` instances
- Keep the palette UI itself, but make the registry provider pluggable so FCP and Motion can use different command catalogs

Concrete target:

- Palette categories should come from Motion groups such as `Tools`, `Transport`, `Mark`, `GoTo`, `View`, and `Alignment`
- The first Motion palette should support search, favorites, and browse mode even before every command becomes executable

### Phase 3: Command Execution Adapters

Motion command ids are not enough by themselves; we need the dispatch path from palette action to live responder/controller call.

Primary strategy:

- Use Motion's command plist selector names as the first execution target
- Discover which live object responds to those selectors using runtime introspection on `MGApplication`, `MGMainWindowModule`, `OZCommandsController`, and `LKCommandsController`
- Fall back to menu execution for commands that are exposed in the menu bar before direct adapters exist

Concrete target:

- Build a Motion action router parallel to `SpliceKit_handleTimelineAction`, but keyed to Motion concepts
- First commands to land should be low-risk and visible:
  - playback: `Play`, `Stop`, `PlayfromStart`
  - navigation: `GoTo/*`
  - markers: `Markers/*`
  - tools: `TextTool`, `BezierTool`, `RectTool`, `ZoomTool`
  - view: `ZoomIn`, `ZoomOut`, `ShowOverlays`, `Audio Timeline`

### Phase 4: Motion Object Model Mapping

FCP's timeline spine is the wrong mental model for Motion. MotionKit needs a new semantic layer centered on:

- documents and project settings
- layers, groups, cameras, behaviors, filters, masks, text objects
- canvas selection
- keyframes and timing
- tools and inspectors

Concrete target:

- Introduce Motion-specific bridge methods for:
  - active document
  - selected layers/objects
  - current tool
  - current playhead time / work area / markers
  - adding behaviors, filters, masks, and text
  - keyframe insertion and navigation

This should live beside the generic runtime helpers instead of being squeezed into existing `timeline.*` APIs.

### Phase 5: Motion MCP Coverage

Once the execution layer exists, expand `mcp/motion_server.py` from discovery to control.

Priority order:

1. Runtime and app state
2. Menu and dialog automation
3. Playback and navigation
4. Tool switching
5. Marker and keyframe workflows
6. Layer/object creation and arrangement
7. Inspector/property reads and writes
8. Export/share flows

Do not port these early:

- FCPXML helpers
- montage and FlexMusic
- transcript/caption flows
- batch export

## Suggested Work Breakdown

1. Refactor the command palette registry into a provider interface
2. Add a Motion provider backed by `NSProCommands.plist`
3. Add a Motion action router in the injected runtime
4. Prove direct execution for one command in each starter category
5. Add Motion MCP tools that wrap those adapters
6. Expand from command execution to layer/document introspection APIs

## Immediate Validation Loop

Use the new Motion-first tools in this order:

1. `python3 tools/extract_motion_surface.py --summary`
2. `python3 tools/extract_motion_surface.py --query marker --limit 20`
3. `python3 mcp/motion_server.py`
4. `bridge_status()`
5. `motion_search_commands("text tool")`
6. `get_classes("MG")`
7. `explore_class("MGMainWindowModule")`
8. `list_menus("Window", depth=3)`
9. `detect_dialog()`

## Exit Criteria For A Useful First MotionKit Release

- The dylib injects cleanly into a copied `Motion.app`
- The MotionKit palette opens inside Motion
- The palette can search Motion commands sourced from Motion's own plists
- At least 15 to 25 high-value Motion commands execute reliably through direct selectors or menu fallbacks
- The Motion MCP server can inspect runtime classes, search Motion commands, execute menus, and handle dialogs without falling back to FCP-specific abstractions
