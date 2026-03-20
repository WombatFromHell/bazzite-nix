#!/usr/bin/env bash
# grimshot — a hyprshot-like screenshot wrapper for the niri compositor
# Requires: grim, slurp, jq, libnotify (notify-send), wl-copy (optional)
#
# Usage: [OPTIONS] -- MODE [FILE]
#
# Modes:
#   window      Interactively pick a window to capture
#   active      Capture the currently focused window (no prompt)
#   region      Interactive region selection (via slurp)
#   output      Capture the focused output (monitor)
#   screen      Alias for 'output'
#
# Options:
#   -o, --output-folder DIR   Directory to save screenshots (default: ~/Pictures/Screenshots)
#   -f, --filename NAME       Override filename (default: timestamped)
#   -c, --clipboard-only      Copy to clipboard, do not save file
#   -C, --no-clipboard        Do not copy to clipboard
#   -n, --no-notify           Suppress desktop notification
#   -s, --silent              Alias for --no-notify
#   -d, --delay SECS          Delay before capture (integer seconds)
#   -t, --screenshot-type     Ignored (hyprshot compat shim)
#   -h, --help                Show this help

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
OUTPUT_FOLDER="${XDG_PICTURES_DIR:-$HOME/Pictures}/Screenshots"
FILENAME=""
CLIPBOARD_ONLY=false
NO_CLIPBOARD=false
NO_NOTIFY=false
DELAY=0
MODE=""
SAVE_FILE=""

# ── Helpers ─────────────────────────────────────────────────────────────────
die() {
  echo "grimshot-niri: error: $*" >&2
  exit 1
}
need() { command -v "$1" &>/dev/null || die "'$1' is required but not installed."; }
notify() {
  $NO_NOTIFY && return
  local summary="$1" body="${2:-}" icon="${3:-camera}"
  command -v notify-send &>/dev/null && notify-send -i "$icon" -t 3000 "$summary" "$body" || true
}

usage() {
  cat <<'EOF'
Usage:
  grimshot-niri [OPTIONS] -- MODE [FILE]

Modes:
  window      Interactively pick a window to capture
  active      Capture the currently focused window (no prompt)
  region      Interactive region selection (via slurp)
  output      Capture the focused output (monitor)
  screen      Alias for 'output'

Options:
  -o, --output-folder DIR   Directory to save screenshots (default: ~/Pictures/Screenshots)
  -f, --filename NAME       Override filename (default: timestamped)
  -c, --clipboard-only      Copy to clipboard, do not save file
  -C, --no-clipboard        Do not copy to clipboard
  -n, --no-notify           Suppress desktop notification
  -s, --silent              Alias for --no-notify
  -d, --delay SECS          Delay before capture (integer seconds)
  -t, --screenshot-type     Ignored (hyprshot compat shim)
  -h, --help                Show this help
EOF
  exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────
# Support both hyprshot-style  "-- MODE [FILE]"  and  "MODE [FILE]"  directly.
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  -o | --output-folder)
    OUTPUT_FOLDER="$2"
    shift 2
    ;;
  -f | --filename)
    FILENAME="$2"
    shift 2
    ;;
  -c | --clipboard-only)
    CLIPBOARD_ONLY=true
    shift
    ;;
  -C | --no-clipboard)
    NO_CLIPBOARD=true
    shift
    ;;
  -n | --no-notify | -s | --silent)
    NO_NOTIFY=true
    shift
    ;;
  -d | --delay)
    DELAY="$2"
    shift 2
    ;;
  -t | --screenshot-type) shift 2 ;; # compat shim, ignored
  -h | --help) usage ;;
  --)
    shift
    POSITIONAL+=("$@")
    break
    ;;
  -*) die "Unknown option: $1" ;;
  *)
    POSITIONAL+=("$1")
    shift
    ;;
  esac
done

if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
  MODE="${POSITIONAL[0]}"
else
  die "No mode specified. Use: window | active | region | output | screen"
