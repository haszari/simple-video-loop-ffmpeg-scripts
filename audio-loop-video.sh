#!/usr/bin/env bash
#
# audio-loop-video.sh
# -------------------
# Loops a video to match the duration of an audio file, replacing the
# video's original soundtrack with the provided audio. Optionally applies
# a subtle time-based colour effect (LFO) during the same single render
# pass, and can read its settings from a saved config file.
#
# Usage:
#   ./audio-loop-video.sh [options] <audio> <video>
#   ./audio-loop-video.sh --config <settings-file>
#
# Arguments:
#   audio   Path to the audio file (sets output duration)
#   video   Path to the video file (looped to match audio length)
#
# Flags:
#   -c, --codec         Video encoder (default: libx264)
#   -q, --crf           CRF quality (default: 23; software encoders only)
#   -Q, --video-quality Hardware encoder quality 0-100, higher = better
#                       (h264_videotoolbox / hevc_videotoolbox only; default:
#                       unset = encoder default)
#   -a, --audio-codec   Audio encoder (default: aac)
#   -o, --output        Output file path (default: renders/<audio>.<video-ext>)
#   -s, --start         Trim audio start time (e.g. 00:01:30)
#   -e, --end           Trim audio end time (e.g. 00:45:00)
#   -f, --fade          Fade duration in seconds (default: 0.04, i.e. 40ms)
#   -C, --color         Colour LFO presets, comma-separated. See COLOUR EFFECTS.
#       --color-raw     Raw ffmpeg filter expression for the colour effect
#                       (escape hatch), e.g. --color-raw 'hue=H=2*PI*t/7200'
#       --bpm           Beats per minute for bar-synced LFOs (default: 120)
#       --bars          Global LFO period in bars (overridden by per-preset
#                       periods; default: whole timeline)
#       --config FILE   Read arguments from FILE (curl-style config file;
#                       also accepted as @FILE). Repeatable, in-place,
#                       later args win.
#       --audio FILE    Long-name alias for the <audio> positional arg
#       --video FILE    Long-name alias for the <video> positional arg
#
# When --start or --end is provided, a short fade-in and fade-out is
# applied automatically (default 40ms). Use --fade to customise.
#
# COLOUR EFFECTS:
#   Colour presets apply a slow time-based effect to the video, evaluated
#   per frame from the filter timestamp. Expressions use ffmpeg's
#   expression language, so t is the running timestamp in seconds and
#   PI / 2*PI are available.
#
#   Preset syntax:  hue[:deg[:period]]           deg = hue rotation per LFO
#                                                cycle, in degrees (default 360)
#                   temp[:amplitude[:period]]    amplitude = gamma swing,
#                                                fraction 0-1 (default 0.05)
#                   sat[:delta[:period]]         delta = saturation swing,
#                                                fraction 0-1 (default 0.15)
#                   balance[:amount[:period]]    amount = green-gamma swing,
#                                                fraction 0-1 (default 0.12)
#
#   period is either 'whole' (default) — one LFO cycle over the entire
#   output duration — or a bar count synced to --bpm, where
#   period_seconds = bars * 240 / bpm (assumes 4/4 time).
#   Precedence: per-preset period > --bars > whole.
#
#   Examples:
#     --color hue                      one colour rotation per whole video
#     --color hue,sat:0.1:32           hue per whole video + sat per 32 bars
#     --bpm 128 --bars 64 --color hue,temp
#     --color-raw 'hue=H=2*PI*t/7200'  raw expression escape hatch
#
# CONFIG FILES:
#   --config reads a plain-text file of command-line arguments (the curl
#   -K/--config convention): one option per line, option and its value on
#   the same line, # comments and blank lines ignored. Long option names
#   may omit the leading dashes, e.g. 'codec = libx265'. Lines that are
#   not options are treated as positional arguments. @FILE is accepted as
#   an alias (gcc-style response file). Multiple --config files may be
#   given; contents are expanded in place and later arguments win, so
#   './audio-loop-video.sh --config show.conf -o final.mp4' lets the
#   command line override the file.
#
#   Example show.conf:
#     # 2026-08-01 render
#     --codec libx265
#     --crf 23
#     --bpm 128
#     --bars 64
#     --color hue,sat:0.1:32
#     --output renders/08-01-final.mp4
#     --audio music.mp3
#     --video bg.mp4
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
#   ./audio-loop-video.sh -c copy music.mp3 bg.mp4  # fast, no re-encode
#   ./audio-loop-video.sh -c h264_videotoolbox -Q 60 music.mp3 bg.mp4  # hardware
#   ./audio-loop-video.sh --color hue music.mp3 bg.mp4
#   ./audio-loop-video.sh --bpm 128 --bars 64 --color hue,sat music.mp3 bg.mp4
#   ./audio-loop-video.sh --config show.conf
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
  echo "$1" | awk -F: '{ s=0; for(i=1;i<=NF;i++) s=s*60+$i; printf "%.6f", s }'
}

