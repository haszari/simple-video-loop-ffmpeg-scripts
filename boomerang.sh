#!/usr/bin/env bash
#
# boomerang.sh
# ------------
# Creates a "boomerang" video clip by concatenating the original video
# with its reversed copy, producing a seamless forward→backward loop.
#
# Usage:
#   ./boomerang.sh [-c codec] [-q crf] [-o output] <video>
#
# Arguments:
#   video   Path to the source video file
#
# Flags:
#   -c, --codec  Video encoder (default: libx264)
#   -q, --crf    CRF quality (default: 23)
#   -o, --output Output file path (default: renders/<video>-boomerang.<ext>)
#
# Flags can go anywhere, mixed with positional args.
# Filenames starting with - are accepted as positional args if the file exists.
# Output is overwritten if it already exists (-y).
# Codec/quality flags are delegated through to ffmpeg.
# See https://ffmpeg.org/ffmpeg-codecs.html for codec details.
#
# Examples:
#   ./boomerang.sh clip.mp4
#   ./boomerang.sh -c libx265 -q 20 -o reversed.mp4 clip.mp4
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
OUTPUT=""
POSARGS=()

# Parse flags anywhere; unknown args starting with - are checked as files
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--codec) CODEC="${2:?"-c requires a value"}"; shift 2 ;;
    -q|--crf)   CRF="${2:?"-q requires a value"}"; shift 2 ;;
    -o|--output) OUTPUT="${2:?"-o requires a value"}"; shift 2 ;;
    -h|--help)  usage ;;
    -*)
      [[ -f "$1" ]] && { POSARGS+=("$1"); shift; continue; }
      die "unknown flag: $1"
      ;;
    *)  POSARGS+=("$1"); shift ;;
  esac
done

[[ ${#POSARGS[@]} -lt 1 ]] && usage

VIDEO="${POSARGS[0]}"

[[ ! -f "$VIDEO" ]] && die "video file not found: $VIDEO"

# Validate codec
case "$CODEC" in
  copy|libx264|libx265|libaom-av1|libvpx-vp9) ;;
  *) die "unknown video codec: $CODEC (allowed: copy libx264 libx265 libaom-av1 libvpx-vp9)" ;;
esac

# Validate CRF
[[ "$CRF" =~ ^[0-9]+$ ]] || die "CRF must be a non-negative integer, got: $CRF"

# Default output: renders/<name>-boomerang.<ext> if renders/ exists, else ./<name>-boomerang.<ext>
if [[ -z "$OUTPUT" ]]; then
  VNAME="${VIDEO##*/}"
  VNAME="${VNAME%.*}"
  VEXT="${VIDEO##*.}"
  if [[ -d "./renders" ]]; then
    OUTPUT="./renders/${VNAME}-boomerang.${VEXT}"
  else
    OUTPUT="./${VNAME}-boomerang.${VEXT}"
  fi
fi
mkdir -p "$(dirname "$OUTPUT")"

echo "Creating boomerang clip..."
echo "  Video:  $VIDEO"
echo "  Output: $OUTPUT"

ffmpeg -y -i "$VIDEO" \
  -filter_complex "[0:v]split[fw][rev];[rev]reverse[rv];[fw][rv]concat=n=2:v=1:a=0" \
  -c:v "$CODEC" -crf "$CRF" -an \
  -movflags +faststart \
  "$OUTPUT"

echo "Done: $OUTPUT"
