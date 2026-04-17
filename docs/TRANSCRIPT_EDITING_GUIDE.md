# Transcript-Based Editing Guide

Text-based video editing via speech transcription — edit video by editing text.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Transcription Engines](#transcription-engines)
4. [Getting Started](#getting-started)
5. [The Transcript Panel](#the-transcript-panel)
6. [Editing Operations](#editing-operations)
7. [Silence Detection & Removal](#silence-detection--removal)
8. [Speaker Diarization](#speaker-diarization)
9. [Search & Navigation](#search--navigation)
10. [Programmatic API](#programmatic-api)
11. [Workflows](#workflows)

---

## Overview

SpliceKit includes a full transcript-based editing system. It transcribes all clips
on the timeline using on-device speech recognition, then displays the transcript as
editable text in a floating panel inside Final Cut Pro. Editing the text edits the
video — deleting words removes the corresponding video segments, dragging words
reorders clips on the timeline.

This is similar to text-based editing in tools like Descript or Premiere Pro's
transcript panel, but runs entirely on-device with no cloud dependency.

Key capabilities:

- **Multiple transcription engines** — choose between speed and accuracy
- **Speaker diarization** — automatic speaker identification (macOS 26+)
- **Silence detection** — inline `[...]` markers for pauses, with batch removal
- **Click-to-seek** — click any word to jump the playhead to that moment
- **Drag-to-reorder** — drag selected words to rearrange clips on the timeline
- **Delete-to-cut** — select words and press Delete to ripple-delete the segment
- **Live playhead sync** — current word highlighted during playback
- **Search** — find text, filter by pauses or low-confidence words

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  Final Cut Pro Process                                │
│                                                       │
│  ┌─────────────────────────────────────────────────┐ │
│  │  SpliceKitTranscriptPanel (floating NSPanel)           │ │
│  │                                                  │ │
│  │  ┌────────────────────────────────────────┐      │ │
│  │  │  Engine Selector  │  Speaker Diarization│      │ │
│  │  ├────────────────────────────────────────┤      │ │
│  │  │  SpliceKitTranscriptTextView                 │      │ │
│  │  │  ┌──────────────────────────────────┐  │      │ │
│  │  │  │ [Speaker 1] 00:00:02:00          │  │      │ │
│  │  │  │ Hello world this is a test       │  │      │ │
│  │  │  │ [...] ← silence marker           │  │      │ │
│  │  │  │ [Speaker 2] 00:00:05:12          │  │      │ │
│  │  │  │ Yes it is working now            │  │      │ │
│  │  │  └──────────────────────────────────┘  │      │ │
│  │  ├────────────────────────────────────────┤      │ │
│  │  │  Search Bar  │  Status / Word Count    │      │ │
│  │  └────────────────────────────────────────┘      │ │
│  └─────────────────────────────────────────────────┘ │
│                                                       │
│  ┌───────────────────────┐                           │
│  │  Timeline             │ ← edits applied here      │
│  └───────────────────────┘                           │
└──────────────────────────────────────────────────────┘
```

The transcript panel runs in-process within FCP (via SpliceKit injection). It reads
clips directly from the timeline data model, extracts audio for transcription, then
maps each word back to its exact position in the timeline for editing.

### Data Model

Each transcribed word is stored as an `SpliceKitTranscriptWord` with:

| Property | Type | Description |
|----------|------|-------------|
| `text` | String | The transcribed word |
| `startTime` | Double | Start time on the timeline (seconds) |
| `duration` | Double | Word duration (seconds) |
| `confidence` | Double | Recognition confidence (0.0–1.0) |
| `wordIndex` | Int | Position in the words array |
| `speaker` | String | Detected or assigned speaker name |
| `clipHandle` | String | Handle to the FCP clip this word belongs to |
| `clipTimelineStart` | Double | Where the clip starts on the timeline |
| `sourceMediaOffset` | Double | Offset in source media (trim start) |
| `sourceMediaPath` | String | Path to source media file |

Silences between words are stored as `SpliceKitTranscriptSilence` objects:

| Property | Type | Description |
|----------|------|-------------|
| `startTime` | Double | Silence start (end of previous word) |
| `endTime` | Double | Silence end (start of next word) |
| `duration` | Double | Duration in seconds |
| `afterWordIndex` | Int | Index of the word before this silence |

---

## Transcription Engines

The panel includes an engine selector dropdown with three options:

### Parakeet v3 (Default)

- **Model**: NVIDIA Parakeet TDT 0.6B
- **Languages**: 25 languages (multilingual)
- **Processing**: On-device via FluidAudio framework
- **Speed**: Fast — model loaded once, reused across all clips
- **Download**: Auto-downloads on first use (~600MB)
- **Speaker diarization**: Supported (macOS 26+)

### Apple Speech

- **Engine**: SFSpeechRecognizer (Speech.framework)
- **Languages**: System language
- **Processing**: On-device or network-assisted
- **Speed**: Slower than Parakeet
- **Download**: No download needed (system framework)
- **Note**: Speech.framework is loaded dynamically since FCP doesn't bundle it

### FCP Native

- **Engine**: FCP's built-in AASpeechAnalyzer
- **Processing**: On-device
- **Speed**: Fast
- **Note**: Uses FCP's own transcription pipeline

---

## Getting Started

### Via MCP (Programmatic)

```python
# Transcribe all clips on the current timeline
open_transcript()

# Transcribe a specific file
open_transcript(file_url="/path/to/video.mp4")

# Wait for transcription to complete, then get results
get_transcript()
```

### Via FCP UI

1. Open the transcript panel from SpliceKit's menu or via MCP
2. Select a transcription engine from the dropdown
3. (Optional) Enable speaker diarization checkbox
4. Transcription starts automatically for all timeline clips
5. Words appear in the text view as transcription progresses

---

## The Transcript Panel

### Text Display

The transcript is displayed as formatted text organized by speaker segments:

```
[Speaker 1] 00:00:02:00 – 00:00:08:15
Hello world this is a test of the transcription system

[...] ← 1.2s pause

[Speaker 2] 00:00:09:20 – 00:00:14:05
Yes it is working now and the quality is quite good
```

- **Speaker headers** show the speaker name and timecode range (HH:MM:SS:FF)
- **Silence markers** `[...]` appear inline between words where pauses exceed the threshold
- **Confidence coloring** — low-confidence words are visually distinguished
- **Playhead highlight** — the current word is highlighted during playback

### Interaction

| Action | Effect |
|--------|--------|
| Click a word | Jump playhead to that word's timestamp |
| Click `[...]` | Jump playhead to the silence position |
| Select words + Delete | Ripple-delete the corresponding video segment |
| Select `[...]` + Delete | Remove the pause from the timeline |
| Drag selected words | Reorder clips on the timeline |
| Cmd+F | Focus the search bar |

---

## Editing Operations

### Deleting Words (Removing Video)

Deleting words from the transcript removes the corresponding video segments from
the timeline. The operation performs:

1. Blade at the word's start time
2. Blade at the word's end time
3. Select the bladed segment
4. Ripple delete

```python
# Delete words at indices 5, 6, 7
delete_transcript_words(start_index=5, count=3)
```

This removes the video/audio from the timeline and shifts subsequent clips to
fill the gap (ripple delete behavior).

### Moving Words (Reordering Clips)

Moving words reorders the corresponding clips on the timeline:

1. Blade and cut the source segment
2. Move playhead to the destination position
3. Paste at the new location

```python
# Move words 10-11 to position 3
move_transcript_words(start_index=10, count=2, dest_index=3)
```

### Keyboard Editing in the Panel

Select words in the transcript text view using standard text selection (click
and drag, Shift+click, Cmd+A), then:

- **Delete key** — remove selected words/silences from the timeline
- **Drag** — click and drag selected text to a new position to reorder

---

## Silence Detection & Removal

The transcript panel detects gaps between words and marks them as silences.
Silences appear as `[...]` markers inline with the transcript text.

### Configuring the Threshold

The silence threshold controls the minimum gap duration to flag as a silence:

```python
# Only detect pauses longer than 1 second
set_silence_threshold(threshold=1.0)

# More sensitive — detect pauses as short as 0.3 seconds (default)
set_silence_threshold(threshold=0.3)
```

### Batch Silence Removal

Remove all detected silences in one operation:

```python
# Remove all silences
delete_transcript_silences()

# Remove only silences longer than 1 second
delete_transcript_silences(min_duration=1.0)
```

Each silence removal performs a ripple delete, tightening the edit by removing
dead air. This is especially useful for:

- Interview footage with long pauses
- Podcast editing (removing "ums" and dead air)
- Tightening talking-head videos

---

## Speaker Diarization

On macOS 26+, the transcript supports automatic speaker identification.
When enabled, the system groups words by speaker and labels each segment.

### Automatic Detection

Enable the "Speaker Diarization" checkbox in the panel UI before transcribing.
The Parakeet engine will automatically identify different speakers.

### Manual Speaker Assignment

Assign or correct speaker labels programmatically:

```python
# Label the first 50 words as "Host"
set_transcript_speaker(start_index=0, count=50, speaker="Host")

# Label words 50-100 as "Guest"
set_transcript_speaker(start_index=50, count=50, speaker="Guest")
```

Speaker segments are displayed with headers showing the speaker name and
timecode range:

```
[Host] 00:00:00:00 – 00:00:15:10
Welcome to the show today we have a special guest...

[Guest] 00:00:15:15 – 00:00:32:20
Thank you for having me it's great to be here...
```

---

## Search & Navigation

### Text Search

```python
# Search for a word or phrase
search_transcript("hello")
```

The search bar supports:
- Text search across all transcript words
- Result count with prev/next navigation
- Highlighting of matches in the transcript view

### Special Filters

```python
# Find all silences/pauses
search_transcript("pauses")
```

The panel's search UI includes filter buttons for:
- **Pauses** — show only silence markers
- **Low Confidence** — show only words with low recognition confidence

### Batch Operations on Search Results

After searching, you can delete all matching results in one operation using the
"Delete All" button in the search bar.

---

## Programmatic API

### Complete Tool Reference

| Tool | Description |
|------|-------------|
| `open_transcript()` | Open panel, transcribe timeline clips |
| `open_transcript(file_url=...)` | Transcribe a specific file |
| `get_transcript()` | Get words with timestamps, speakers, silences |
| `delete_transcript_words(start_index, count)` | Delete words (removes video) |
| `move_transcript_words(start_index, count, dest_index)` | Reorder clips |
| `search_transcript(query)` | Search text or filter by "pauses" |
| `delete_transcript_silences()` | Remove all silences |
| `delete_transcript_silences(min_duration=1.0)` | Remove silences > 1s |
| `set_transcript_speaker(start_index, count, speaker)` | Label speakers |
| `set_silence_threshold(threshold)` | Set pause detection sensitivity |
| `close_transcript()` | Close the panel |

### Transcript State

`get_transcript()` returns:

```json
{
  "status": "ready",
  "wordCount": 342,
  "words": [
    {
      "text": "Hello",
      "startTime": 2.05,
      "duration": 0.35,
      "confidence": 0.95,
      "speaker": "Speaker 1",
      "wordIndex": 0
    }
  ],
  "silences": [
    {
      "startTime": 5.2,
      "endTime": 6.8,
      "duration": 1.6,
      "afterWordIndex": 12
    }
  ],
  "fullText": "Hello world this is..."
}
```

---

## Workflows

### Quick Rough Cut from Interview

```python
# 1. Transcribe the timeline
open_transcript()

# 2. Review the transcript
transcript = get_transcript()

# 3. Remove all dead air (pauses > 0.5s)
delete_transcript_silences(min_duration=0.5)

# 4. Remove specific unwanted sections by word index
delete_transcript_words(start_index=45, count=20)

# 5. Close when done
close_transcript()
```

### Podcast Cleanup

```python
# Transcribe with sensitive silence detection
open_transcript()
set_silence_threshold(threshold=0.3)

# Label speakers
set_transcript_speaker(start_index=0, count=100, speaker="Host")
set_transcript_speaker(start_index=100, count=150, speaker="Guest")

# Remove all short pauses to tighten the edit
delete_transcript_silences(min_duration=0.5)
```

### Find and Remove Specific Content

```python
# Search for a specific phrase
results = search_transcript("um")

# Or delete words directly by index after reviewing the transcript
delete_transcript_words(start_index=23, count=1)
```

### Reorder Segments

```python
# Move the conclusion (words 200-250) to the beginning
move_transcript_words(start_index=200, count=50, dest_index=0)
```

---

*SpliceKit's transcript panel runs entirely on-device. No audio data is sent
to external servers. The Parakeet model auto-downloads on first use and runs
locally via the FluidAudio framework.*