# Map video codec to conventional file extension
codec_to_ext() {
  case "$1" in
    libx264|libx265|h264_videotoolbox|hevc_videotoolbox) echo "mp4" ;;
    libaom-av1)        echo "mp4" ;;
    libvpx-vp9)        echo "webm" ;;
    copy)              echo "" ;;  # keep input extension
  esac
}

# Effective output duration (seconds) set by audio, honouring --start/--end.
# The video is looped infinitely (-stream_loop -1), so audio sets the length.
compute_duration() {
  local dur
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AUDIO") || return 1
  if [[ -n "$START" ]]; then
    dur=$(awk "BEGIN { printf \"%.6f\", $dur - $(time_to_seconds "$START") }")
  fi
  if [[ -n "$END" ]]; then
    if [[ -n "$START" ]]; then
      dur=$(awk "BEGIN { printf \"%.6f\", $(time_to_seconds "$END") - $(time_to_seconds "$START") }")
    else
      dur=$(time_to_seconds "$END")
    fi
  fi
  printf '%s' "$dur"
}

# ---------------------------------------------------------------------------
# Config file expansion (curl -K/--config convention, plus gcc-style @file).
# --config/@file tokens are expanded in place into ARGS before arg parsing,
# so later arguments win and the main parser never sees them.
# ---------------------------------------------------------------------------

ARGS=()
LINE_TOKENS=()

tokenize() {
  local s="$1"
  LINE_TOKENS=()
  local buf="" c
  local i=0 len=${#s} in_single=0 in_double=0
  while (( i < len )); do
    c="${s:i:1}"
    if (( in_single )); then
      if [[ "$c" == "'" ]]; then in_single=0; else buf+="$c"; fi
    elif (( in_double )); then
      if [[ "$c" == '"' ]]; then in_double=0
      elif [[ "$c" == '\' && $((i+1)) < len ]]; then ((i++)); buf+="${s:i:1}"
      else buf+="$c"; fi
    else
      case "$c" in
        "'") in_single=1 ;;
        '"') in_double=1 ;;
        [[:space:]]) if [[ -n "$buf" ]]; then LINE_TOKENS+=("$buf"); buf=""; fi ;;
        '\') if [[ $((i+1)) < len ]]; then ((i++)); buf+="${s:i:1}"; else buf+='\'; fi ;;
        *) buf+="$c" ;;
      esac
    fi
    ((i++))
  done
  if [[ -n "$buf" ]]; then LINE_TOKENS+=("$buf"); fi
}

is_known_flag() {
  case "$1" in
    codec|crf|audio-codec|output|start|end|fade|color|color-raw|bpm|bars|config|audio|video) return 0 ;;
  esac
  return 1
}