fi
if [[ ${#POSITIONAL[@]} -gt 1 ]]; then
  SAVE_FILE="${POSITIONAL[1]}"
fi

# Normalise mode aliases
[[ "$MODE" == "screen" ]] && MODE="output"
# NOTE: 'active' is intentionally NOT collapsed into 'window' here —
# 'window' = interactive pick, 'active' = focused window (no prompt).

# ── Dependency checks ────────────────────────────────────────────────────────
need niri
[[ "$MODE" != "window" && "$MODE" != "active" ]] && need grim
need jq
[[ "$MODE" == "region" ]] && need slurp
if ! $CLIPBOARD_ONLY && ! $NO_CLIPBOARD; then
  command -v wl-copy &>/dev/null || true # soft dep; warned later if missing
fi

# ── Build output path ────────────────────────────────────────────────────────
if ! $CLIPBOARD_ONLY; then
  mkdir -p "$OUTPUT_FOLDER"
  if [[ -z "$SAVE_FILE" ]]; then
    TS=$(date +"%Y-%m-%d_%H-%M-%S")
    FNAME="${FILENAME:-screenshot_${TS}.png}"
    # Ensure .png extension
    [[ "$FNAME" == *.* ]] || FNAME="${FNAME}.png"
    SAVE_FILE="${OUTPUT_FOLDER}/${FNAME}"
  fi
fi

# ── Optional delay ───────────────────────────────────────────────────────────
if [[ "$DELAY" -gt 0 ]]; then
  notify "Screenshot in ${DELAY}s…" ""
  sleep "$DELAY"
fi

# ── Niri IPC helpers ────────────────────────────────────────────────────────
niri_pick_window_id() {
  # Interactively pick a window with the mouse and return its ID.
  niri msg --json pick-window 2>/dev/null |
    jq -r '.id // empty' |
    head -1
}

niri_focused_window_id() {
  # Return the ID of the currently focused window without any user prompt.
  niri msg --json focused-window 2>/dev/null |
    jq -r '.id // empty' |
    head -1
}

niri_focused_output_name() {
  # Returns the name of the focused output
  niri msg --json focused-output 2>/dev/null |
    jq -r '.name // empty' |
    head -1
}

# ── Capture ──────────────────────────────────────────────────────────────────
# TMP_FILE declared before the case block so window mode can write to it.
TMP_FILE=$(mktemp --suffix=.png)
trap 'rm -f "$TMP_FILE"' EXIT INT TERM
# Timestamp anchor for the niri-window fallback finder (must precede the action call).
PRE_SHOT=$(date +%s)

GRIM_ARGS=()
SKIP_GRIM=false

_screenshot_window_by_id() {
  local win_id="$1"
  # niri msg action screenshot-window writes to niri's configured
  # screenshot-path. We capture its output to find the saved path,
  # then copy the file into our own pipeline.
  local niri_out niri_path
  niri_out=$(niri msg action screenshot-window --id "$win_id" 2>&1) || true
  # Try to parse the path from niri's output ("Screenshot saved to /…")
  niri_path=$(echo "$niri_out" | grep -oP '(?<=Screenshot saved to ).*' | head -1)

  if [[ -z "$niri_path" || ! -f "$niri_path" ]]; then
    # Fallback: find the newest PNG in the default screenshot dir that
    # appeared after we started (PRE_SHOT epoch seconds).
    local ss_search_dir="${XDG_PICTURES_DIR:-$HOME/Pictures}/Screenshots"
    niri_path=$(find "$ss_search_dir" -maxdepth 1 -name '*.png' \
      -printf '%T@ %p\n' 2>/dev/null |
      awk -v t="$PRE_SHOT" '$1 >= t' |
      sort -rn | head -1 | cut -d' ' -f2-)
  fi

  [[ -z "$niri_path" || ! -f "$niri_path" ]] &&
    die "Could not locate screenshot produced by niri." \
      "Ensure niri v0.1.9+ and screenshot-path is set in your config."

  cp "$niri_path" "$TMP_FILE"
  SKIP_GRIM=true
}

case "$MODE" in
active)
  # Capture the focused window immediately — no user interaction required.
  WIN_ID=$(niri_focused_window_id) ||
    die "Could not query focused window from niri."
  [[ -z "$WIN_ID" ]] && die "No focused window found."
  _screenshot_window_by_id "$WIN_ID"
  ;;

window)
  # Use niri's pick-window to interactively select a window with the mouse.
  WIN_ID=$(niri_pick_window_id) ||
    die "Could not pick window from niri."
  [[ -z "$WIN_ID" ]] && die "No window selected."
  _screenshot_window_by_id "$WIN_ID"
  ;;

region)
  # slurp exits non-zero on cancel; the || must be on the same line as the
  # assignment so set -e doesn't fire before we can handle the failure.
  GEOM=$(slurp -d 2>/dev/null || true)
  [[ -z "$GEOM" ]] && die "Region selection cancelled."
  GRIM_ARGS+=(-g "$GEOM")
  ;;

output)
  OUTPUT=$(niri_focused_output_name) ||
    die "Could not get focused output from niri."
  [[ -z "$OUTPUT" ]] && die "No focused output found."
  GRIM_ARGS+=(-o "$OUTPUT")
  ;;

*)
  die "Unknown mode: '$MODE'. Use: window | active | region | output | screen"
  ;;
esac

if [[ "${SKIP_GRIM:-false}" != true ]]; then
  grim "${GRIM_ARGS[@]}" "$TMP_FILE" ||
    die "grim failed to capture screenshot."
fi

# ── Save ─────────────────────────────────────────────────────────────────────
if ! $CLIPBOARD_ONLY; then
  cp "$TMP_FILE" "$SAVE_FILE"
fi

# ── Clipboard ────────────────────────────────────────────────────────────────
if ! $NO_CLIPBOARD; then
  if command -v wl-copy &>/dev/null; then
    wl-copy <"$TMP_FILE"
  else
    notify "grimshot-niri" "wl-copy not found; clipboard skipped." "dialog-warning"
  fi
fi

# ── Notification ─────────────────────────────────────────────────────────────
if $CLIPBOARD_ONLY; then
  notify "Screenshot copied" "Captured $MODE to clipboard." "camera"
else
  notify "Screenshot saved" "$SAVE_FILE" "camera"
  echo "$SAVE_FILE"
fi
