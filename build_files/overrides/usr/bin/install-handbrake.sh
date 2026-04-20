#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

#==============================================================================
# CONFIGURATION
#==============================================================================
readonly CONTAINER_NAME="${CONTAINER_NAME:-encoderbox}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-archlinux:latest}"
DBX_USE_ROOT="false"
readonly DBX_EXPORT_APP="ghb"

DBX_PACKAGES="git base-devel"
DBX_CHECK_APP="ghb"

DBX_POST_HOOKS=(
  "rm -rf /tmp/yay-bin &&"
  "git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin &&"
  "cd /tmp/yay-bin && makepkg -si --noconfirm &&"
  "rm -rf /tmp/yay-bin"
  "yay -Syu --noconfirm amf-amdgpu-pro handbrake gst-plugins-good gst-libav xdg-desktop-portal-gtk"
  "distrobox-export -a ghb"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/distrobox-installer.sh"

#==============================================================================
# HELP
#==============================================================================

show_help() {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]

Options:
  --recreate     Force recreation of the container
  --freshen     Re-run post-hooks, refresh exports
  --install      Install HandBrake (ghb) and export to host
  --uninstall    Remove HandBrake export from host (does not uninstall from container)
  --rm           Also remove container (use with --uninstall)
  --help         Show this help message

Examples:
  ${0##*/}                   # Install HandBrake and export
  ${0##*/} --install         # Same as above (idempotent)
  ${0##*/} --uninstall       # Remove export from host
  ${0##*/} --rm --uninstall  # Remove export and delete container
  ${0##*/} --recreate        # Recreate container and reinstall
  ${0##*/} --freshen        # Re-run post-hooks

Description:
  Installs HandBrake with AMDGPU Pro support inside an Arch Linux
  distrobox container using yay (AUR helper), then exports ghb to host.
EOF
}

#==============================================================================
# MAIN
#==============================================================================

main() {
  dbx_main "$(show_help)" "$@"
}

main "$@"
