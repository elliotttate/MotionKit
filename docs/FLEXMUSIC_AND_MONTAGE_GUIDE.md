---
layout: default
title: FlexMusic & Montage Maker Guide
---

# FlexMusic & Montage Maker Guide

SpliceKit brings two iPad-exclusive features to Final Cut Pro on the Mac: **FlexMusic** (dynamic soundtracks that automatically fit any project duration) and **Montage Maker** (auto-edit clips to the beat of a song).

Both features work entirely through SpliceKit's programmatic interface — no UI panels, no mouse clicks. Every operation is a direct ObjC call into FCP's process.

---

## Table of Contents

- [How It Works](#how-it-works)
- [FlexMusic: Dynamic Soundtracks](#flexmusic-dynamic-soundtracks)
  - [Browse the Song Library](#browse-the-song-library)
  - [Inspect a Song](#inspect-a-song)
  - [Get Beat Timing for Any Duration](#get-beat-timing-for-any-duration)
  - [Render a Song to Audio](#render-a-song-to-audio)
  - [Add Music to the Timeline](#add-music-to-the-timeline)
- [Montage Maker: Auto-Edit to Beat](#montage-maker-auto-edit-to-beat)
  - [Step-by-Step Montage Workflow](#step-by-step-montage-workflow)
  - [One-Shot Auto-Montage](#one-shot-auto-montage)
- [Recipes & Use Cases](#recipes--use-cases)
  - [Score a Rough Cut to Music](#score-a-rough-cut-to-music)
  - [Travel Montage from Photos and Clips](#travel-montage-from-photos-and-clips)
  - [Social Media Cut to Beat](#social-media-cut-to-beat)
  - [Music Video Style Quick Cuts](#music-video-style-quick-cuts)
  - [Use Beat Timing with Your Own Audio](#use-beat-timing-with-your-own-audio)
  - [Preview Multiple Songs Against the Same Edit](#preview-multiple-songs-against-the-same-edit)
  - [Export Stems for External DAW](#export-stems-for-external-daw)
- [Technical Reference](#technical-reference)
  - [FlexMusic API](#flexmusic-api)
  - [Montage API](#montage-api)
  - [Cut Styles](#cut-styles)
  - [Song Metadata Fields](#song-metadata-fields)
  - [How FlexMusic Fitting Works](#how-flexmusic-fitting-works)

---

## How It Works

Apple ships a private framework called **FlexMusicKit** on every Mac. It contains a library of royalty-free songs, each stored as segmented audio with metadata describing intros, body sections, outros, and transition points. A fitting algorithm assembles these segments to precisely match any target duration while maintaining musical coherence — the song expands, contracts, loops, or rearranges itself to fit.

Final Cut Pro already weak-links this framework and has the internal plumbing (`FFFlexMusicLibrary`, `FFAnchoredFlexMusicObject`, beat detection) but never exposes it to users on the Mac. SpliceKit makes it accessible.

The **Montage Maker** combines FlexMusic timing data with clip analysis to automatically cut a sequence of clips to the rhythm of a chosen song, complete with transitions and background music.

---

## FlexMusic: Dynamic Soundtracks

### Browse the Song Library

List all available songs:

```python
flexmusic_list_songs()
```

Filter by keyword:

```python
flexmusic_list_songs(filter="upbeat")
flexmusic_list_songs(filter="cinematic")
flexmusic_list_songs(filter="ambient")
```

Each song returns:
- **uid** — unique identifier (use this for all other calls)
- **name** — song title
- **artist** — artist name  
- **mood** — emotional character (e.g., "Uplifting", "Reflective", "Energetic")
- **pace** — tempo feel (e.g., "Medium", "Fast", "Slow")
- **genres** — musical genres
- **naturalDuration** — the song's default duration in seconds

### Inspect a Song

Get detailed metadata for a specific song:

```python
flexmusic_get_song(song_uid="com.apple.flexmusic.song-12345")
```

Returns everything from `list_songs` plus:
- **minimumDuration** — shortest possible arrangement
- **idealDurations** — durations where the song fits most naturally
- **arousal** — energy level (low to high)
- **valence** — mood positivity (negative to positive)
- **format** — "Legacy" or "ML" (newer ML-based arrangement)

### Get Beat Timing for Any Duration

This is where FlexMusic becomes powerful. Ask for the exact beat, bar, and section timestamps of a song fitted to any specific duration:

```python
flexmusic_get_timing(
    song_uid="com.apple.flexmusic.song-12345",
    duration_seconds=45.0
)
```

Returns:
```json
{
  "beats": [0.0, 0.5, 1.0, 1.5, 2.0, ...],
  "bars": [0.0, 2.0, 4.0, 6.0, 8.0, ...],
  "sections": [0.0, 8.0, 24.0, 36.0, 44.0],
  "fittedDuration": 45.2,
  "beatCount": 90,
  "barCount": 23,
  "sectionCount": 5
}
```

- **beats** — every single beat (usually 1/4 notes). Fastest cuts.
- **bars** — every measure (usually 4 beats). Natural pacing for most edits.
- **sections** — musical phrases (intro, verse, chorus, outro). Longest segments.

The song is dynamically rearranged to fit 45 seconds. The timestamps are exact — you can blade clips precisely at these points.

### Render a Song to Audio

Export the fitted song as a standard audio file:

```python
flexmusic_render_to_file(
    song_uid="com.apple.flexmusic.song-12345",
    duration_seconds=60.0,
    output_path="/tmp/my_soundtrack.m4a",
    format="m4a"
)
```

Formats: `"m4a"` (AAC, smaller) or `"wav"` (lossless, larger).

The output file is a fully mixed, broadcast-ready audio track with proper intro, body, and outro sections — all fitted to exactly the requested duration. You can import this into any project or DAW.

### Add Music to the Timeline

Add a FlexMusic track directly to the current FCP timeline:

```python
flexmusic_add_to_timeline(
    song_uid="com.apple.flexmusic.song-12345",
    duration_seconds=90.0
)
```

If `duration_seconds` is 0 or omitted, it automatically matches the current timeline duration.

Under the hood, this renders the song to a temporary file and imports it via FCPXML as a background audio clip.

---

## Montage Maker: Auto-Edit to Beat

The Montage Maker analyzes your clips, selects a song, gets the beat timing, and assembles everything into a finished sequence — clips cut to the rhythm, transitions between them, and the song as background music.

### Step-by-Step Montage Workflow

For full control, use the individual steps:

**Step 1: Analyze your clips**

```python
montage_analyze_clips(event_name="Vacation 2025")
```

Returns every clip in the event, scored by quality:
- Videos score higher than photos
- Longer clips score higher (more usable material)
- Each clip gets a handle you'll use in later steps

**Step 2: Pick a song and get timing**

```python
# Browse songs
flexmusic_list_songs(filter="upbeat")

# Get timing fitted to your desired montage length
flexmusic_get_timing(
    song_uid="com.apple.flexmusic.song-12345",
    duration_seconds=30.0
)
```

**Step 3: Plan the edit**

```python
montage_plan_edit(
    beats='[0.0, 2.0, 4.0, 6.0, 8.0, ...]',     # bar timestamps from step 2
    clips='[{"handle":"obj_1","duration":15.2,"score":25}, ...]',  # from step 1
    style="bar",
    total_duration=30.0
)
```

Returns an edit decision list (EDL):
```json
{
  "editPlan": [
    {"clipHandle": "obj_1", "clipName": "Beach sunset", "inSeconds": 3.0, "outSeconds": 5.0,
     "timelineStart": 0.0, "duration": 2.0},
    {"clipHandle": "obj_5", "clipName": "Walking trail", "inSeconds": 0.0, "outSeconds": 2.0,
     "timelineStart": 2.0, "duration": 2.0},
    ...
  ]
}
```

You can inspect and modify this plan before assembling — reorder clips, swap handles, adjust in/out points.

**Step 4: Render the song**

```python
flexmusic_render_to_file(
    song_uid="com.apple.flexmusic.song-12345",
    duration_seconds=30.0,
    output_path="/tmp/montage_music.m4a"
)
```

**Step 5: Assemble the montage**

```python
montage_assemble(
    edit_plan='[...]',          # the EDL from step 3
    project_name="Summer 2025",
    song_file="/tmp/montage_music.m4a"
)
```

This generates FCPXML with:
- Every clip placed at its assigned timeline position
- Cross Dissolve transitions between clips (0.5 seconds)
- The rendered song as a connected audio clip
- Proper frame rates and timecodes

The FCPXML is imported into FCP as a new project, ready to play.

### One-Shot Auto-Montage

For the fast path, one call does everything:

```python
montage_auto(
    song_uid="com.apple.flexmusic.song-12345",
    event_name="Vacation 2025",
    style="bar",
    project_name="Summer Montage"
)
```

This orchestrates the full pipeline: analyze clips → get timing → plan edit → render song → assemble timeline.

If you don't know which song to use, browse first:

```python
flexmusic_list_songs(filter="happy")
# Pick one from the results, then:
montage_auto(song_uid="...", event_name="My Event")
```

---

## Recipes & Use Cases

### Score a Rough Cut to Music

You already have clips on the timeline and want to add a soundtrack that perfectly matches the length:

```python
# Check current timeline duration
get_timeline_clips()
# Suppose it's 2 minutes 15 seconds (135s)

# Find a matching song
flexmusic_list_songs(filter="documentary")

# Add it — duration auto-matches the timeline
flexmusic_add_to_timeline(song_uid="com.apple.flexmusic.song-XYZ")
```

The song dynamically arranges itself to exactly 135 seconds with a proper intro and outro.

### Travel Montage from Photos and Clips

You imported 50 clips and photos from a trip. Turn them into a 60-second highlight reel:

```python
montage_auto(
    song_uid="com.apple.flexmusic.song-upbeat-01",
    event_name="Japan Trip",
    style="bar",
    project_name="Japan Highlights"
)
```

Each bar of the song (~2 seconds) gets the next best clip. Photos get a brief duration, videos use their most interesting segment (center of the clip by default).

### Social Media Cut to Beat

Make a fast-paced 15-second reel with cuts on every beat:

```python
# Get beat timing for 15 seconds
timing = flexmusic_get_timing(song_uid="...", duration_seconds=15.0)

# Analyze clips
clips = montage_analyze_clips(event_name="Product Shots")

# Plan with beat-level cuts (fastest)
plan = montage_plan_edit(
    beats='[0.0, 0.5, 1.0, 1.5, ...]',  # every beat
    clips='[...]',
    style="beat",
    total_duration=15.0
)

# Render and assemble
flexmusic_render_to_file(song_uid="...", duration_seconds=15.0, output_path="/tmp/reel_music.m4a")
montage_assemble(edit_plan='[...]', project_name="Product Reel", song_file="/tmp/reel_music.m4a")
```

### Music Video Style Quick Cuts

Get beat timing and use it to manually blade an existing edit:

```python
# Get beats for your song duration
timing = flexmusic_get_timing(song_uid="...", duration_seconds=180.0)

# Use the beat timestamps to blade at exact positions
# Each beat is a precise frame position
playback_action("goToStart")

# Navigate to each beat and blade
for beat_time in timing["beats"]:
    # Seek to the beat timestamp
    playback_action("seekToTime", time=beat_time)
    timeline_action("blade")
```

### Use Beat Timing with Your Own Audio

You don't have to use FlexMusic songs for the final audio. Use the timing data as a cutting guide, then swap in your own music:

```python
# Get timing from a FlexMusic song that matches your vibe
timing = flexmusic_get_timing(song_uid="...", duration_seconds=60.0)

# Build montage using those beat/bar positions
montage_plan_edit(beats=timing["bars"], clips='[...]', style="bar")

# Assemble WITHOUT a song file
montage_assemble(edit_plan='[...]', project_name="My Edit", song_file="")

# Then import your own music manually
```

The bar/beat timing gives you a rhythmic structure to cut against, even if the final soundtrack is something else.

### Preview Multiple Songs Against the Same Edit

Render several songs and compare:

```python
songs = flexmusic_list_songs()

# Render 3 candidates at the same duration
for song in songs[:3]:
    flexmusic_render_to_file(
        song_uid=song["uid"],
        duration_seconds=45.0,
        output_path=f"/tmp/preview_{song['name']}.m4a"
    )
```

Import each into the same project as separate audio tracks, mute/solo to compare.

### Export Stems for External DAW

Render a FlexMusic track as lossless WAV for use in Logic Pro, Pro Tools, or any DAW:

```python
flexmusic_render_to_file(
    song_uid="com.apple.flexmusic.song-XYZ",
    duration_seconds=120.0,
    output_path="~/Desktop/soundtrack_120s.wav",
    format="wav"
)
```

The rendered file has the full arrangement baked in — proper intro, body loops/variations, and outro — all fitted to exactly 120 seconds.

---

## Technical Reference

### FlexMusic API

| Tool | JSON-RPC Method | Description |
|------|----------------|-------------|
| `flexmusic_list_songs(filter)` | `flexmusic.listSongs` | Browse available songs with optional keyword filter |
| `flexmusic_get_song(song_uid)` | `flexmusic.getSong` | Detailed metadata, durations, mood/energy scores |
| `flexmusic_get_timing(song_uid, duration_seconds)` | `flexmusic.getTiming` | Beat/bar/section timestamps for a fitted duration |
| `flexmusic_render_to_file(song_uid, duration_seconds, output_path, format)` | `flexmusic.renderToFile` | Export fitted song as M4A or WAV |
| `flexmusic_add_to_timeline(song_uid, duration_seconds)` | `flexmusic.addToTimeline` | Add song to current timeline as background audio |

### Montage API

| Tool | JSON-RPC Method | Description |
|------|----------------|-------------|
| `montage_analyze_clips(event_name)` | `montage.analyzeClips` | Score browser clips for montage quality |
| `montage_plan_edit(beats, clips, style, total_duration)` | `montage.planEdit` | Generate edit decision list from timing + clips |
| `montage_assemble(edit_plan, project_name, song_file)` | `montage.assemble` | Build timeline from EDL via FCPXML import |
| `montage_auto(song_uid, event_name, style, project_name)` | `montage.auto` | Full automated pipeline in one call |

### Cut Styles

The `style` parameter controls how clips are assigned to musical boundaries:

| Style | Cut Frequency | Best For |
|-------|--------------|----------|
| `"beat"` | Every beat (~0.5s at 120 BPM) | Fast-paced reels, music videos, action |
| `"bar"` | Every measure (~2s at 120 BPM) | Most montages, travel edits, highlights |
| `"section"` | At phrase boundaries (~8-16s) | Slow builds, documentary, narrative |

### Song Metadata Fields

| Field | Type | Description |
|-------|------|-------------|
| `uid` | string | Unique song identifier |
| `name` | string | Song title |
| `artist` | string | Artist name |
| `mood` | string | Emotional character ("Uplifting", "Dark", "Playful", etc.) |
| `pace` | string | Tempo feel ("Slow", "Medium", "Fast") |
| `genres` | array | Musical genres |
| `arousal` | string | Energy level |
| `valence` | string | Mood positivity |
| `naturalDuration` | number | Default duration in seconds |
| `minimumDuration` | number | Shortest possible arrangement |
| `idealDurations` | array | Durations where the song sounds most natural |
| `format` | string | "Legacy" (segment-based) or "ML" (neural arrangement) |

### How FlexMusic Fitting Works

FlexMusic songs aren't simple loops. Each song is composed of discrete segments:

1. **Intro** — opening bars that establish the mood
2. **Body segments** — the main musical content, available in multiple variations
3. **Transitions** — crossfade sections between body segments
4. **Outro** — closing bars with optional stinger or early fade

The fitting algorithm (`FMSong.renditionForDuration:withOptions:`) does the following:

1. Reserves space for the intro and outro
2. Fills the remaining duration with body segments, choosing variations to avoid repetition
3. Inserts transitions between segments for smooth flow
4. If the song needs to be longer than its natural material, it loops body segments
5. Applies crossfade mix parameters between the two rendered tracks (A/B mixing)

The output is an `FMSongRendition` containing two audio tracks with volume automation, which when mixed produce a seamless, broadcast-quality soundtrack that sounds like it was composed for exactly that duration.

**ML-format songs** (newer) use pre-computed summaries at various durations (`FlexMLSummary`), providing video cue points that suggest ideal cut positions. Legacy-format songs use the segment assembly algorithm described above.

---

*FlexMusic and Montage Maker are powered by Apple's FlexMusicKit private framework and FCP's internal editing engine, accessed programmatically via SpliceKit.*
