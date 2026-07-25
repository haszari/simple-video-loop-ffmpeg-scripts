#!/usr/bin/env bash
#
# watermark.sh
# ------------
# Adds a watermark/logo image to a video with configurable fade-in and
# fade-out effects. The logo is positioned with configurable margins.
#
# Usage:
#   ./watermark.sh [-c codec] [-q crf] [-f fade-in] [-F fade-out]
#                  [-m margin] [-p position] [-s scale] [-o output]
#                  <video> <logo>
#
# Arguments:
#   video   Path to the video file
#   logo    Path to the logo/watermark image (PNG with transparency recommended)
#
# Flags:
#   -c, --codec       Video encoder (default: libx264)
#   -q, --crf         CRF quality (default: 23)
#   -f, --fade-in     Watermark opacity fade-in duration in seconds (default: 3)
#   -F, --fade-out    Watermark opacity fade-out duration in seconds (default: 3)
#   -m, --margin      Margin in pixels from edges (default: 20)
#   -p, --position    Logo position: bottom-right, bottom-left, top-right,
#                     top-left, center (default: bottom-right)
#   -s, --scale       Scale video before overlay, e.g. 1920x1080
#   -o, --output      Output file path (default: renders/<video>-watermarked.<ext>)
#
# Flags can go anywhere, mixed with positional args.
# Filenames starting with - are accepted as positional args if the file exists.
# Output is overwritten if it already exists (-y).
# Codec/quality flags are delegated through to ffmpeg.
# See https://ffmpeg.org/ffmpeg-codecs.html for codec details.
#
# Examples:
#   ./watermark.sh video.mp4 logo.png
#   ./watermark.sh -f 5 -F 5 -p top-left -m 10 video.mp4 logo.png
#   ./watermark.sh -s 1920x1080 -o out.mp4 video.mp4 logo.png
#
# Requires: ffmpeg
#
set -euo pipefail

usage() {
  sed -n '/^# Usage:/,/^# Requires:/p' "$0" | sed 's/^# \?//'
  exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

CODEC="libx264"
CRF="23"
FADE_IN="3"
FADE_OUT="3"
MARGIN="20"
POSITION="bottom-right"
SCALE=""
OUTPUT=""
POSARGS=()

# Parse flags anywhere; unknown args starting with - are checked as files
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--codec)     CODEC="${2:?"-c requires a value"}"; shift 2 ;;
    -q|--crf)       CRF="${2:?"-q requires a value"}"; shift 2 ;;
    -f|--fade-in)   FADE_IN="${2:?"-f requires a value"}"; shift 2 ;;
    -F|--fade-out)  FADE_OUT="${2:?"-F requires a value"}"; shift 2 ;;
    -m|--margin)    MARGIN="${2:?"-m requires a value"}"; shift 2 ;;
    -p|--position)  POSITION="${2:?"-p requires a value"}"; shift 2 ;;
    -s|--scale)     SCALE="${2:?"-s requires a value"}"; shift 2 ;;
    -o|--output)    OUTPUT="${2:?"-o requires a value"}"; shift 2 ;;
    -h|--help)      usage ;;
    -*)
      [[ -f "$1" ]] && { POSARGS+=("$1"); shift; continue; }
      die "unknown flag: $1"
      ;;
    *)  POSARGS+=("$1"); shift ;;
  esac
done

[[ ${#POSARGS[@]} -lt 2 ]] && usage

VIDEO="${POSARGS[0]}"
LOGO="${POSARGS[1]}"

[[ ! -f "$VIDEO" ]] && die "video file not found: $VIDEO"
[[ ! -f "$LOGO" ]] && die "logo file not found: $LOGO"

# Validate codec
case "$CODEC" in
  copy|libx264|libx265|libaom-av1|libvpx-vp9) ;;
  *) die "unknown video codec: $CODEC (allowed: copy libx264 libx265 libaom-av1 libvpx-vp9)" ;;
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

# Default output: renders/<name>-watermarked.<ext> if renders/ exists, else ./<name>-watermarked.<ext>
if [[ -z "$OUTPUT" ]]; then
  VNAME="${VIDEO##*/}"
  VNAME="${VNAME%.*}"
  VEXT="${VIDEO##*.}"
  if [[ -d "./renders" ]]; then
    OUTPUT="./renders/${VNAME}-watermarked.${VEXT}"
  else
    OUTPUT="./${VNAME}-watermarked.${VEXT}"
  fi
fi
mkdir -p "$(dirname "$OUTPUT")"

# Get video duration to compute fade-out start time
DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$VIDEO" 2>/dev/null | cut -d. -f1)
FADE_OUT_START=$(( DURATION - FADE_OUT ))
echo "  Video duration: ${DURATION}s — fade-out starts at ${FADE_OUT_START}s"

# Build overlay position expression
case "$POSITION" in
  bottom-right)  OVERLAY_POS="W-w-${MARGIN}:H-h-${MARGIN}" ;;
  bottom-left)   OVERLAY_POS="${MARGIN}:H-h-${MARGIN}" ;;
  top-right)     OVERLAY_POS="W-w-${MARGIN}:${MARGIN}" ;;
  top-left)      OVERLAY_POS="${MARGIN}:${MARGIN}" ;;
  center)        OVERLAY_POS="(W-w)/2:(H-h)/2" ;;
esac

# Build optional scale filter
SCALE_FILTER=""
if [[ -n "$SCALE" ]]; then
  SCALE_W="${SCALE%%x*}"
  SCALE_H="${SCALE##*x}"
  SCALE_FILTER="scale=${SCALE_W}:${SCALE_H}:force_original_aspect_ratio=decrease,pad=${SCALE_W}:${SCALE_H}:(ow-iw)/2:(oh-ih)/2,"
fi

echo "Adding watermark..."
echo "  Video:    $VIDEO"
echo "  Logo:     $LOGO"
echo "  Output:   $OUTPUT"
echo "  Position: $POSITION (${MARGIN}px margin)"
echo "  Fade in:  ${FADE_IN}s"
echo "  Fade out: ${FADE_OUT}s (starts at ${FADE_OUT_START}s)"

ffmpeg -y -i "$VIDEO" -i "$LOGO" \
  -filter_complex \
    "[1:v]format=rgba,fade=t=in:st=0:d=${FADE_IN}:alpha=1,fade=t=out:st=${FADE_OUT_START}:d=${FADE_OUT}:alpha=1[wm]; \
     [0:v]${SCALE_FILTER}[main]; \
     [main][wm]overlay=${OVERLAY_POS}:shortest=1" \
  -c:v "$CODEC" -crf "$CRF" -c:a copy \
  -movflags +faststart \
  "$OUTPUT"

echo "Done: $OUTPUT"