# Convert a curl-style config line ("codec = libx265", "codec=libx265")
# into normal CLI tokens. Bare lines that are not known options pass
# through untouched (positional args).
normalize_config_tokens() {
  local first="${LINE_TOKENS[0]}"
  local name="" value=""
  if [[ "$first" == *=* || "$first" == *:* ]]; then
    if [[ "$first" == *=* ]]; then
      name="${first%%=*}"; value="${first#*=}"
    else
      name="${first%%:*}"; value="${first#*:}"
    fi
  elif [[ ${#LINE_TOKENS[@]} -ge 2 && "${LINE_TOKENS[1]}" == ["=":] ]]; then
    name="$first"; value="${LINE_TOKENS[2]:-}"
    LINE_TOKENS=("--$name")
    [[ -n "$value" ]] && LINE_TOKENS+=("$value")
    return
  elif [[ ${#LINE_TOKENS[@]} -ge 2 ]]; then
    name="$first"; value="${LINE_TOKENS[1]}"
    LINE_TOKENS=("--$name" "$value")
    return
  else
    name="$first"
  fi
  if is_known_flag "$name"; then
    LINE_TOKENS=("--$name")
    [[ -n "$value" ]] && LINE_TOKENS+=("$value")
  fi
}

parse_config_line() {
  local depth="$1" raw="$2"
  tokenize "$raw"
  [[ ${#LINE_TOKENS[@]} -eq 0 ]] && return
  local first="${LINE_TOKENS[0]}"
  if [[ "$first" == "--config" || "$first" == @* ]]; then
    local cfg
    if [[ "$first" == "--config" ]]; then
      [[ ${#LINE_TOKENS[@]} -lt 2 ]] && die "config line needs a file for --config: $raw"
      cfg="${LINE_TOKENS[1]}"
      [[ ${#LINE_TOKENS[@]} -gt 2 ]] && die "config line has unexpected args after --config: $raw"
    else
      cfg="${first#@}"
    fi
    read_config_file "$((depth+1))" "$cfg"
    return
  fi
  if [[ "$first" != -* ]]; then
    normalize_config_tokens
  fi
  ARGS+=("${LINE_TOKENS[@]}")
  return 0
}

read_config_file() {
  local depth="$1" cfg="$2"
  [[ "$cfg" == "-" ]] && cfg="/dev/stdin"
  if [[ "$cfg" != "/dev/stdin" ]]; then
    [[ -f "$cfg" ]] || die "config file not found: $cfg"
  fi
  local line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    parse_config_line "$depth" "$line"
  done < "$cfg"
  return 0
}

expand_config() {
  local depth="$1"; shift
  (( depth > 20 )) && die "config files nested too deeply (possible cycle)"
  local -a args=("$@")
  local i arg
  for ((i=0; i<${#args[@]}; i++)); do
    arg="${args[$i]}"
    case "$arg" in
      --config)
        (( i+1 >= ${#args[@]} )) && die "--config requires a file argument"
        read_config_file "$((depth+1))" "${args[$((i+1))]}"
        ((i++))
        ;;
      @*)
        read_config_file "$((depth+1))" "${arg#@}"
        ;;
      *)
        ARGS+=("$arg")
        ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# Colour LFO presets -> ffmpeg filter expressions.
# ---------------------------------------------------------------------------

# Effective period for a preset: per-preset period > --bars > whole
eff_period() {
  local p="$1"
  local -a parts=()
  local rest="${p#*:}"
  IFS=: read -r -a parts <<< "$rest" || true
  if [[ ${#parts[@]} -ge 2 ]]; then
    printf '%s' "${parts[1]}"
  elif [[ -n "$BARS" ]]; then
    printf '%s' "$BARS"
  else
    printf 'whole'
  fi
}

period_value() {
  local per
  per=$(eff_period "$1")
  case "$per" in
    whole|timeline|full)
      [[ -n "$OUTPUT_DURATION" ]] || die "colour period 'whole' requires the output duration (audio probe failed)"
      printf '%s' "$OUTPUT_DURATION"
      ;;
    *[!0-9]*)
      die "invalid colour period: $per (expected a bar count or 'whole')"
      ;;
    *)
      awk "BEGIN { printf \"%.6f\", $per * 240 / $BPM }"
      ;;
  esac
}

preset_uses_whole() {
  local per
  per=$(eff_period "$1")
  [[ "$per" == "whole" || "$per" == "timeline" || "$per" == "full" ]]
}

build_preset_filter() {
  local p="$1"
  local name="${p%%:*}"
  local rest="${p#*:}"
  local -a parts=()
  if [[ "$p" == *:* ]]; then
    IFS=: read -r -a parts <<< "$rest" || true
  fi
  case "$name" in
    hue)
      local deg="${parts[0]:-360}"
      [[ "$deg" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "hue preset: invalid degrees: $deg"
      local frac; frac=$(awk "BEGIN { printf \"%.6f\", $deg / 360 }")
      printf 'hue=H=2*PI*t*%s/(%s)' "$frac" "$(period_value "$p")"
      ;;
    temp)
      local amp="${parts[0]:-0.05}"
      [[ "$amp" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "temp preset: invalid amplitude: $amp"
      printf "eq=gamma_r='1+%s*sin(2*PI*t/(%s))':gamma_b='1-%s*sin(2*PI*t/(%s))':eval=frame" \
        "$amp" "$(period_value "$p")" "$amp" "$(period_value "$p")"
      ;;
    sat)
      local delta="${parts[0]:-0.15}"
      [[ "$delta" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "sat preset: invalid delta: $delta"
      printf "eq=saturation='1+%s*sin(2*PI*t/(%s))':eval=frame" "$delta" "$(period_value "$p")"
      ;;
    balance)
      local amount="${parts[0]:-0.12}"
      [[ "$amount" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "balance preset: invalid amount: $amount"
      printf "eq=gamma_g='1+%s*sin(2*PI*t/(%s))':eval=frame" "$amount" "$(period_value "$p")"
      ;;
    *)
      die "unknown colour preset: $name (allowed: hue temp sat balance)"
      ;;
  esac
}

color_filter_string() {
  local -a filters=()
  local p r
  for p in "${COLOR_PRESETS[@]+"${COLOR_PRESETS[@]}"}"; do
    filters+=("$(build_preset_filter "$p")")
  done
  for r in "${COLOR_RAW[@]+"${COLOR_RAW[@]}"}"; do
    filters+=("$r")
  done
  if [[ ${#filters[@]} -gt 0 ]]; then
    local IFS=,
    printf '%s' "${filters[*]}"
  fi
}

setup_color() {
  COLOR_FILTER_STRING=""
  if [[ ${#COLOR_PRESETS[@]} -gt 0 || ${#COLOR_RAW[@]} -gt 0 ]]; then
    local p uses_whole=false
    for p in "${COLOR_PRESETS[@]+"${COLOR_PRESETS[@]}"}"; do
      if preset_uses_whole "$p"; then uses_whole=true; break; fi
    done
    if [[ "$uses_whole" == true ]]; then
      OUTPUT_DURATION=$(compute_duration) || die "could not determine output duration for colour period 'whole'"
    fi
    COLOR_FILTER_STRING=$(color_filter_string)
  fi
}

CODEC="libx264"
CRF="23"
CRF_SET=false
VIDEO_QUALITY=""
AUDIO_CODEC="aac"
OUTPUT=""
START=""
END=""
FADE="0.04"
COLOR_PRESETS=()
COLOR_RAW=()
BPM="120"
BARS=""
AUDIO_ARG=""
VIDEO_ARG=""
OUTPUT_DURATION=""
COLOR_FILTER_STRING=""
POSARGS=()

# Expand --config/@file into ARGS, then re-run with the flat arg list
expand_config 1 "$@"
set -- "${ARGS[@]}"

# Parse flags anywhere; unknown args starting with - are checked as files
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--codec)        CODEC="${2:?"-c requires a value"}"; shift 2 ;;
    -q|--crf)          CRF="${2:?"-q requires a value"}"; CRF_SET=true; shift 2 ;;
    -Q|--video-quality) VIDEO_QUALITY="${2:?"-Q requires a value"}"; shift 2 ;;
    -a|--audio-codec)  AUDIO_CODEC="${2:?"-a requires a value"}"; shift 2 ;;
    -o|--output)       OUTPUT="${2:?"-o requires a value"}"; shift 2 ;;
    -s|--start)        START="${2:?"-s requires a value"}"; shift 2 ;;
    -e|--end)          END="${2:?"-e requires a value"}"; shift 2 ;;
    -f|--fade)
      if [[ $# -gt 1 && "$2" != -* && "$2" != '' ]]; then
        FADE="$2"; shift 2
      else
        FADE="0.04"; shift
      fi
      ;;
    -C|--color)
      _color_val="${2:?"-C requires a value"}"
      IFS=, read -r -a _presets <<< "$_color_val"
      COLOR_PRESETS+=("${_presets[@]}")
      shift 2
      ;;
    --color-raw)       COLOR_RAW+=("${2:?"--color-raw requires a value"}"); shift 2 ;;
    --bpm)             BPM="${2:?"--bpm requires a value"}"; shift 2 ;;
    --bars)            BARS="${2:?"--bars requires a value"}"; shift 2 ;;
    --audio)           AUDIO_ARG="${2:?"--audio requires a value"}"; shift 2 ;;
    --video)           VIDEO_ARG="${2:?"--video requires a value"}"; shift 2 ;;
    -h|--help)         usage ;;
    -*)
      [[ -f "$1" ]] && { POSARGS+=("$1"); shift; continue; }
      die "unknown flag: $1"
      ;;
    *)  POSARGS+=("$1"); shift ;;
  esac
done

[[ ${#POSARGS[@]} -gt 2 ]] && die "too many positional arguments: ${POSARGS[*]}"
AUDIO="${POSARGS[0]:-}"
VIDEO="${POSARGS[1]:-}"
[[ -z "$AUDIO" ]] && AUDIO="$AUDIO_ARG"
[[ -z "$VIDEO" ]] && VIDEO="$VIDEO_ARG"
[[ -z "$AUDIO" || -z "$VIDEO" ]] && usage

[[ ! -f "$AUDIO" ]] && die "audio file not found: $AUDIO"
[[ ! -f "$VIDEO" ]] && die "video file not found: $VIDEO"

# Validate codec
case "$CODEC" in
  copy|libx264|libx265|libaom-av1|libvpx-vp9|h264_videotoolbox|hevc_videotoolbox) ;;
  *) die "unknown video codec: $CODEC (allowed: copy libx264 libx265 libaom-av1 libvpx-vp9 h264_videotoolbox hevc_videotoolbox)" ;;
esac

# Validate audio codec
case "$AUDIO_CODEC" in
  aac|libmp3lame|libopus|copy) ;;
  *) die "unknown audio codec: $AUDIO_CODEC (allowed: aac libmp3lame libopus copy)" ;;
esac

# Validate CRF
[[ "$CRF" =~ ^[0-9]+$ ]] || die "CRF must be a non-negative integer, got: $CRF"

# Validate video quality (hardware encoders only; 0-100, higher = better)
if [[ -n "$VIDEO_QUALITY" ]]; then
  [[ "$VIDEO_QUALITY" =~ ^[0-9]+$ ]] || die "--video-quality must be an integer 0-100, got: $VIDEO_QUALITY"
  (( VIDEO_QUALITY <= 100 )) || die "--video-quality must be 0-100, got: $VIDEO_QUALITY"
  case "$CODEC" in
    h264_videotoolbox|hevc_videotoolbox) ;;
    *) die "--video-quality is for h264_videotoolbox/hevc_videotoolbox; use -q/--crf for libx264/libx265/libvpx-vp9/libaom-av1" ;;
  esac
fi

# -q/--crf only makes sense for CRF-based (software) encoders
if [[ "$CRF_SET" == true ]]; then
  case "$CODEC" in
    h264_videotoolbox|hevc_videotoolbox)
      die "-q/--crf is for software encoders (libx264 etc.); use -Q/--video-quality for $CODEC" ;;
  esac
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

# Validate bpm/bars
[[ "$BPM" =~ ^[0-9]+$ ]] || die "--bpm must be a positive integer, got: $BPM"
(( BPM >= 1 )) || die "--bpm must be >= 1, got: $BPM"
if [[ -n "$BARS" ]]; then
  [[ "$BARS" =~ ^[0-9]+$ ]] || die "--bars must be a positive integer, got: $BARS"
  (( BARS >= 1 )) || die "--bars must be >= 1, got: $BARS"
fi

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

# Build audio trim args and fade filter
AUDIO_INPUT_ARGS=()
AUDIO_FILTER=()
TRIMMING=false
if [[ -n "$START" || -n "$END" ]]; then
  TRIMMING=true
  [[ -n "$START" ]] && AUDIO_INPUT_ARGS+=(-ss "$START")
  [[ -n "$END" ]] && AUDIO_INPUT_ARGS+=(-to "$END")

  # Calculate trimmed duration for fade-out timing
  DURATION=$(compute_duration)

  FADE_OUT_START=$(awk "BEGIN { printf \"%.6f\", $DURATION - $FADE }")
  AUDIO_FILTER+=("afade=t=in:d=${FADE}")
  AUDIO_FILTER+=("afade=t=out:st=${FADE_OUT_START}:d=${FADE}")
fi

# Build colour filter (needs output duration for 'whole' periods)
setup_color

# Colour effects force re-encoding
if [[ -n "$COLOR_FILTER_STRING" && "$CODEC" == "copy" ]]; then
  die "colour effects require re-encoding; drop -c copy (or remove --color/--color-raw)"
fi

# Build ffmpeg codec args
CODEC_ARGS=(-c:v "$CODEC")
case "$CODEC" in
  h264_videotoolbox|hevc_videotoolbox)
    # Hardware encoders use -q:v (1-100, higher = better), not -crf
    [[ -n "$VIDEO_QUALITY" ]] && CODEC_ARGS+=(-q:v "$VIDEO_QUALITY")
    ;;
  copy)
    ;;  # no quality options with stream copy
  *)
    [[ -n "$CRF" ]] && CODEC_ARGS+=(-crf "$CRF")
    ;;
esac
# Use hvc1 tag for HEVC — required for QuickTime/macOS compatibility
case "$CODEC" in
  libx265|hevc_videotoolbox) CODEC_ARGS+=(-tag:v hvc1) ;;
esac

# Build video filter args
VF_ARGS=()
if [[ -n "$COLOR_FILTER_STRING" ]]; then
  VF_ARGS=(-vf "$COLOR_FILTER_STRING")
fi

echo "Looping video to match audio..."
echo "  Audio:  $AUDIO"
echo "  Video:  $VIDEO"
echo "  Output: $OUTPUT"
[[ "$TRIMMING" == true ]] && echo "  Trim:   ${START:-0} → ${END:-end} (fade ${FADE}s)"
if [[ -n "$COLOR_FILTER_STRING" ]]; then
  echo "  Colour: $COLOR_FILTER_STRING"
  [[ -n "$BARS" ]] && echo "  Sync:   ${BARS} bars @ ${BPM} bpm"
fi

# Build ffmpeg audio filter args
AUDIO_FILTER_ARGS=()
if [[ ${#AUDIO_FILTER[@]} -gt 0 ]]; then
  FILTER_STRING=$(IFS=,; echo "${AUDIO_FILTER[*]}")
  AUDIO_FILTER_ARGS+=(-af "$FILTER_STRING")
fi

ffmpeg -y -stream_loop -1 -i "$VIDEO" \
  ${AUDIO_INPUT_ARGS[@]+"${AUDIO_INPUT_ARGS[@]}"} -i "$AUDIO" \
  -map 0:v:0 -map 1:a:0 \
  "${CODEC_ARGS[@]}" -c:a "$AUDIO_CODEC" \
  ${VF_ARGS[@]+"${VF_ARGS[@]}"} \
  ${AUDIO_FILTER_ARGS[@]+"${AUDIO_FILTER_ARGS[@]}"} \
  -movflags +faststart \
  -shortest \
  "$OUTPUT"

echo "Done: $OUTPUT"
