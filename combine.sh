#!/usr/bin/env bash
#
# combine.sh
# ----------
# All-in-one: creates a boomerang loop of a video, loops it to match
# an audio file, and overlays a fading watermark/logo.
#
# This is a convenience wrapper that chains the operations:
#   1. Create boomerang clip (forward + reverse)
#   2. Add watermark with fade-in/fade-out
#   3. Loop to match audio duration
#
# Usage:
#   ./combine.sh [-c codec] [-q crf] [-a audio-codec]
#                [-f fade-in] [-F fade-out] [-m margin] [-p position] [-s scale]
#                [--keep-boomerang] [-o output]
#                <video> <audio> <logo>
#
# Arguments:
#   video   Path to the video file (boomeranged then looped)
#   audio   Path to the audio file (sets output duration)
#   logo    Path to the logo/watermark image
#
# Flags:
#   -c, --codec        Video encoder (default: libx264)
#   -q, --crf          CRF quality (default: 23)
#   -a, --audio-codec  Audio encoder (default: aac)
#   -f, --fade-in      Watermark opacity fade-in seconds (default: 3)
#   -F, --fade-out     Watermark opacity fade-out seconds (default: 3)
#   -m, --margin       Watermark margin in pixels (default: 20)
#   -p, --position     Watermark position (default: bottom-right)
#   -s, --scale        Scale video, e.g. 1920x1080
#   --keep-boomerang   Keep intermediate boomerang file
#   -o, --output       Output file path (default: renders/<audio>.<video-ext>)
#
# Flags can go anywhere, mixed with positional args.
# Filenames starting with - are accepted as positional args if the file exists.
# Output is overwritten if it already exists (-y).
# Intermediate files in /tmp are cleaned up on exit.
# Codec/quality flags are delegated through to ffmpeg.
# See https://ffmpeg.org/ffmpeg-codecs.html for codec details.
#
# Examples:
#   ./combine.sh video.mp4 music.mp3 logo.png
#   ./combine.sh -c libx265 -q 23 video.mp4 music.mp3 logo.png
#   ./combine.sh -f 5 -m 30 -p top-right -o final.mp4 video.mp4 music.mp3 logo.png
#
# Requires: ffmpeg, ffprobe (for auto fade-out timing)
#
set -euo pipefail

usage() {
  sed -n '/^# Usage:/,/^# Requires:/p' "$0" | sed 's/^# \?//'
  exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

CODEC="libx264"
CRF="23"
AUDIO_CODEC="aac"
FADE_IN="3"
FADE_OUT="3"
MARGIN="20"
POSITION="bottom-right"
SCALE=""
KEEP_BOOMERANG=false
OUTPUT=""
POSARGS=()

# Track temp files for cleanup on exit
CLEANUP_FILES=()
cleanup() {
  for f in "${CLEANUP_FILES[@]}"; do
    rm -f "$f"
  done
}
trap cleanup EXIT

# Parse flags anywhere; unknown args starting with - are checked as files
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--codec)        CODEC="${2:?"-c requires a value"}"; shift 2 ;;
    -q|--crf)          CRF="${2:?"-q requires a value"}"; shift 2 ;;
    -a|--audio-codec)  AUDIO_CODEC="${2:?"-a requires a value"}"; shift 2 ;;
    -f|--fade-in)      FADE_IN="${2:?"-f requires a value"}"; shift 2 ;;
    -F|--fade-out)     FADE_OUT="${2:?"-F requires a value"}"; shift 2 ;;
    -m|--margin)       MARGIN="${2:?"-m requires a value"}"; shift 2 ;;
    -p|--position)     POSITION="${2:?"-p requires a value"}"; shift 2 ;;
    -s|--scale)        SCALE="${2:?"-s requires a value"}"; shift 2 ;;
    --keep-boomerang)  KEEP_BOOMERANG=true; shift ;;
    -o|--output)       OUTPUT="${2:?"-o requires a value"}"; shift 2 ;;
    -h|--help)         usage ;;
    -*)
      [[ -f "$1" ]] && { POSARGS+=("$1"); shift; continue; }
      die "unknown flag: $1"
      ;;
    *)  POSARGS+=("$1"); shift ;;
  esac
done

[[ ${#POSARGS[@]} -lt 3 ]] && usage

VIDEO="${POSARGS[0]}"
AUDIO="${POSARGS[1]}"
LOGO="${POSARGS[2]}"

[[ ! -f "$VIDEO" ]] && die "video file not found: $VIDEO"
[[ ! -f "$AUDIO" ]] && die "audio file not found: $AUDIO"
[[ ! -f "$LOGO" ]] && die "logo file not found: $LOGO"

# Validate codecs
case "$CODEC" in
  copy|libx264|libx265|libaom-av1|libvpx-vp9) ;;
  *) die "unknown video codec: $CODEC (allowed: copy libx264 libx265 libaom-av1 libvpx-vp9)" ;;
esac
case "$AUDIO_CODEC" in
  aac|libmp3lame|libopus|copy) ;;
  *) die "unknown audio codec: $AUDIO_CODEC (allowed: aac libmp3lame libopus copy)" ;;
