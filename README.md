# Simple Video Loop FFmpeg Scripts

Shell scripts for easily producing atmospheric videos for DJ mixes from short video loops. Works great with high-definition phone videos. 

[Example](https://cartoonbeats.com/radio/2026/07/version-reality-jul-26/): 

https://www.youtube.com/embed/8vfvAQUJK4g?si=OWiLlClgObkbIOjt

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
| `-q`, `--crf` | CRF quality | `23` |
| `-a`, `--audio-codec` | Audio encoder | `aac` |
| `-o`, `--output` | Output path | `renders/<audio>.<video-ext>` |
| `-s`, `--start` | Trim audio start time (e.g. `00:01:30`) | — |
| `-e`, `--end` | Trim audio end time (e.g. `00:45:00`) | — |
| `-f`, `--fade` | Fade duration in seconds (auto-applied when trimming) | `0.04` (40ms) |

When `--start` or `--end` is provided, a fade-in and fade-out are applied automatically to avoid clicks at the trim points. Use `--fade` to customise the fade length.

Codec and quality flags are passed through to ffmpeg. See [ffmpeg codecs](https://ffmpeg.org/ffmpeg-codecs.html) for details.

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

- **Recommended codec:** `-c libx265 -q 23` gives the best quality per byte for long videos.
- **Fast iteration:** Use `-c copy` in `audio-loop-video.sh` when the video codec is already compatible — avoids re-encoding. Note: output may not work in QuickTime.
- **Transparency:** Use PNG logos for watermark transparency. JPG logos will have a solid background.
- **Boomerang quality:** The boomerang script re-encodes to ensure frame-level precision for the reverse. Use `--keep-boomerang` in `combine.sh` to inspect the intermediate file.
- **Cleanup:** Intermediate files in `/tmp` are cleaned up automatically on script exit. Use `--keep-boomerang` to retain them for debugging.
