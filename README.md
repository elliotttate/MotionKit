# MotionKit

MotionKit is a Motion-oriented copy of SpliceKit. It keeps the injected runtime, JSON-RPC bridge, command palette shell, Lua support, and MCP shape from SpliceKit, but retargets the outer scaffolding to Apple Motion at `/Applications/Motion.app`.

This copy is intentionally split into two layers:

- `Sources/` is the existing injected runtime and FCP-oriented bridge code, preserved as the starting point for a Motion port.
- `mcp/motion_server.py` and `tools/extract_motion_surface.py` are Motion-first additions that focus on runtime discovery, menu/dialog control, and command-palette seeding from Motion's own command metadata.

## Current State

- `Makefile` now targets a modded Motion copy at `~/Applications/MotionKit/Motion.app` and builds `MotionKit.framework`.
- `mcp/motion_server.py` is the new Motion-first MCP entrypoint.
- `tools/extract_motion_surface.py` reads Motion's bundled `NSProCommands*.plist` and `NSProCommandGroups.plist` files to seed a Motion command palette.
- `docs/MOTION_PORT_PLAN.md` lays out the migration plan for the command palette, JSON-RPC layer, and Motion-specific adapters.

## What Is Still FCP-Specific

- Most of [`Sources/SpliceKitServer.m`](/Users/briantate/Documents/GitHub/MotionKit/Sources/SpliceKitServer.m)
- The hard-coded command registry in [`Sources/SpliceKitCommandPalette.m`](/Users/briantate/Documents/GitHub/MotionKit/Sources/SpliceKitCommandPalette.m)
- Transcript, captions, montage, FlexMusic, and FCPXML workflows
- Several docs and helper scripts kept as reference while the Motion port is in progress

## Quick Start

1. `make copy-app`
2. `make deploy`
3. `make launch` for the lightweight background launcher, or `make launch-foreground` to run Motion directly in the current terminal like SpliceKit
4. Run `python3 mcp/motion_server.py`

## Motion Command Discovery

- `python3 tools/extract_motion_surface.py --summary`
- `python3 tools/extract_motion_surface.py --query marker --limit 20`
- `python3 tools/extract_motion_surface.py --group Tools --limit 50`

## Port Plan

The concrete migration plan lives in [`docs/MOTION_PORT_PLAN.md`](/Users/briantate/Documents/GitHub/MotionKit/docs/MOTION_PORT_PLAN.md).
