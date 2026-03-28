#!/usr/bin/env bash
# new-browser-window — open a new browser window using the system default

set -euo pipefail

URL="${1:-}"

# Get the .desktop file name for the default browser
DESKTOP_FILE="$(xdg-settings get default-web-browser 2>/dev/null)" || {
  echo "Error: could not determine default browser" >&2
  exit 1
}

# Search for .desktop file - check flatpak paths first for common flatpak browser IDs
# Flatpak app IDs follow reverse-DNS pattern (e.g., com.brave.Browser.desktop)
if [[ "$DESKTOP_FILE" =~ ^[a-z][a-z0-9]*\.[a-z][a-z0-9.-]*\.[a-z][a-z0-9.-]*\.desktop$ ]]; then
  # Likely a flatpak app - check flatpak paths first
  DESKTOP_PATH="$(
    for dir in \
      "$HOME/.local/share/flatpak/exports/share/applications" \
      /var/lib/flatpak/exports/share/applications \
      "$HOME/.local/share/applications" \
      /usr/local/share/applications \
      /usr/share/applications; do
      [[ -f "$dir/$DESKTOP_FILE" ]] && {
        echo "$dir/$DESKTOP_FILE"
        break
      }
    done
  )"
else
  # Native app - check standard paths first
  DESKTOP_PATH="$(
    for dir in \
      "$HOME/.local/share/applications" \
      /usr/local/share/applications \
      /usr/share/applications \
      "$HOME/.local/share/flatpak/exports/share/applications" \
      /var/lib/flatpak/exports/share/applications; do
      [[ -f "$dir/$DESKTOP_FILE" ]] && {
        echo "$dir/$DESKTOP_FILE"
        break
      }
    done
  )"
fi

[[ -z "$DESKTOP_PATH" ]] && {
  echo "Error: .desktop file not found for '$DESKTOP_FILE'" >&2
  exit 1
}

# Extract the Exec= line, strip field codes (%u %U %f %F etc.), @@ markers, and quotes
# But preserve the full command structure for wrapper scripts
RAW_EXEC_LINE="$(grep -m1 '^Exec=' "$DESKTOP_PATH" | sed 's/^Exec=//')"

# Check for wrapper scripts that should be exec'd directly
if [[ "$RAW_EXEC_LINE" =~ chromium-flags\.sh|brave-wrapper\.sh ]]; then
  # Wrapper script detected - exec directly with URL substituted for %U
  if [[ -n "$URL" ]]; then
    # Replace %U/%u with the URL using | as delimiter to avoid issues with URLs
    FINAL_CMD="$(echo "$RAW_EXEC_LINE" | sed "s|%U|$URL|g; s|%u|$URL|g; s|%[a-zA-Z]||g; s|@@[^ ]*||g")"
  else
    FINAL_CMD="$(echo "$RAW_EXEC_LINE" | sed 's|%[a-zA-Z]||g; s|@@[^ ]*||g')"
  fi
  # Execute via bash to handle the full command line
  exec bash -c "$FINAL_CMD"
fi

# Legacy path: extract browser binary and spawn via spawn_browser()
EXEC_LINE="$(echo "$RAW_EXEC_LINE" | sed 's/%[a-zA-Z]//g; s/@@[^ ]*//g; s/^ *//; s/ *$//')"

