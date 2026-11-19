# Setlist

A clean, native macOS playback deck for concerts, recitals, and events. Build
playlists, match their loudness, and run the show live — Space plays the cued
track, and nothing starts that you didn't ask for.

![Setlist icon](logo/setlist-icon.svg)

## Download

Grab **Setlist.zip** from the [latest release](https://github.com/bramwellfreeman/setlist/releases/latest),
unzip, and drag **Setlist** into Applications. Universal (Apple Silicon + Intel),
macOS 14 or later.

Setlist is signed ad-hoc rather than notarized, so the first time you open it
macOS will warn you: right-click the app → **Open** → **Open**. (Or System
Settings → Privacy & Security → **Open Anyway**.) After that it opens normally.

## What it does

**Running the show**
- **Cue-based playback** — when a track ends, the next one is cued (highlighted)
  rather than auto-played; press Space to start it. Or switch a playlist to
  **gapless** or **crossfade** (2–8 s) to play straight through.
- **Space = pause, or stop & cue** (per playlist), with an optional **fade-out**
  (1–5 s) when stopping. Press Space again mid-fade to stop immediately.
- **Waveform scrubber** — the playing track's waveform with a playhead; click or
  drag anywhere to jump there (stays paused if you're paused).
- **Show lock** — one click locks out editing, reordering, deleting, and
  double-click starts; only selection and the transport still work.
- **Output device per playlist** — send a show to a specific interface;
  falls back to the system output (and says so) if it's unplugged.
- Keeps the display awake while a track is loaded or the show is locked, and
  recovers if the audio device changes mid-show.

**Preparing**
- **Playlists and sub-playlists** — nest them (Spring Recital › Act I), collapse,
  and drag playlists to reorder, nest, or pull them out.
- **Move songs between playlists** — right-click → Move to, or drag a song onto
  a playlist in the sidebar.
- **Loudness matching (EBU R128 / ITU-R BS.1770)** — Analyze & Match measures
  each track's integrated LUFS and gains it to the target (−23 / −18 / −16 / −14).
- **Waveform trim** — drag start/end handles to cut silence or pick a section.
- **Notes** — for the playlist (show notes) and for each track (cue notes, shown
  in the transport when that track is live or cued).
- **Video files** — add MP4/MOV/M4V; the soundtrack is extracted losslessly and
  played like any audio track. The video is never modified.
- **Missing files** — relink one file and its neighbours follow, or search a
  whole folder.
- Per-track gain, skip, live master/track volume, `.setlist` import/export, and
  fully customizable keyboard shortcuts (⌘,).

## Build from source

```bash
./build.sh          # release, universal → dist/Setlist.app
./build.sh debug    # fast local build
./build.sh zip      # release + dist/Setlist.zip (for a GitHub release)
open dist/Setlist.app
```

Swift 6 toolchain (Xcode 16+). A SwiftPM executable assembled into an `.app`
bundle. The library is saved to `~/Library/Application Support/Setlist/library.json`.

### Layout

- `AudioController.swift` — two-deck AVAudioEngine playback
  (`player → mixer → EQ gain → main mixer`), fades, crossfade, sample-accurate
  gapless hand-off, output-device selection
- `AppState.swift` — library, queue and continue logic, analysis, sub-playlists,
  relinking, persistence, import/export
- `Loudness.swift` — BS.1770 K-weighting + gated integrated loudness
- `Waveform.swift` — cached peak envelopes, scrubber and trimmer views
- `AudioExtractor.swift` — video soundtrack → Apple Lossless
- `ContentView.swift` — sidebar, track list, transport card, track sheet
- `SelfTest.swift` — scripted checks (`SETLIST_SELFTEST=1…4` with
  `SETLIST_LIBRARY=<scratch library>`), and `SETLIST_SNAPSHOT` for window renders
