# Runtime Introspection Guide

Explore Final Cut Pro's 78,000+ Objective-C classes, methods, and data structures
at runtime using SpliceKit's reflection tools.

---

## Table of Contents

1. [Overview](#overview)
2. [Class Discovery](#class-discovery)
3. [Method Exploration](#method-exploration)
4. [Properties & Instance Variables](#properties--instance-variables)
5. [Protocols & Inheritance](#protocols--inheritance)
6. [Comprehensive Class Overview](#comprehensive-class-overview)
7. [Calling Methods](#calling-methods)
8. [Object Handles](#object-handles)
9. [Binary & Symbol Analysis](#binary--symbol-analysis)
10. [Notification Discovery](#notification-discovery)
11. [Key Class Prefixes](#key-class-prefixes)
12. [Exploration Workflows](#exploration-workflows)

---

## Overview

FCP loads 78,000+ Objective-C classes across 53 binaries at runtime. SpliceKit
exposes the ObjC runtime reflection API, letting you enumerate classes, inspect
methods with type encodings, read properties and ivars, walk inheritance chains,
discover protocols, and call methods — all from the MCP interface.

This is essential for:

- **Discovering new FCP capabilities** before they're documented
- **Understanding FCP's internal architecture** for building integrations
- **Debugging** unexpected behavior by inspecting live object state
- **Reverse engineering** FCP's data model and rendering pipeline
- **Building new SpliceKit features** by finding the right internal APIs

---

## Class Discovery

### Listing Classes

```python
# List all classes (78,000+) — returns first 200
get_classes()

# Filter by prefix — find all Flexo classes
get_classes(filter="FF")

# Find color-related classes
get_classes(filter="Color")

# Find timeline classes
get_classes(filter="Timeline")
```

### Common Class Prefixes

| Prefix | Framework | Domain |
|--------|-----------|--------|
| `FF` | Flexo | Core editing, timeline, library, effects |
| `OZ` | Ozone | Color processing, LUTs, scopes |
| `PE` | ProEditor | App controller, editor modules, UI |
| `LK` | LunaKit | UI components, views, controls |
| `TLK` / `TK` | TimelineKit | Timeline rendering, layout |
| `IX` | Interchange | FCPXML import/export |
| `HM` / `HMD` | Helium | GPU rendering, Metal pipeline |
| `PA` | ProAppSupport | Logging, utilities, shared services |
| `AA` | (various) | AI/ML analysis (speech, scenes, faces) |
| `MF` | MFToolkit | Media foundation, codecs |
| `NS` | Foundation | Apple framework classes |

---

## Method Exploration

### Listing All Methods

```python
# All methods declared directly on a class
get_methods("FFAnchoredTimelineModule")

# Include inherited methods from superclasses
get_methods("FFAnchoredTimelineModule", include_super=True)
```

Returns instance methods (`-`) and class methods (`+`) with ObjC type encodings.

### Searching Methods

```python
# Find blade-related methods on the timeline module
search_methods("FFAnchoredTimelineModule", "blade")
# Results:
#   - actionBlade:  (v24@0:8@16)
#   - actionBladeAll:  (v24@0:8@16)

# Find methods related to markers
search_methods("FFAnchoredTimelineModule", "marker")

# Find color correction methods
search_methods("FFAnchoredTimelineModule", "color")

# Find export-related methods
search_methods("FFAnchoredSequence", "export")
```

### Understanding Type Encodings

ObjC type encodings describe method signatures:

| Encoding | Type |
|----------|------|
| `v` | void |
| `@` | id (object) |
| `:` | SEL (selector) |
| `B` | BOOL |
| `i` | int |
| `q` | long long (int64) |
| `d` | double |
| `f` | float |
| `{CMTime=qiIq}` | CMTime struct |
| `#` | Class |
| `^` | pointer |

Example: `v24@0:8@16` means:
- Return type: `v` (void)
- Total frame size: 24 bytes
- Arg 0 at offset 0: `@` (self)
- Arg 1 at offset 8: `:` (selector)
- Arg 2 at offset 16: `@` (id — the sender parameter)

---

## Properties & Instance Variables

### Declared Properties

```python
# List @property declarations
get_properties("FFAnchoredMediaComponent")
# Results:
#   displayName: T@"NSString",R,N
#   duration: T{CMTime=qiIq},R,N
#   mediaType: Ti,R,N
```

Property attribute codes:

| Code | Meaning |
|------|---------|
| `T` | Type |
| `R` | Readonly |
| `N` | Nonatomic |
| `C` | Copy |
| `&` | Retain (strong) |
| `W` | Weak |

### Instance Variables

```python
# List ivars with types and offsets
get_ivars("FFAnchoredSequence")
# Results:
#   _primaryObject: @"FFAnchoredCollection"
#   _duration: {CMTime=qiIq}
#   _startTime: {CMTime=qiIq}
```

Ivars reveal the internal storage layout, which is useful for understanding
what data a class actually holds (as opposed to computed properties).

---

## Protocols & Inheritance

### Protocol Conformance

```python
# What protocols does a class adopt?
get_protocols("FFAnchoredTimelineModule")
# Results:
#   FFUndoManagerClient
#   FFEditActionTarget
#   NSMenuDelegate
#   ...
```

### Inheritance Chain

```python
# Walk the superclass chain
get_superchain("FFAnchoredMediaComponent")
# Result:
#   FFAnchoredMediaComponent -> FFAnchoredItem -> FFAnchoredObject -> NSObject
```

This reveals the class hierarchy and helps you understand where methods are
actually implemented (check the superclass if a method isn't on the subclass).

---

## Comprehensive Class Overview

The `explore_class` tool combines all introspection into a single overview:

```python
explore_class("FFAnchoredTimelineModule")
```

Returns:
- Inheritance chain
- Adopted protocols (with count)
- Properties (first 30)
- Instance variables (first 15)
- Method counts (instance + class)
- All class methods
- Notable instance methods (filtered by keywords: get, set, current, active,
  selected, add, remove, create, delete, open, close, name, items, clip,
  effect, marker)

This is the best starting point when investigating a new class.

---

## Calling Methods

### Zero-Argument Methods

```python
# Call a class method
call_method("FFLibraryDocument", "copyActiveLibraries", class_method=True)

# Call an instance method (need a handle first)
call_method("NSApp", "delegate", class_method=False)
```

### Methods with Arguments

```python
# Full method invocation with typed arguments
call_method_with_args(
    target="FFLibraryDocument",
    selector="copyActiveLibraries",
    args="[]",
    class_method=True,
    return_handle=True
)

# Get item at index from an array handle
call_method_with_args(
    target="obj_1",              # handle from previous call
    selector="objectAtIndex:",
    args='[{"type":"int","value":0}]',
    class_method=False,
    return_handle=True
)

# Call with string argument
call_method_with_args(
    target="obj_2",
    selector="valueForKey:",
    args='[{"type":"string","value":"displayName"}]',
    class_method=False
)
```

### Argument Types

| Type | Format | Example |
|------|--------|---------|
| `string` | `{"type":"string","value":"text"}` | NSString argument |
| `int` | `{"type":"int","value":42}` | Integer argument |
| `double` | `{"type":"double","value":3.14}` | Double argument |
| `float` | `{"type":"float","value":1.5}` | Float argument |
| `bool` | `{"type":"bool","value":true}` | BOOL argument |
| `nil` | `{"type":"nil"}` | nil/NULL argument |
| `handle` | `{"type":"handle","value":"obj_3"}` | Object from handle store |
| `cmtime` | `{"type":"cmtime","value":{"value":30000,"timescale":600}}` | CMTime struct |
| `selector` | `{"type":"selector","value":"doSomething:"}` | SEL argument |
| `sender` | `{"type":"sender"}` | Uses nil as IBAction sender |

### Raw JSON-RPC

For advanced use, send raw JSON-RPC calls directly:

```python
raw_call("system.callMethod", '{"className":"NSApp","selector":"delegate","classMethod":false}')
```

---

## Object Handles

When you call methods that return objects, you can store them as handles for
subsequent calls. Handles persist across multiple RPC calls (up to 2000 cached).

### Getting Handles

```python
# return_handle=True stores the returned object
r = call_method_with_args("FFLibraryDocument", "copyActiveLibraries", "[]", True, True)
# Returns: {"handle": "obj_1", "class": "__NSArrayM", ...}
```

### Using Handles

```python
# Use the handle ID as the target in subsequent calls
call_method_with_args("obj_1", "count", "[]", False)
call_method_with_args("obj_1", "objectAtIndex:", '[{"type":"int","value":0}]', False, True)
```

### Reading Properties via KVC

```python
# Key-Value Coding property access
get_object_property("obj_2", "displayName")
get_object_property("obj_2", "duration")
```

### Managing Handles

```python
# List all stored handles
manage_handles(action="list")

# Inspect a specific handle
manage_handles(action="inspect", handle="obj_1")

# Release a specific handle
manage_handles(action="release", handle="obj_1")

# Release all handles (clean up)
manage_handles(action="release_all")
```

Always release handles when done to prevent memory leaks in FCP's process.

---

## Binary & Symbol Analysis

### Listing Loaded Binaries

FCP loads 53+ Mach-O binaries (frameworks, dylibs, plugins). List them with
base addresses and ASLR slides:

```python
# All loaded images
list_loaded_images()

# Filter to specific frameworks
list_loaded_images(filter="Flexo")
list_loaded_images(filter="Ozone")
list_loaded_images(filter="Helium")
```

### Exported Symbols

Get the symbol table for any loaded binary:

```python
# All exported symbols from a framework
get_image_symbols(binary="Flexo")

# Filter to specific symbols
get_image_symbols(binary="Flexo", filter="Timeline")

# Without Swift demangling
get_image_symbols(binary="Flexo", filter="render", demangle=False)
```

### ObjC Section Data

Inspect cross-binary dependencies:

```python
# Get selector refs, class refs, superclass refs
get_image_sections(binary="Flexo")
```

This reveals which selectors a binary calls and which classes it references,
essential for understanding the dependency graph between FCP's frameworks.

### Bulk Runtime Export

Export full runtime metadata for use in IDA Pro or other analysis tools:

```python
# Full metadata dump (slow, comprehensive)
dump_runtime_metadata()

# Filter to a specific framework
dump_runtime_metadata(binary="Flexo")

# Quick overview — just class names per image
dump_runtime_metadata(classes_only=True)
```

Returns loaded images with ASLR slides and complete class metadata including
method IMP addresses (for mapping to static disassembly addresses).

---

## Notification Discovery

FCP uses NSNotificationCenter extensively. Discover notification names from
exported symbols:

```python
# All notification names across all binaries
get_notification_names()

# Notifications from a specific framework
get_notification_names(binary="Flexo")
```

This finds exported symbols containing "Notification" and resolves their actual
NSString values — the names used in `postNotificationName:` calls.

Useful notifications to watch for:

- Timeline changes (clip added/removed/moved)
- Selection changes
- Playhead position updates
- Library save events
- Render completion

---

## Key Class Prefixes

### Core Editing (FF — Flexo)

| Class | Purpose |
|-------|---------|
| `FFAnchoredTimelineModule` | Main timeline editing controller (1,400+ methods) |
| `FFAnchoredSequence` | Timeline data model (sequence container) |
| `FFAnchoredMediaComponent` | Video/audio clips in the timeline |
| `FFAnchoredTransition` | Transitions between clips |
| `FFAnchoredCollection` | Container for timeline items (primary storyline) |
| `FFLibrary` | Library data model |
| `FFLibraryDocument` | Library document controller |
| `FFEditActionMgr` | Edit command dispatcher |
| `FFEffectStack` | Effects applied to a clip |
| `FFUndoManager` | Undo/redo management |
| `FFEffectRegistry` | Available effects catalog |

### App Controller (PE — ProEditor)

| Class | Purpose |
|-------|---------|
| `PEAppController` | Application delegate |
| `PEEditorContainerModule` | Editor/timeline container |
| `PEPlayerContainerModule` | Viewer container |

### Color & Rendering (OZ — Ozone, HM — Helium)

| Class | Purpose |
|-------|---------|
| `OZColorSpace` | Color space management |
| `OZLookupTable` | LUT processing |
| `HMDRenderPipeline` | Metal render pipeline |
| `HMDFramerate` | Framerate monitoring |

### Timeline UI (TLK — TimelineKit)

| Class | Purpose |
|-------|---------|
| `TLKTimeline` | Timeline UI view |
| `TLKTimelineLayer` | Individual timeline layer |
| `TLKUserDefaults` | Timeline debug settings |

---

## Exploration Workflows

### Discovering a New Feature

```python
# 1. Find relevant classes
get_classes(filter="Magnetic")

# 2. Pick the most promising one and explore it
explore_class("FFMagneticMaskEffect")

# 3. Search for specific methods
search_methods("FFMagneticMaskEffect", "apply")
search_methods("FFMagneticMaskEffect", "mask")

# 4. Check the superclass for inherited behavior
get_superchain("FFMagneticMaskEffect")
explore_class("FFVideoEffect")  # parent class

# 5. Try calling a method
call_method_with_args("FFMagneticMaskEffect", "someClassMethod", "[]", True, True)
```

### Walking the Timeline Data Model

```python
# 1. Get active libraries
call_method_with_args("FFLibraryDocument", "copyActiveLibraries", "[]", True, True)
# → obj_1 (__NSArrayM)

# 2. Get first library
call_method_with_args("obj_1", "objectAtIndex:", '[{"type":"int","value":0}]', False, True)
# → obj_2 (FFLibrary)

# 3. Get library name
get_object_property("obj_2", "displayName")

# 4. Get sequences
call_method_with_args("obj_2", "_deepLoadedSequences", "[]", False, True)
# → obj_3 (NSSet)

# 5. Convert to array for indexing
call_method_with_args("obj_3", "allObjects", "[]", False, True)
# → obj_4 (__NSArrayM)

# 6. Explore each sequence
call_method_with_args("obj_4", "objectAtIndex:", '[{"type":"int","value":0}]', False, True)
get_object_property("obj_5", "displayName")
get_object_property("obj_5", "duration")

# 7. Clean up
manage_handles(action="release_all")
```

### Finding How FCP Implements a Feature

```python
# Example: How does FCP handle the "Balance Color" feature?

# 1. Find related classes
get_classes(filter="Balance")
get_classes(filter="ColorBalance")

# 2. Search timeline module for the action
search_methods("FFAnchoredTimelineModule", "balance")
# → actionBalanceColor:

# 3. Find what effect it applies
get_classes(filter="FFColorBalance")
explore_class("FFColorBalanceEffect")

# 4. Check effect registry for the balance effect
search_methods("FFEffectRegistry", "balance")
```

### Mapping Runtime to IDA Pro

```python
# 1. Get ASLR slide for the target binary
list_loaded_images(filter="Flexo")
# → base: 0x104000000, slide: 0x4000000

# 2. Export runtime metadata with IMP addresses
dump_runtime_metadata(binary="Flexo")
# → methods with IMP: 0x104123456

# 3. Convert: static_addr = IMP - slide
# → 0x104123456 - 0x4000000 = 0x100123456 (IDA address)
```

---

*All introspection tools operate on the live FCP process. Class layouts and
method signatures may change between FCP versions. Always verify with the
current runtime before relying on specific selectors or properties.*
