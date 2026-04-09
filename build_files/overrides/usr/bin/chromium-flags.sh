#!/usr/bin/env bash
set -euo pipefail

#==============================================================================
# Chromium Flags Loader
#==============================================================================
# Reads flags from ~/.config/chromium-flags.conf and prepends them to a command.
# Designed to be used as a wrapper for Chromium-based browsers.
#
# Usage:
#   chromium-flags.sh <command> [args...]
#
# Examples:
#   chromium-flags.sh brave-browser
#   chromium-flags.sh flatpak run com.brave.Browser
#   chromium-flags.sh distrobox-enter -n bravebox -- brave-browser
#
# The flags config file (~/.config/chromium-flags.conf) should contain one flag
# per line. Lines starting with # are treated as comments.
#==============================================================================

readonly FLAGS_CONFIG="${FLAGS_CONFIG:-${HOME}/.config/chromium-flags.conf}"

#------------------------------------------------------------------------------
# Load flags from config file
#------------------------------------------------------------------------------
load_flags() {
  local flags=()

  if [[ ! -f "$FLAGS_CONFIG" ]]; then
    echo "Warning: Flags configuration file '$FLAGS_CONFIG' not found." >&2
    echo "  To add custom flags, create the file with one flag per line." >&2
    echo "  Example: echo '--disable-gpu' >> $FLAGS_CONFIG" >&2
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # Trim whitespace and add to flags array
    flags+=("$(echo "$line" | xargs)")
  done <"$FLAGS_CONFIG"

  # Only output if we have flags (prevents empty line from being read by mapfile)
  [[ ${#flags[@]} -gt 0 ]] && printf '%s\n' "${flags[@]}"
}

#------------------------------------------------------------------------------
# Main: Execute command with flags injected after the first argument
#------------------------------------------------------------------------------
main() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: chromium-flags.sh <command> [args...]" >&2
    echo "  Injects flags from $FLAGS_CONFIG into the command." >&2
    exit 1
  fi

  local command="$1"
  shift

  # Load flags
  local flags=()
  mapfile -t flags < <(load_flags 2>/dev/null)

  # Special handling for distrobox-enter: inject flags after '--'
  if [[ "$command" == "distrobox-enter" || "$command" == "distrobox" ]]; then
    local distrobox_args=()
    local after_dash_dash=false
    local browser_found=false

    for arg in "$@"; do
      if [[ "$after_dash_dash" == true && "$browser_found" == false ]]; then
        # This is the browser command after '--'
        browser_found=true
        if [[ ${#flags[@]} -gt 0 ]]; then
          distrobox_args+=("$arg" "${flags[@]}")
        else
          distrobox_args+=("$arg")
        fi
      elif [[ "$arg" == "--" ]]; then
        after_dash_dash=true
        distrobox_args+=("$arg")
      elif [[ "$browser_found" == true ]]; then
        # Pass through all arguments after the browser command (e.g., %U, URLs)
        distrobox_args+=("$arg")
      else
        distrobox_args+=("$arg")
      fi
    done

    exec "$command" "${distrobox_args[@]}"
  fi

  # Special handling for flatpak: inject flags after 'run' and app-id
  if [[ "$command" == "flatpak" && "$1" == "run" ]]; then
    local flatpak_cmd=("$command" "$1" "$2")
    shift 2

    if [[ ${#flags[@]} -gt 0 ]]; then
      flatpak_cmd+=("${flags[@]}")
    fi

    exec "${flatpak_cmd[@]}" "$@"
  fi

  # Standard command: inject flags after command
  if [[ ${#flags[@]} -gt 0 ]]; then
    exec "$command" "${flags[@]}" "$@"
  else
    exec "$command" "$@"
  fi
}

main "$@"
