# Video Scripts

FFmpeg-based shell scripts for video/audio manipulation. Each script is self-contained, does one thing, and configures via flags.

## Requirements

- [ffmpeg](https://ffmpeg.org/)
- [ffprobe](https://ffmpeg.org/ffprobe.html) (bundled with ffmpeg)

## Scripts

| Script | Purpose |
|---|---|
| `audio-loop-video.sh` | Loop video to match audio duration, replace soundtrack |
| `boomerang.sh` | Create forward ↔ backward boomerang clip |
| `watermark.sh` | Add logo/watermark with fade in/out _(experimental)_ |
| `combine.sh` | All-in-one: boomerang + watermark + audio loop _(experimental)_ |

## Quick Start

```bash
chmod +x scripts/*.sh

# Loop video to match audio — H.264, QuickTime-compatible
./scripts/audio-loop-video.sh music.mp3 bg.mp4

# Trim audio from 1:30 to 45:00 with auto 40ms fades
./scripts/audio-loop-video.sh -s 00:01:30 -e 00:45:00 music.mp3 bg.mp4

# Trim with custom 100ms fade
./scripts/audio-loop-video.sh -s 00:01:30 -e 00:45:00 -f 0.1 music.mp3 bg.mp4

# Fast copy, no re-encode (may not work in QuickTime)
./scripts/audio-loop-video.sh -c copy music.mp3 bg.mp4

# Colour LFO — one hue rotation across the whole video
./scripts/audio-loop-video.sh --color hue music.mp3 bg.mp4

# Hardware encode — several × realtime on macOS, CPU free
./scripts/audio-loop-video.sh -c h264_videotoolbox -Q 60 music.mp3 bg.mp4

# Bar-synced colour LFO (64-bar hue, 32-bar sat @ 128 BPM)
./scripts/audio-loop-video.sh --bpm 128 --bars 64 --color hue,sat:0.1:32 music.mp3 bg.mp4

# Render settings saved in a config file
./scripts/audio-loop-video.sh --config show.conf

# Boomerang clip
./scripts/boomerang.sh clip.mp4

# Add watermark (experimental)
./scripts/watermark.sh video.mp4 logo.png

# Everything combined (experimental)
./scripts/combine.sh video.mp4 music.mp3 logo.png
```

## Script Details

### audio-loop-video.sh

Loops a video infinitely, then trims to match the audio file duration. The video's original soundtrack is replaced entirely.

```bash
./scripts/audio-loop-video.sh [options] <audio> <video>
```

| Arg | Description | Default |
|---|---|---|
| `audio` | Audio file (sets output duration) | *required* |
| `video` | Video file (looped to match audio) | *required* |

| Flag | Description | Default |
|---|---|---|
| `-c`, `--codec` | Video encoder | `libx264` (H.264, QuickTime-compatible) |
| `-q`, `--crf` | CRF quality, 0–51, lower = better (software encoders only) | `23` |
| `-Q`, `--video-quality` | Hardware encoder quality, 1–100, higher = better (`h264_videotoolbox`/`hevc_videotoolbox` only) | unset (encoder default) |
| `-a`, `--audio-codec` | Audio encoder | `aac` |
| `-o`, `--output` | Output path | `renders/<audio>.<video-ext>` |
| `-s`, `--start` | Trim audio start: `HH:MM:SS` or seconds | — |
| `-e`, `--end` | Trim audio end: `HH:MM:SS` or seconds | — |
| `-f`, `--fade` | Fade-in/out duration, seconds | `0.04` (40ms) |
| `-C`, `--color` | Colour LFO presets, comma-separated (see Colour effects) | — |
| `--color-raw` | Raw ffmpeg colour filter expression, `t` in seconds | — |
| `--bpm` | Tempo for bar-synced LFOs, beats per minute | `120` |
| `--bars` | Global LFO period, in 4/4 bars (per-preset periods override) | whole output |
| `--config` | Read args from a config file (`@file` also accepted) | — |
| `--audio`, `--video` | Long-name aliases for the positional audio/video args | — |

When `--start` or `--end` is provided, a fade-in and fade-out are applied automatically to avoid clicks at the trim points. Use `--fade` to customise the fade length.

Codec and quality flags are passed through to ffmpeg. See [ffmpeg codecs](https://ffmpeg.org/ffmpeg-codecs.html) for details.

**Encoder settings.** `--codec` selects the video encoder: `libx264` (H.264, default) is the most compatible; `libx265` (HEVC) gives better quality per byte for long videos. `--crf` (Constant Rate Factor) is a perceptual quality target roughly 0–51: lower = higher quality + larger file. `18`–`20` is near-lossless, `23` (the default) is libx264's sweet spot, `28+` starts to look blocky. CRF only applies when re-encoding (it is ignored with `-c copy`). The macOS hardware encoders `h264_videotoolbox`/`hevc_videotoolbox` use `-Q/--video-quality` (1–100, higher = better) instead of `-crf`; passing `-q/--crf` to a hardware codec (or `-Q` to a software one) errors with a pointer to the right flag.

**Speed vs quality.** Suggested settings, fastest first:

| Setting | Speed vs default | Trade-off | Usable via script? |
|---|---|---|---|
| `-c h264_videotoolbox -Q 60` (macOS hardware) | several × realtime, CPU idle | near-identical quality, similar file size | yes |
| `-c hevc_videotoolbox -Q 60` (macOS hardware) | several × realtime, CPU idle | near-identical quality, smaller file | yes |
| `-c libx264 -q 23` (default) | baseline | most compatible; great quality | yes |
| `-c libx265 -q 23` | ~2–4× more CPU | smaller file at same quality | yes |
| `-c libvpx-vp9` / `-c libaom-av1` | much slower | smallest files, heaviest CPU | yes |
| ffmpeg `-preset veryfast` + `-crf 23` | ~2× faster | same quality, slightly larger file | no — run ffmpeg directly |

#### Colour effects (LFO)

`--color` applies a subtle time-based colour effect to the video, evaluated per frame from the filter timestamp — so it drifts across the whole output with no extra render pass (the effect rides on the same encode). Each preset is a sine LFO; expressions use ffmpeg's expression language, where `t` is the running timestamp in seconds and `PI`/`2*PI` are available.

Preset syntax (`:params` optional):

| Preset | Effect | Strength (units) | Period |
|---|---|---|---|
| `hue[:deg[:period]]` | Colour-wheel rotation | `deg`: hue rotation per LFO cycle, degrees (default `360` = one full rotation) | `period` |
| `temp[:amplitude[:period]]` | Warm ↔ cool drift | `amplitude`: red up / blue down gamma swing, dimensionless fraction 0–1 (default `0.05` = ±5%) | `period` |
| `sat[:delta[:period]]` | Saturation pulse | `delta`: saturation swing, dimensionless fraction 0–1 (default `0.15` = ±15%) | `period` |
| `balance[:amount[:period]]` | Green/magenta breathing | `amount`: green gamma swing, dimensionless fraction 0–1 (default `0.12` = ±12%) | `period` |

`period` (LFO cycle length) is either:
- `whole` (default) — one cycle across the **entire output duration**, in seconds, sized from the audio file; or
- a **bar count** (positive integer) synced to `--bpm` (default `120`), converted to seconds by `period_seconds = bars × 240 / bpm` (assumes 4/4 time).

`--bars` sets the period for any preset that doesn't specify its own. Precedence: **per-preset period > `--bars` > `whole`**.

```bash
# one colour rotation across the whole video
./scripts/audio-loop-video.sh --color hue music.mp3 bg.mp4

# warm/cool drift once over the whole video
./scripts/audio-loop-video.sh --color temp:0.08 music.mp3 bg.mp4

# bar-synced: hue per 64 bars, saturation per 32 bars
./scripts/audio-loop-video.sh --bpm 128 --bars 64 --color hue,sat:0.1:32 music.mp3 bg.mp4

# 60° hue shift per 16 bars
./scripts/audio-loop-video.sh --bpm 128 --color hue:60:16 music.mp3 bg.mp4

# raw expression escape hatch (e.g. per-loop sync via mod(t, ...))
./scripts/audio-loop-video.sh --color-raw 'hue=H=2*PI*t/7200' music.mp3 bg.mp4
```

Notes: colour effects force re-encoding, so they cannot be combined with `-c copy`. Timestamps run continuously across the video loop, so the LFO stays phase-locked in time rather than resetting at each loop boundary; use `mod(t, <loop-length>)` in `--color-raw` if you want per-loop sync.

#### Config files

`--config <file>` reads command-line arguments from a plain-text file (the curl `-K`/`--config` convention) so a whole render's settings can be saved per show and reused. `@<file>` is accepted as an alias.

- One option per line, with its value on the same line: `--codec libx265`
- `#` comments and blank lines are ignored
- Long option names may omit the leading dashes: `codec = libx265`
- Lines that are not options are treated as positional arguments; `--audio`/`--video` also work
- Multiple `--config` files allowed, including nested ones; `--config -` reads from stdin
- Contents expand in place; later arguments win, so CLI flags after `--config` override the file

Example `show.conf`:

```
# 2026-08-01 render
--codec libx265
--crf 23
--bpm 128
--bars 64
--color hue,sat:0.1:32
--output renders/08-01-final.mp4
--audio music.mp3
--video bg.mp4
```

```bash
./scripts/audio-loop-video.sh --config show.conf
./scripts/audio-loop-video.sh --config show.conf -o preview.mp4  # CLI wins
```

See `example.conf` in the repo for a commented template.

### boomerang.sh

Creates a boomerang clip by concatenating the original video with its reversed copy. The output plays forward, then backward, seamlessly.

```bash
./scripts/boomerang.sh [-c codec] [-q crf] [-o output] <video>
```

| Arg | Description | Default |
|---|---|---|
| `video` | Source video | *required* |

| Flag | Description | Default |
|---|---|---|
| `-c`, `--codec` | Video encoder | `libx264` |
| `-q`, `--crf` | CRF quality | `23` |
| `-o`, `--output` | Output path | `renders/<video>-boomerang.<ext>` |

Codec and quality flags are passed through to ffmpeg. See [ffmpeg codecs](https://ffmpeg.org/ffmpeg-codecs.html) for details.

### watermark.sh _(experimental)_

Overlays a logo image onto a video with configurable fade-in and fade-out effects. Supports multiple positions.

```bash
./scripts/watermark.sh [-c codec] [-q crf] [-f fade-in] [-F fade-out]
                       [-m margin] [-p position] [-s scale] [-o output]
                       <video> <logo>
```

| Arg | Description | Default |
|---|---|---|
| `video` | Video file | *required* |
| `logo` | Logo image (PNG with transparency recommended) | *required* |

| Flag | Description | Default |
|---|---|---|
| `-c`, `--codec` | Video encoder | `libx264` |
| `-q`, `--crf` | CRF quality | `23` |
| `-f`, `--fade-in` | Watermark opacity fade-in (seconds) | `3` |
| `-F`, `--fade-out` | Watermark opacity fade-out (seconds) | `3` |
| `-m`, `--margin` | Margin in pixels from edges | `20` |
| `-p`, `--position` | `bottom-right`, `bottom-left`, `top-right`, `top-left`, `center` | `bottom-right` |
| `-s`, `--scale` | Scale video before overlay, e.g. `1920x1080` | no scaling |
| `-o`, `--output` | Output path | `renders/<video>-watermarked.<ext>` |

Codec and quality flags are passed through to ffmpeg. See [ffmpeg codecs](https://ffmpeg.org/ffmpeg-codecs.html) for details.

### combine.sh _(experimental)_

All-in-one pipeline: creates a boomerang clip, adds a fading watermark, then loops to match audio duration. Intermediate files in `/tmp` are cleaned up on exit.

```bash
./scripts/combine.sh [-c codec] [-q crf] [-a audio-codec]
                     [-f fade-in] [-F fade-out] [-m margin] [-p position] [-s scale]
                     [--keep-boomerang] [-o output]
                     <video> <audio> <logo>
```

| Arg | Description | Default |
|---|---|---|
| `video` | Source video (boomeranged then looped) | *required* |
| `audio` | Audio file (sets output duration) | *required* |
| `logo` | Logo/watermark image | *required* |

| Flag | Description | Default |
|---|---|---|
| `-c`, `--codec` | Video encoder | `libx264` |
| `-q`, `--crf` | CRF quality | `23` |
| `-a`, `--audio-codec` | Audio encoder | `aac` |
| `-f`, `--fade-in` | Watermark opacity fade-in (seconds) | `3` |
| `-F`, `--fade-out` | Watermark opacity fade-out (seconds) | `3` |
| `-m`, `--margin` | Watermark margin (pixels) | `20` |
| `-p`, `--position` | Watermark position | `bottom-right` |
| `-s`, `--scale` | Scale video, e.g. `1920x1080` | no scaling |
| `--keep-boomerang` | Keep intermediate boomerang file | off |
| `-o`, `--output` | Output path | `renders/<audio>.<video-ext>` |

Codec and quality flags are passed through to ffmpeg. See [ffmpeg codecs](https://ffmpeg.org/ffmpeg-codecs.html) for details.

## Tips

- **Fast iteration:** Use `-c copy` in `audio-loop-video.sh` when the video codec is already compatible — avoids re-encoding. Note: output may not work in QuickTime.
- **Transparency:** Use PNG logos for watermark transparency. JPG logos will have a solid background.
- **Boomerang quality:** The boomerang script re-encodes to ensure frame-level precision for the reverse. Use `--keep-boomerang` in `combine.sh` to inspect the intermediate file.
- **Cleanup:** Intermediate files in `/tmp` are cleaned up automatically on script exit. Use `--keep-boomerang` to retain them for debugging.