esac

# Validate position
case "$POSITION" in
  bottom-right|bottom-left|top-right|top-left|center) ;;
  *) die "unknown position: $POSITION (allowed: bottom-right bottom-left top-right top-left center)" ;;
esac

# Validate numeric values
[[ "$CRF" =~ ^[0-9]+$ ]] || die "CRF must be a non-negative integer, got: $CRF"
[[ "$FADE_IN" =~ ^[0-9]+$ ]] || die "fade-in must be a non-negative integer, got: $FADE_IN"
[[ "$FADE_OUT" =~ ^[0-9]+$ ]] || die "fade-out must be a non-negative integer, got: $FADE_OUT"
[[ "$MARGIN" =~ ^[0-9]+$ ]] || die "margin must be a non-negative integer, got: $MARGIN"

# Validate scale format if provided
if [[ -n "$SCALE" ]]; then
  [[ "$SCALE" =~ ^[0-9]+x[0-9]+$ ]] || die "scale must be WxH format, got: $SCALE"
fi

# Default output: renders/<audio-name>.<video-ext> if renders/ exists, else ./<audio-name>.<video-ext>
if [[ -z "$OUTPUT" ]]; then
  ANAME="${AUDIO##*/}"
  ANAME="${ANAME%.*}"
  VEXT="${VIDEO##*.}"
  if [[ -d "./renders" ]]; then
    OUTPUT="./renders/${ANAME}.${VEXT}"
  else
    OUTPUT="./${ANAME}.${VEXT}"
  fi
fi
mkdir -p "$(dirname "$OUTPUT")"

VEXT="${VIDEO##*.}"
BOOMERANG_FILE=$(mktemp /tmp/boomerang_XXXXXX."${VEXT}")
CLEANUP_FILES+=("$BOOMERANG_FILE")

echo "=== Step 1/3: Create boomerang clip ==="
ffmpeg -y -i "$VIDEO" \
  -filter_complex "[0:v]split[fw][rev];[rev]reverse[rv];[fw][rv]concat=n=2:v=1:a=0" \
  -c:v "$CODEC" -crf "$CRF" -an \
  -movflags +faststart \
  "$BOOMERANG_FILE"

echo ""
echo "=== Step 2/3: Add watermark with fade ==="

# Get boomerang duration for fade-out timing
DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$BOOMERANG_FILE" 2>/dev/null | cut -d. -f1)
FADE_OUT_START=$(( DURATION - FADE_OUT ))

case "$POSITION" in
  bottom-right)  OVERLAY_POS="W-w-${MARGIN}:H-h-${MARGIN}" ;;
  bottom-left)   OVERLAY_POS="${MARGIN}:H-h-${MARGIN}" ;;
  top-right)     OVERLAY_POS="W-w-${MARGIN}:${MARGIN}" ;;
  top-left)      OVERLAY_POS="${MARGIN}:${MARGIN}" ;;
  center)        OVERLAY_POS="(W-w)/2:(H-h)/2" ;;
esac

SCALE_FILTER=""
if [[ -n "$SCALE" ]]; then
  SCALE_W="${SCALE%%x*}"
  SCALE_H="${SCALE##*x}"
  SCALE_FILTER="scale=${SCALE_W}:${SCALE_H}:force_original_aspect_ratio=decrease,pad=${SCALE_W}:${SCALE_H}:(ow-iw)/2:(oh-ih)/2,"
fi

WATERMARKED=$(mktemp /tmp/watermarked_XXXXXX."${VEXT}")
CLEANUP_FILES+=("$WATERMARKED")

ffmpeg -y -i "$BOOMERANG_FILE" -i "$LOGO" \
  -filter_complex \
    "[1:v]format=rgba,fade=t=in:st=0:d=${FADE_IN}:alpha=1,fade=t=out:st=${FADE_OUT_START}:d=${FADE_OUT}:alpha=1[wm]; \
     [0:v]${SCALE_FILTER}[main]; \
     [main][wm]overlay=${OVERLAY_POS}:shortest=1" \
  -c:v "$CODEC" -crf "$CRF" -c:a copy \
  -movflags +faststart \
  "$WATERMARKED"

echo ""
echo "=== Step 3/3: Loop to match audio ==="
ffmpeg -y -stream_loop -1 -i "$WATERMARKED" -i "$AUDIO" \
  -map 0:v:0 -map 1:a:0 \
  -c:v copy -c:a "$AUDIO_CODEC" \
  -movflags +faststart \
  -shortest \
  "$OUTPUT"

if [[ "$KEEP_BOOMERANG" == "true" ]]; then
  # Don't clean up the boomerang — remove from cleanup list
  CLEANUP_FILES=("${CLEANUP_FILES[@]/$BOOMERANG_FILE/}")
  echo "  Boomerang kept: $BOOMERANG_FILE"
fi

echo ""
echo "=== Complete: $OUTPUT ==="
