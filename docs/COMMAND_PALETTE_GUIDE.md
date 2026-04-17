# Command Palette & AI Commands Guide

Quick-access command palette with fuzzy search and Apple Intelligence natural
language processing for Final Cut Pro.

---

## Table of Contents

1. [Overview](#overview)
2. [Opening the Palette](#opening-the-palette)
3. [Fuzzy Search](#fuzzy-search)
4. [Command Categories](#command-categories)
5. [Apple Intelligence Integration](#apple-intelligence-integration)
6. [Favorites](#favorites)
7. [Keyboard Navigation](#keyboard-navigation)
8. [Programmatic API](#programmatic-api)
9. [Available Commands](#available-commands)

---

## Overview

The command palette provides instant access to 120+ Final Cut Pro editing
commands through a VS Code-style search interface. It opens as a floating
window inside FCP and supports:

- **Fuzzy search** — type partial matches to find commands quickly
- **Apple Intelligence** — type natural language sentences and press Tab to
  interpret them as editing commands using the on-device LLM
- **Favorites** — star frequently-used commands for quick access
- **Categories** — commands organized by Editing, Playback, Color, Speed,
  Markers, Titles, Keyframes, Effects, Transcript, Export, AI, Music, Options
- **Keyboard shortcuts** — displayed alongside each command for reference

---

## Opening the Palette

### Keyboard Shortcut

Press **Cmd+Shift+P** inside Final Cut Pro to toggle the palette.

### Via MCP

```python
show_command_palette()    # open
hide_command_palette()    # close
```

### Via SpliceKit Menu

The palette is also accessible from SpliceKit's menu in the FCP menu bar
and via a toolbar button.

---

## Fuzzy Search

Type in the search field to instantly filter commands. The fuzzy matching
algorithm scores results based on:

- **Character matches** — all query characters must appear in order in the
  target string
- **Consecutive bonus** — +0.5 for each consecutive character match
- **Word boundary bonus** — +0.3 for matches at the start of a word or after
  a space
- **Length penalty** — shorter, more precise matches rank higher

### Examples

| Query | Top Matches |
|-------|-------------|
| `bl` | Blade, Blade All |
| `colb` | Color Board, Color Balance |
| `slo` | Slow 50%, Slow 25%, Slow 10% |
| `mk` | Add Marker, Add Chapter Marker |
| `und` | Undo |

Results update in real-time as you type.

---

## Command Categories

Commands are organized into categories, shown as badges on each row:

| Category | Examples |
|----------|----------|
| **Editing** | Blade, Cut, Copy, Paste, Delete, Undo, Redo, Trim |
| **Playback** | Play/Pause, Next Frame, Previous Frame, Go to Start |
| **Color** | Color Board, Color Wheels, Color Curves, Balance Color |
| **Speed** | Slow 50%, Fast 2x, Reverse, Freeze Frame, Hold |
| **Markers** | Add Marker, Chapter Marker, Todo Marker, Delete Marker |
| **Titles** | Basic Title, Lower Third |
| **Keyframes** | Add Keyframe, Delete Keyframes, Next/Previous |
| **Effects** | Paste Effects, Remove Effects, Copy Attributes |
| **Transcript** | Open Transcript, Delete Silences |
| **Export** | Export XML, Share |
| **AI** | Natural language commands via Apple Intelligence |
| **Music** | FlexMusic, Montage |
| **Options** | SpliceKit settings toggles |

---

## Apple Intelligence Integration

The command palette integrates with Apple's on-device FoundationModels framework
for natural language command interpretation.

### How to Use

1. Open the palette (Cmd+Shift+P)
2. Type a natural language sentence describing what you want to do
3. Press **Tab** to send the query to Apple Intelligence
4. The AI interprets your request and maps it to one or more FCP commands
5. The result appears as an AI row in the palette — press Return to execute

### Examples

| Natural Language | Interpreted As |
|-----------------|----------------|
| "slow this clip to half speed" | `retimeSlow50` |
| "add a cross dissolve" | `addTransition` |
| "mark this spot" | `addMarker` |
| "cut here" | `blade` |
| "go back to the beginning" | `goToStart` |
| "make it black and white" | Color correction commands |

### Fallback

When Apple Intelligence is unavailable (older macOS or hardware without Neural
Engine), the system falls back to keyword matching against command names and
their associated search terms.

---

## Favorites

Star commands you use frequently for instant access:

### Adding Favorites

Right-click any command in the palette to toggle its favorite status, or use
the context menu.

### Favorite Behavior

- Favorited commands show a star indicator (★) next to their name
- When the search field is empty, favorites appear at the top of the list
- Favorites persist across FCP sessions via NSUserDefaults

---

## Keyboard Navigation

| Key | Action |
|-----|--------|
| **Cmd+Shift+P** | Toggle palette |
| **↑ / ↓** | Navigate commands (skips separator rows) |
| **Return** | Execute selected command |
| **Tab** | Send query to Apple Intelligence |
| **Escape** | Close palette |
| Type anything | Fuzzy search |

The search field stays focused while arrow keys navigate the table, so you can
type and navigate without clicking.

---

## Programmatic API

### Search Commands

```python
# Find commands by name or keyword
search_commands("blade")
search_commands("color")
search_commands("speed")
```

Returns matching commands with their action IDs, types, and categories.

### Execute Commands

```python
# Execute by action name and type
execute_command("blade", type="timeline")
execute_command("goToStart", type="playback")
execute_command("addColorBoard", type="timeline")
```

### AI Natural Language

```python
# Interpret natural language as FCP commands
ai_command("slow this clip to half speed")
ai_command("add a marker here")
ai_command("cut at every scene change")
```

### Complete Tool Reference

| Tool | Description |
|------|-------------|
| `show_command_palette()` | Open the palette |
| `hide_command_palette()` | Close the palette |
| `search_commands(query)` | Search commands by name/keyword |
| `execute_command(action, type)` | Execute a command directly |
| `ai_command(query)` | Natural language via Apple Intelligence |

---

## Available Commands

The palette includes 120+ commands spanning all FCP editing operations. These
map directly to SpliceKit's `timeline_action()` and `playback_action()` functions:

### Editing
Blade, Blade All, Delete, Cut, Copy, Paste, Paste as Connected, Undo, Redo,
Select All, Deselect All, Replace with Gap, Join Clips, Insert Gap,
Insert Placeholder, Add Adjustment Clip

### Playback
Play/Pause, Go to Start, Go to End, Next Frame, Previous Frame,
Next Frame ×10, Previous Frame ×10, Play Around Current

### Navigation
Next Edit, Previous Edit, Select Clip at Playhead, Select to Playhead

### Trim
Trim to Playhead, Extend Edit to Playhead, Trim Start, Trim End,
Nudge Left/Right/Up/Down

### Color
Color Board, Color Wheels, Color Curves, Color Adjustment, Hue/Saturation,
Enhance Light and Color, Balance Color, Match Color, Magnetic Mask,
Smart Conform

### Speed
Normal Speed, Fast 2x/4x/8x/20x, Slow 50%/25%/10%, Reverse, Hold,
Freeze Frame, Blade Speed, Speed Ramp to Zero, Speed Ramp from Zero

### Markers
Add Marker, Add Todo Marker, Add Chapter Marker, Delete Marker,
Next/Previous Marker, Delete Markers in Selection

### Titles & Effects
Basic Title, Basic Lower Third, Paste Effects, Remove Effects,
Copy/Paste Attributes, Remove Attributes

### Audio
Expand Audio, Channel EQ, Enhance Audio, Match Audio, Detach Audio,
Volume Up/Down

### Keyframes
Add Keyframe, Delete Keyframes, Next/Previous Keyframe

### Clip Operations
Solo, Disable, Create Compound Clip, Auto Reframe, Break Apart,
Synchronize Clips, Open Clip, Rename Clip, Change Duration

### Storyline
Create Storyline, Lift from Primary, Overwrite to Primary,
Collapse to Connected

### Rating
Favorite, Reject, Unrate

### View
Zoom to Fit, Zoom In/Out, Toggle Snapping, Toggle Skimming,
Toggle Inspector, Toggle Timeline

---

*The command palette runs in-process inside FCP. AI features require Apple
Silicon and macOS with FoundationModels framework support.*
