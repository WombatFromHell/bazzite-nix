#!/usr/bin/env bash
set -euo pipefail

COLOR=$(hyprpicker) || exit 0
[[ -z "$COLOR" ]] && exit 0

printf '%s' "$COLOR" | wl-copy

# copy over our tmpfs swatch for safety
SWATCH="${XDG_RUNTIME_DIR:-/tmp}/colorpicker-swatch.png"
# show a swatch of our copied color in our notification
convert -size 64x64 xc:"$COLOR" "$SWATCH"
notify-send -i "$SWATCH" -t 3000 "Color copied to clipboard" "$COLOR"