# Helper: extract browser name and spawn based on launcher type
spawn_browser() {
  local launcher_type="$1"
  local target="$2"
  local browser_name="$3"
  shift 3
  local extra_args=("$@")

  # Build the command array
  local cmd=()

  # Add PREFIX if set (e.g., for env vars or wrappers)
  if [[ -n "${PREFIX:-}" ]]; then
    # shellcheck disable=SC2086
    cmd+=("$PREFIX")
  fi

  case "$browser_name" in
  firefox* | librewolf* | waterfox*)
    if [[ "$launcher_type" == "flatpak" ]]; then
      cmd+=(flatpak run "$target" --new-window)
    elif [[ "$launcher_type" == "distrobox" ]]; then
      cmd+=(distrobox run "$target" -- --new-window)
    else
      cmd+=("$target" --new-window)
    fi
    ;;
  google-chrome* | chromium* | brave* | microsoft-edge* | vivaldi* | floorp*)
    if [[ "$launcher_type" == "flatpak" ]]; then
      cmd+=(flatpak run "$target" --new-window)
    elif [[ "$launcher_type" == "distrobox" ]]; then
      cmd+=(distrobox run "$target" -- --new-window)
    else
      cmd+=("$target" --new-window)
    fi
    ;;
  epiphany* | gnome-web*)
    if [[ "$launcher_type" == "flatpak" ]]; then
      cmd+=(flatpak run "$target" --new-window)
    elif [[ "$launcher_type" == "distrobox" ]]; then
      cmd+=(distrobox run "$target" -- --new-window)
    else
      cmd+=("$target" --new-window)
    fi
    ;;
  *)
    # Best-effort fallback
    echo "Warning: unknown browser '$browser_name', trying without --new-window" >&2
    if [[ "$launcher_type" == "flatpak" ]]; then
      cmd+=(flatpak run "$target")
    elif [[ "$launcher_type" == "distrobox" ]]; then
      cmd+=(distrobox run "$target" --)
    else
      cmd+=("$target")
    fi
    ;;
  esac

  exec "${cmd[@]}" "${extra_args[@]}"
}

# Check if this is a flatpak run command
if [[ "$EXEC_LINE" =~ ^(/usr/bin/)?flatpak[[:space:]]+run ]]; then
  # Extract flatpak app ID - it's the first argument after 'flatpak run' that matches reverse-DNS pattern
  # Strip @@ markers and options first
  # shellcheck disable=SC2001
  CLEAN_EXEC="$(echo "$EXEC_LINE" | sed 's/@@[^ ]*//g')"

  # Extract app ID: first token after 'flatpak run' matching reverse-DNS pattern (case-insensitive)
  FLATPAK_APP_ID="$(echo "$CLEAN_EXEC" | grep -oiE '[a-z][a-z0-9]*\.[a-z][a-z0-9.-]*\.[a-z][a-z0-9.-]*' | head -n1)"

  [[ -z "$FLATPAK_APP_ID" ]] && {
    echo "Error: could not determine flatpak app ID from '$EXEC_LINE'" >&2
    exit 1
  }

  # Extract --command value if present for browser detection
  if [[ "$EXEC_LINE" =~ --command=([^[:space:]]+) ]]; then
    BROWSER_NAME="${BASH_REMATCH[1]}"
  else
    BROWSER_NAME="$FLATPAK_APP_ID"
  fi

  spawn_browser "flatpak" "$FLATPAK_APP_ID" "$BROWSER_NAME" ${URL:+"$URL"}

# Check if this is a distrobox run command
elif [[ "$EXEC_LINE" =~ ^distrobox[[:space:]]+run[[:space:]]+([^[:space:]]+) ]]; then
  DISTROBOX_CONTAINER="${BASH_REMATCH[1]}"

  # Extract the command after '--' separator, strip distrobox-specific options
  DISTROBOX_CMD="$(echo "$EXEC_LINE" | sed 's/.*--[[:space:]]*//' | sed 's/@@[^ ]*//g')"

  # Get the browser binary (first token)
  BROWSER_BIN="${DISTROBOX_CMD%% *}"

  [[ -z "$BROWSER_BIN" ]] && {
    echo "Error: could not determine browser command from '$EXEC_LINE'" >&2
    exit 1
  }

  spawn_browser "distrobox" "$DISTROBOX_CONTAINER" "$BROWSER_BIN" ${URL:+"$URL"}
else
  # Native binary path
  BROWSER_BIN="${EXEC_LINE%% *}"

  # Resolve to full path if needed
  BROWSER_BIN="$(command -v "$BROWSER_BIN" 2>/dev/null || echo "$BROWSER_BIN")"

  [[ -z "$BROWSER_BIN" ]] && {
    echo "Error: could not resolve browser binary" >&2
    exit 1
  }

  spawn_browser "native" "$BROWSER_BIN" "$(basename "$BROWSER_BIN")" ${URL:+"$URL"}
fi
