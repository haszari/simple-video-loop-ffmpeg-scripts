#!/usr/bin/env bash
#
# audio-loop-video.sh
# -------------------
# Loops a video to match the duration of an audio file, replacing the
# video's original soundtrack with the provided audio.
#
# Usage:
#   ./audio-loop-video.sh [options] <audio> <video>
#
# Arguments:
#   audio   Path to the audio file (sets output duration)
#   video   Path to the video file (looped to match audio length)
#
# Flags:
#   -c, --codec        Video encoder (default: copy)
#   -q, --crf          CRF quality (omit for copy default)
#   -a, --audio-codec  Audio encoder (default: aac)
#   -o, --output       Output file path (default: renders/<audio>.<video-ext>)
#   -s, --start        Trim audio start time (e.g. 00:01:30)
#   -e, --end          Trim audio end time (e.g. 00:45:00)
#   -f, --fade         Fade duration in seconds (default: 0.04, i.e. 40ms)
#
# When --start or --end is provided, a short fade-in and fade-out is
# applied automatically (default 40ms). Use --fade to customise.
#
# Output is overwritten if it already exists (-y).
# Video/audio/codec flags are delegated through to ffmpeg.
# See https://ffmpeg.org/ffmpeg-codecs.html for codec details.
#
# Examples:
#   ./audio-loop-video.sh music.mp3 bg.mp4
#   ./audio-loop-video.sh -s 00:01:30 -e 00:45:00 music.mp3 bg.mp4
#   ./audio-loop-video.sh -s 00:01:30 -e 00:45:00 -f 0.1 music.mp3 bg.mp4
#   ./audio-loop-video.sh -c libx265 -q 23 -o final.mp4 music.mp3 bg.mp4
#
# Requires: ffmpeg
#
set -euo pipefail

usage() {
  sed -n '/^# Usage:/,/^# Requires:/p' "$0" | sed 's/^# \?//'
  exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

# Convert HH:MM:SS or MM:SS or seconds to raw seconds for arithmetic
time_to_seconds() {
  local t="$1"
  local ncolons="${t//[^:]}"
  ncolons=${#ncolons}
  if [[ $ncolons -eq 2 ]]; then
    # HH:MM:SS
    local h m s
    IFS=: read -r h m s <<< "$t"
    echo "$h * 3600 + $m * 60 + $s" | bc
  elif [[ $ncolons -eq 1 ]]; then
    # MM:SS
    local m s
    IFS=: read -r m s <<< "$t"
    echo "$m * 60 + $s" | bc
  else
    # Raw seconds
    echo "$t"
  fi
}

# Map video codec to conventional file extension
codec_to_ext() {
  case "$1" in
    libx264|libx265)    echo "mp4" ;;
    libaom-av1)         echo "mp4" ;;
    libvpx-vp9)         echo "webm" ;;
    copy)               echo "" ;;  # keep input extension
  esac
}

CODEC="copy"
CRF=""
AUDIO_CODEC="aac"
OUTPUT=""
START=""
END=""
FADE="0.04"
POSARGS=()

# Parse flags anywhere; unknown args starting with - are checked as files
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--codec)       CODEC="${2:?"-c requires a value"}"; shift 2 ;;
    -q|--crf)         CRF="${2:?"-q requires a value"}"; shift 2 ;;
    -a|--audio-codec) AUDIO_CODEC="${2:?"-a requires a value"}"; shift 2 ;;
    -o|--output)      OUTPUT="${2:?"-o requires a value"}"; shift 2 ;;
    -s|--start)       START="${2:?"-s requires a value"}"; shift 2 ;;
    -e|--end)         END="${2:?"-e requires a value"}"; shift 2 ;;
    -f|--fade)
      if [[ $# -gt 1 && "$2" != -* && "$2" != '' ]]; then
        FADE="$2"; shift 2
      else
        FADE="0.04"; shift
      fi
      ;;
    -h|--help)        usage ;;
    -*)
      [[ -f "$1" ]] && { POSARGS+=("$1"); shift; continue; }
      die "unknown flag: $1"
      ;;
    *)  POSARGS+=("$1"); shift ;;
  esac
done

