# Dragging FCPXML Content Directly onto the FCP Timeline

How to drag storylines, titles, and other content from a Workflow Extension
directly onto the Final Cut Pro timeline — without creating library artifacts.

---

## Table of Contents

1. [The Problem](#the-problem)
2. [The Solution](#the-solution)
3. [How It Works](#how-it-works)
4. [Implementation](#implementation)
5. [Building the FCPXML](#building-the-fcpxml)
6. [Frame Rate Matching](#frame-rate-matching)
7. [Common Pitfalls](#common-pitfalls)
8. [Comparison of Approaches](#comparison-of-approaches)

---

## The Problem

When building a workflow extension that needs to place content onto the FCP
timeline, you'll quickly discover that every documented approach creates
unwanted side effects:

- **Importing FCPXML via file** — Always creates events/projects in the library.
  FCP validates against the DTD and routes through the full import pipeline.
- **Using `<clip>` at the root** — Valid FCPXML, but creates a library item.
  The clip appears in the browser/events and can't be cleanly "timeline-only."
- **Using `<spine>` at the root** — Fails DTD validation entirely.
- **Suppressing warnings with `import-options`** — FCP still validates the DTD.
  No bypass exists for the structural requirements.

The core issue: FCP's FCPXML import pipeline is designed for project-level
operations. There's no documented way to say "just put this on the timeline."

---

## The Solution

Use FCP's **internal pasteboard UTI** for drag-and-drop:

```
com.apple.flexo.proFFPasteboardUTI
```

This is the same pasteboard type that FCP uses internally for copy/paste and
drag operations between timelines. When FCP sees this UTI on a drag pasteboard,
it treats the content as an internal operation — the FCPXML is deserialized and
inserted directly at the drop point on the timeline. No library artifact, no
event, no browser entry.

---

## How It Works

### The Mechanism

1. Your extension builds an FCPXML string containing the content to insert
2. The XML data is placed on an `NSPasteboardItem` with the type
   `com.apple.flexo.proFFPasteboardUTI`
3. An `NSDraggingItem` wraps the pasteboard item
4. `beginDraggingSessionWithItems:event:source:` initiates the drag from your
   extension's view
5. When the user drops onto the timeline, FCP's internal drag handler
   deserializes the FCPXML and inserts it at the drop point

### Why This Bypasses the Library

- Standard FCPXML import goes through FCP's `Interchange` framework import
  pipeline, which always creates library structures (events, projects, etc.)
- The `proFFPasteboardUTI` drag path goes through `Flexo`'s internal
  pasteboard handling, which operates at the timeline level
- This is the same code path FCP uses when you copy clips from one timeline
  and paste them into another — no new library items are created

### Drop Target Behavior

- **Timeline**: Accepts the drop, inserts content as a connected storyline
- **Browser/Library**: Ignored — FCP does not accept `proFFPasteboardUTI`
  drags on the library or browser panes
- This is by design: the internal pasteboard format represents timeline-level
  objects, not library-level media

---

## Implementation

### Swift — Drag Source

```swift
import Cocoa

class DragSourceView: NSView, NSDraggingSource {

    /// The pasteboard type FCP uses internally for FCPXML content
    static let fcpPasteboardType = NSPasteboard.PasteboardType(
        "com.apple.flexo.proFFPasteboardUTI"
    )

    func startDrag(with event: NSEvent) {
        // 1. Build the FCPXML string
        let fcpxml = buildFCPXML()

        guard let xmlData = fcpxml.data(using: .utf8),
              !xmlData.isEmpty else { return }

        // 2. Create pasteboard item with FCP's internal UTI
        let pbItem = NSPasteboardItem()
        pbItem.setData(xmlData, forType: Self.fcpPasteboardType)

        // 3. Create the dragging item
        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
        dragItem.setDraggingFrame(self.bounds, contents: nil)

        // 4. Start the drag session
        let session = self.beginDraggingSession(
            with: [dragItem],
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        return context == .outsideApplication ? .copy : .copy
    }
}
```

### Objective-C — Drag Source

```objc
static NSString *const kFCPPasteboardType = @"com.apple.flexo.proFFPasteboardUTI";

- (void)startDragWithView:(NSView *)view event:(NSEvent *)event {
    NSString *fcpxml = [self buildFCPXML];
    if (fcpxml.length == 0) return;

    // Create pasteboard item with FCP's internal UTI
    NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
    [pbItem setData:[fcpxml dataUsingEncoding:NSUTF8StringEncoding]
            forType:kFCPPasteboardType];

    // Create dragging item
    NSDraggingItem *dragItem = [[NSDraggingItem alloc]
        initWithPasteboardWriter:pbItem];
    [dragItem setDraggingFrame:view.bounds contents:nil];

    // Start drag session
    NSDraggingSession *session = [view
        beginDraggingSessionWithItems:@[dragItem]
                                event:event
                               source:self];
    session.animatesToStartingPositionsOnCancelOrFail = YES;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return NSDragOperationCopy;
}
```

### Triggering the Drag from a Button

If you want a dedicated "drag to timeline" button (rather than drag-from-anywhere),
subclass `NSButton` and override `mouseDown:` to start the drag session:

```swift
class DragButton: NSButton {
    var xmlProvider: (() -> String)?

    override func mouseDown(with event: NSEvent) {
        guard let xml = xmlProvider?(), !xml.isEmpty else {
            super.mouseDown(with: event)
            return
        }

        let pbItem = NSPasteboardItem()
        pbItem.setData(
            xml.data(using: .utf8)!,
            forType: NSPasteboard.PasteboardType("com.apple.flexo.proFFPasteboardUTI")
        )

        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
        dragItem.setDraggingFrame(self.bounds, contents: nil)

        self.beginDraggingSession(with: [dragItem], event: event, source: self)
    }
}
```

---

## Building the FCPXML

The FCPXML placed on the pasteboard must be a valid FCPXML document. The key
structure for a timeline-insertable storyline is a `<spine>` inside the
standard FCPXML wrapper.

### Minimal Storyline with a Title

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>

<fcpxml version="1.11">
    <resources>
        <format id="r1" name="FFVideoFormat1080p2398"
                frameDuration="1001/24000s"
                width="1920" height="1080"/>
        <effect id="r2" name="Basic Title"
                uid=".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"/>
    </resources>
    <spine>
        <title ref="r2" name="My Title" offset="0s" duration="5s" start="3600s">
            <text>
                <text-style ref="ts1">Hello World</text-style>
            </text>
            <text-style-def id="ts1">
                <text-style font="Helvetica" fontSize="63"
                            fontColor="1 1 1 1" alignment="center"/>
            </text-style-def>
        </title>
    </spine>
</fcpxml>
```

### Multiple Titles in a Storyline

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>

<fcpxml version="1.11">
    <resources>
        <format id="r1" name="FFVideoFormat1080p2398"
                frameDuration="1001/24000s"
                width="1920" height="1080"/>
        <effect id="r2" name="Basic Title"
                uid=".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"/>
    </resources>
    <spine>
        <title ref="r2" name="Caption 1" offset="0s" duration="72072/24000s" start="3600s">
            <text>
                <text-style ref="ts1">First caption line</text-style>
            </text>
            <text-style-def id="ts1">
                <text-style font="Helvetica" fontSize="48"
                            fontColor="1 1 1 1" alignment="center"/>
            </text-style-def>
        </title>
        <title ref="r2" name="Caption 2" offset="72072/24000s" duration="48048/24000s" start="3600s">
            <text>
                <text-style ref="ts2">Second caption line</text-style>
            </text>
            <text-style-def id="ts2">
                <text-style font="Helvetica" fontSize="48"
                            fontColor="1 1 1 1" alignment="center"/>
            </text-style-def>
        </title>
    </spine>
</fcpxml>
```

### Key Points About the XML Structure

- The root element is `<fcpxml>` with a `version` attribute
- `<!DOCTYPE fcpxml>` is required
- `<resources>` must declare the format and any referenced effects
- `<spine>` is the container — this is what makes it insert as a storyline
- Each `<title>` references an effect from `<resources>` via `ref`
- Timing uses rational time values (e.g., `1001/24000s` for 23.98fps)
- `start="3600s"` is the standard FCP timeline start time (1 hour)

---

## Frame Rate Matching

The FCPXML format and timing values **must match the active project's frame
rate**. If you have access to the workflow extension host's
`ProjectTimelineObserver`, read the `ActiveSequenceFrameDuration` to get the
project's frame duration as a CMTime value.

| Frame Rate | frameDuration | Format Name |
|-----------|---------------|-------------|
| 23.98 fps | 1001/24000s | FFVideoFormat1080p2398 |
| 24 fps | 100/2400s | FFVideoFormat1080p24 |
| 25 fps | 100/2500s | FFVideoFormat1080p25 |
| 29.97 fps | 1001/30000s | FFVideoFormat1080p2997 |
| 30 fps | 100/3000s | FFVideoFormat1080p30 |
| 50 fps | 100/5000s | FFVideoFormat1080p50 |
| 59.94 fps | 1001/60000s | FFVideoFormat1080p5994 |
| 60 fps | 100/6000s | FFVideoFormat1080p60 |

When building duration values for individual clips, use the frame duration as
your base unit. For example, at 23.98 fps, a 3-second title would have
duration `72072/24000s` (72 frames × 1001/24000).

---

## Common Pitfalls

### 1. Using the wrong pasteboard type

Using `public.xml`, `com.apple.xml`, or any standard UTI will not work. FCP
only recognizes `com.apple.flexo.proFFPasteboardUTI` for timeline drag
insertion.

### 2. Missing DOCTYPE

FCP validates the XML structure. Omitting `<!DOCTYPE fcpxml>` will cause the
drop to silently fail.

### 3. Frame rate mismatch

If your FCPXML declares a different frame rate than the active project, FCP may
reject the drop or insert content with incorrect timing. Always match the
project's frame rate.

### 4. Trying to drag to the library

The `proFFPasteboardUTI` type is only accepted by the timeline. Dragging to
the browser or library panes will show a "not allowed" cursor. If you need
to add items to the library, use the standard FCPXML import workflow via
the extension host API instead.

### 5. Setting string data instead of raw bytes

Use `setData(_:forType:)` with `Data`/`NSData`, not `setString(_:forType:)`.
The pasteboard data should be UTF-8 encoded bytes of the XML string.

### 6. Empty or nil XML

Always check that the XML string has content before creating the pasteboard
item. An empty data payload will cause the drag to appear to start but FCP
won't accept the drop.

---

## Comparison of Approaches

| Approach | Timeline Insert | Library Artifact | DTD Valid | Notes |
|----------|:-:|:-:|:-:|-------|
| FCPXML file import | Yes | **Yes** | Required | Standard import pipeline, always creates events |
| `<clip>` at root | Yes | **Yes** | Yes | Valid but creates browser items |
| `<spine>` at root (file) | No | No | **No** | Fails DTD validation as a file |
| `proFFPasteboardUTI` drag | **Yes** | **No** | Yes | Internal pasteboard, timeline-only |
| NSPasteboard with file URL | Yes | **Yes** | N/A | Treated as media import |

The `proFFPasteboardUTI` approach is the only method that achieves
timeline-only insertion without library side effects.

---

## Related Resources

- [Workflow Extensions Guide](WORKFLOW_EXTENSIONS_GUIDE.md) — Building extensions
  that embed in FCP's UI
- [FCPXML Format Reference](FCPXML_FORMAT_REFERENCE.md) — Complete FCPXML
  element and attribute documentation
- [FCP Pasteboard & Media Linking](FCP_PASTEBOARD_MEDIA_LINKING.md) — How FCP's
  clipboard system works internally
- [Content Exchange Guide](CONTENT_EXCHANGE_GUIDE.md) — Patterns for data
  exchange between extensions and FCP
