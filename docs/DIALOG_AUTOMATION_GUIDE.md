# Dialog Automation Guide

Detect, inspect, and interact with FCP dialogs, sheets, and alerts
programmatically for fully automated workflows.

---

## Table of Contents

1. [Overview](#overview)
2. [Detecting Dialogs](#detecting-dialogs)
3. [Clicking Buttons](#clicking-buttons)
4. [Filling Text Fields](#filling-text-fields)
5. [Toggling Checkboxes](#toggling-checkboxes)
6. [Selecting from Popups](#selecting-from-popups)
7. [Dismissing Dialogs](#dismissing-dialogs)
8. [Common Dialogs](#common-dialogs)
9. [Workflow Examples](#workflow-examples)

---

## Overview

Many FCP operations trigger dialogs that require user interaction — project
creation, export settings, media handle warnings, save confirmations, and more.
SpliceKit provides six tools for automating dialog interaction:

| Tool | Purpose |
|------|---------|
| `detect_dialog()` | Scan for open dialogs and inspect their contents |
| `click_dialog_button(button)` | Click a button by title |
| `fill_dialog_field(value, index)` | Enter text in a field |
| `toggle_dialog_checkbox(checkbox)` | Toggle a checkbox |
| `select_dialog_popup(select)` | Choose from a dropdown menu |
| `dismiss_dialog(action)` | Close the dialog |

These tools work with all dialog types: modal windows, sheets, alerts, panels,
progress dialogs, and share sheets.

---

## Detecting Dialogs

Always call `detect_dialog()` first to understand what's currently showing:

```python
detect_dialog()
```

Returns detailed information about all visible dialogs:

- **Dialog type** — modal, sheet, alert, panel, progress, share
- **Title** — the dialog's title text
- **Labels** — all text labels in the dialog
- **Buttons** — available buttons with enabled/disabled status
- **Text fields** — editable fields with current values
- **Checkboxes** — with checked/unchecked state
- **Popup menus** — with available options and current selection

### Example Response

```json
{
  "dialogCount": 1,
  "dialogs": [{
    "type": "sheet",
    "title": "New Project",
    "buttons": [
      {"title": "OK", "enabled": true},
      {"title": "Cancel", "enabled": true}
    ],
    "textFields": [
      {"index": 0, "value": "Untitled Project", "placeholder": "Name"}
    ],
    "checkboxes": [
      {"title": "Use custom settings", "checked": false}
    ],
    "popupMenus": [
      {"index": 0, "title": "Format", "selectedItem": "1080p HD",
       "items": ["4K", "1080p HD", "720p HD"]}
    ]
  }]
}
```

---

## Clicking Buttons

Click a button in the active dialog:

```python
# By title (case-insensitive, partial match)
click_dialog_button(button="OK")
click_dialog_button(button="Cancel")
click_dialog_button(button="Share")
click_dialog_button(button="Don't Save")
click_dialog_button(button="Use Freeze Frames")

# By index (0-based) when title is ambiguous
click_dialog_button(index=0)   # first button
click_dialog_button(index=1)   # second button
```

Button matching is case-insensitive and supports partial matches, so
`button="save"` will match "Save", "Don't Save", etc. Use the more specific
string or index if there are multiple matches.

---

## Filling Text Fields

Enter text in dialog fields:

```python
# Fill the first text field (index 0)
fill_dialog_field(value="My Project Name")

# Fill a specific field by index
fill_dialog_field(value="30", index=1)  # second field
```

Use `detect_dialog()` first to see available text fields and their current
values. The index is 0-based.

---

## Toggling Checkboxes

Toggle or explicitly set checkbox state:

```python
# Toggle a checkbox (case-insensitive partial match on title)
toggle_dialog_checkbox(checkbox="Use custom settings")

# Explicitly set to checked
toggle_dialog_checkbox(checkbox="Use custom settings", checked=True)

# Explicitly set to unchecked
toggle_dialog_checkbox(checkbox="Include captions", checked=False)
```

---

## Selecting from Popups

Choose an item from a dropdown/popup menu:

```python
# Select by item title
select_dialog_popup(select="4K")
select_dialog_popup(select="ProRes 422")

# If there are multiple popup menus, specify which one (0-based)
select_dialog_popup(select="24p", popup_index=1)
```

---

## Dismissing Dialogs

Close the current dialog with a standard action:

```python
# Click the default button (usually OK/Share/Done)
dismiss_dialog(action="default")

# Click Cancel or press Escape
dismiss_dialog(action="cancel")

# Explicitly look for OK/Done/Share
dismiss_dialog(action="ok")
```

---

## Common Dialogs

### New Project Dialog

```python
# Trigger the dialog
create_project()

# Fill in project name
fill_dialog_field(value="My Edit v2")

# Set format
select_dialog_popup(select="4K")

# Confirm
click_dialog_button(button="OK")
```

### Share/Export Dialog

```python
# Trigger export
share_project("Export File")

# Wait for dialog, then configure
detect_dialog()
select_dialog_popup(select="Apple ProRes 422")
click_dialog_button(button="Share")
```

### "Not Enough Media" Transition Warning

When applying a transition and clips don't have enough media handles:

```python
# Apply transition
apply_transition(name="Cross Dissolve")

# Check if the media handle warning appeared
dialog = detect_dialog()

# Option A: Use freeze frames (SpliceKit addition)
click_dialog_button(button="Use Freeze Frames")

# Option B: Let FCP ripple trim
click_dialog_button(button="OK")

# Option C: Cancel
click_dialog_button(button="Cancel")
```

### Save Changes Dialog

```python
# When closing a library with unsaved changes
detect_dialog()
click_dialog_button(button="Save")      # save and close
# or
click_dialog_button(button="Don't Save") # discard changes
# or
click_dialog_button(button="Cancel")     # cancel closing
```

### Delete Confirmation

```python
detect_dialog()
click_dialog_button(button="Delete")
```

---

## Workflow Examples

### Automated Project Creation

```python
# Create project with specific settings
create_project()

# Detect the dialog
detect_dialog()

# Configure
fill_dialog_field(value="Interview Edit - April 2026")
toggle_dialog_checkbox(checkbox="Use custom settings", checked=True)
select_dialog_popup(select="4K")
select_dialog_popup(select="24p", popup_index=1)

# Confirm
click_dialog_button(button="OK")
```

### Automated Export Pipeline

```python
# Start export
share_project("Export File")

# Handle the share dialog
detect_dialog()
click_dialog_button(button="Share")

# Monitor for progress dialog
import time
time.sleep(2)
dialog = detect_dialog()
# Wait for completion...
```

### Safe Operation with Dialog Checking

For any operation that might trigger an unexpected dialog:

```python
# Perform an edit
timeline_action("blade")

# Check if any dialog appeared
dialog = detect_dialog()
if "no dialog" not in dialog.lower():
    # Handle it
    dismiss_dialog(action="default")
```

### Batch Operations with Dialog Handling

```python
# When batch-exporting, each clip may trigger a share dialog
for i in range(clip_count):
    # ... set range to clip boundaries ...
    share_project("Export File")
    
    # Wait for dialog and confirm
    detect_dialog()
    click_dialog_button(button="Share")
    
    # Wait for export to complete before next clip
```

---

*Dialog automation operates on NSWindow, NSAlert, and NSPanel instances in
FCP's window hierarchy. Button matching is case-insensitive with partial string
matching. Always call `detect_dialog()` first to see what controls are available.*