[[ ${#POSARGS[@]} -lt 2 ]] && usage

AUDIO="${POSARGS[0]}"
VIDEO="${POSARGS[1]}"

[[ ! -f "$AUDIO" ]] && die "audio file not found: $AUDIO"
[[ ! -f "$VIDEO" ]] && die "video file not found: $VIDEO"

# Validate codec
case "$CODEC" in
  copy|libx264|libx265|libaom-av1|libvpx-vp9) ;;
  *) die "unknown video codec: $CODEC (allowed: copy libx264 libx265 libaom-av1 libvpx-vp9)" ;;
esac

# Validate audio codec
case "$AUDIO_CODEC" in
  aac|libmp3lame|libopus|copy) ;;
  *) die "unknown audio codec: $AUDIO_CODEC (allowed: aac libmp3lame libopus copy)" ;;
esac

# Validate CRF if provided
if [[ -n "$CRF" ]]; then
  [[ "$CRF" =~ ^[0-9]+$ ]] || die "CRF must be a non-negative integer, got: $CRF"
fi

# Validate fade
[[ "$FADE" =~ ^[0-9]*\.?[0-9]+$ ]] || die "fade must be a positive number, got: $FADE"

# Validate start/end are valid time formats if provided (basic check)
for t in START END; do
  val="${!t}"
  if [[ -n "$val" ]]; then
    [[ "$val" =~ ^[0-9:.]+$ ]] || die "${t,,} has invalid time format: $val (expected HH:MM:SS or seconds)"
  fi
done

# Default output: renders/<audio>.<ext> if renders/ exists, else ./<audio>.<ext>
# Extension is derived from codec convention; falls back to input video extension for copy.
if [[ -z "$OUTPUT" ]]; then
  ANAME="${AUDIO##*/}"
  ANAME="${ANAME%.*}"
  CODEC_EXT=$(codec_to_ext "$CODEC")
  VEXT="${CODEC_EXT:-${VIDEO##*.}}"
  if [[ -d "./renders" ]]; then
    OUTPUT="./renders/${ANAME}.${VEXT}"
  else
    OUTPUT="./${ANAME}.${VEXT}"
  fi
fi
mkdir -p "$(dirname "$OUTPUT")"

# Build audio filter chain (trim + fade)
AUDIO_FILTER=()
TRIMMING=false
if [[ -n "$START" || -n "$END" ]]; then
  TRIMMING=true
  TRIM_ARGS=""
  [[ -n "$START" ]] && TRIM_ARGS+="start=${START}"
  [[ -n "$END" ]] && { [[ -n "$TRIM_ARGS" ]] && TRIM_ARGS+=":"; TRIM_ARGS+="end=${END}"; }
  AUDIO_FILTER+=("atrim=${TRIM_ARGS}" "asetpts=PTS-STARTPTS")

  # Calculate trimmed duration for fade-out timing
  DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AUDIO")
  DURATION=$(printf '%.6f' "$DURATION")
  if [[ -n "$START" ]]; then
    START_SEC=$(time_to_seconds "$START")
    DURATION=$(awk "BEGIN { printf \"%.6f\", $DURATION - $START_SEC }")
  fi
  if [[ -n "$END" ]]; then
    END_SEC=$(time_to_seconds "$END")
    DURATION="$END_SEC"
    [[ -n "$START" ]] && DURATION=$(awk "BEGIN { printf \"%.6f\", $END_SEC - $START_SEC }")
  fi

  FADE_OUT_START=$(awk "BEGIN { printf \"%.6f\", $DURATION - $FADE }")
  AUDIO_FILTER+=("afade=t=in:d=${FADE}")
  AUDIO_FILTER+=("afade=t=out:st=${FADE_OUT_START}:d=${FADE}")
fi

# Build ffmpeg codec args
CODEC_ARGS=(-c:v "$CODEC")
[[ -n "$CRF" ]] && CODEC_ARGS+=(-crf "$CRF")

echo "Looping video to match audio..."
echo "  Audio:  $AUDIO"
echo "  Video:  $VIDEO"
echo "  Output: $OUTPUT"
[[ "$TRIMMING" == true ]] && echo "  Trim:   ${START:-0} → ${END:-end} (fade ${FADE}s)"

# Build ffmpeg audio args
AUDIO_ARGS=()
if [[ ${#AUDIO_FILTER[@]} -gt 0 ]]; then
  FILTER_STRING=$(IFS=,; echo "${AUDIO_FILTER[*]}")
  AUDIO_ARGS+=(-af "$FILTER_STRING")
fi

ffmpeg -y -stream_loop -1 -i "$VIDEO" -i "$AUDIO" \
  -map 0:v:0 -map 1:a:0 \
  "${CODEC_ARGS[@]}" -c:a "$AUDIO_CODEC" \
  "${AUDIO_ARGS[@]}" \
  -shortest \
  "$OUTPUT"

echo "Done: $OUTPUT"
