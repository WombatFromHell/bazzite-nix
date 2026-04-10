#!/usr/bin/env bash
set -euo pipefail

#==============================================================================
# CONFIGURATION
#==============================================================================
readonly CONTAINER_NAME="${CONTAINER_NAME:-encoderbox}"
readonly CONTAINER_IMAGE="${CONTAINER_IMAGE:-archlinux:latest}"

# Source the shared helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/distrobox-installer.sh"

#==============================================================================
# ACTIONS
#==============================================================================

show_help() {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]

Options:
  --recreate     Force recreation of the container
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

Description:
  Installs HandBrake with AMDGPU Pro support inside an Arch Linux
  distrobox container using yay (AUR helper), then exports ghb to host.
EOF
}

setup_handbrake() {
  dbx_log "Installing HandBrake inside container..."

  # Step 1: Install git, base-devel, and yay-bin from AUR
  dbxe -- bash -c '
    sudo pacman -S --needed --noconfirm git base-devel && \
    git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin && \
    cd /tmp/yay-bin && \
    makepkg -si --noconfirm && \
    cd .. && rm -rf /tmp/yay-bin
  '

  # Step 2: Install amf-amdgpu-pro and handbrake via yay
  dbxe -- yay -Syu --noconfirm amf-amdgpu-pro handbrake gst-plugins-good gst-libav xdg-desktop-portal-gtk

  dbx_log "HandBrake installation complete."
}

#==============================================================================
# MAIN
#==============================================================================

main() {
  if dbx_is_inside_container; then
    exit 0
  fi

  # Parse arguments via helper (sets ACTION, INSTALL_TYPE, RM_CONTAINER, RECREATE)
  local parse_result=0
  dbx_parse_args "$@" || parse_result=$?

  if [[ $parse_result -eq 0 ]]; then
    show_help
    exit 0
  elif [[ $parse_result -eq 1 ]]; then
    show_help
    exit 1
  fi

  case "$ACTION" in
  uninstall)
    if [[ "$RM_CONTAINER" == "true" ]]; then
      dbx_do_remove "$CONTAINER_NAME" "ghb"
    else
      dbx_do_uninstall "$CONTAINER_NAME" "ghb"
    fi
    exit 0
    ;;
  install)
    if [[ "$RECREATE" == "true" ]]; then
      if dbx_container_exists "$CONTAINER_NAME"; then
        if ! dbx_confirm "This will recreate the '${CONTAINER_NAME}' container. All existing data and exports will be lost."; then
          dbx_log "Recreation cancelled."
          exit 0
        fi
      fi
      dbx_log "Recreating container..."
      dbx_remove_container "$CONTAINER_NAME"
      dbx_cleanup_desktop_files "$CONTAINER_NAME"
      dbx_create_container "$CONTAINER_NAME" "$CONTAINER_IMAGE"
      setup_handbrake
    elif dbx_container_exists "$CONTAINER_NAME"; then
      dbx_log "Container '${CONTAINER_NAME}' exists."
      # Check if HandBrake is actually installed
      if ! dbxe -- which ghb &>/dev/null; then
        dbx_log "HandBrake not found in container, installing..."
        setup_handbrake
      fi
    else
      dbx_log "Container not found. Creating..."
      dbx_create_container "$CONTAINER_NAME" "$CONTAINER_IMAGE"
      setup_handbrake
    fi
    if dbx_is_exported "$CONTAINER_NAME" "ghb"; then
      dbx_log "HandBrake already exported."
    else
      do_export
    fi
    dbx_log "Installation complete."
    ;;
  recreate)
    if dbx_container_exists "$CONTAINER_NAME"; then
      if ! dbx_confirm "This will recreate the '${CONTAINER_NAME}' container. All existing data and exports will be lost."; then
        dbx_log "Recreation cancelled."
        exit 0
      fi
    fi
    dbx_log "Recreating container..."
    dbx_remove_container "$CONTAINER_NAME"
    dbx_cleanup_desktop_files "$CONTAINER_NAME"
    dbx_create_container "$CONTAINER_NAME" "$CONTAINER_IMAGE"
    setup_handbrake
    do_export
    dbx_log "Installation complete."
    ;;
  default)
    if dbx_container_exists "$CONTAINER_NAME"; then
      dbx_log "Container '${CONTAINER_NAME}' exists."
      # Check if HandBrake is actually installed
      if ! dbxe -- which ghb &>/dev/null; then
        dbx_log "HandBrake not found in container, installing..."
        setup_handbrake
      fi
      if ! dbx_is_exported "$CONTAINER_NAME" "ghb"; then
        dbx_log "Export missing. Re-exporting..."
        do_export
      fi
    else
      dbx_log "Container not found. Creating..."
      dbx_create_container "$CONTAINER_NAME" "$CONTAINER_IMAGE"
      setup_handbrake
      do_export
      dbx_log "Installation complete."
    fi
    ;;
  esac
}

do_export() {
  dbx_log "Exporting HandBrake (ghb)..."
  if dbxe -- distrobox-export -a ghb 2>&1; then
    dbx_log "Export successful."
  else
    if dbx_is_exported "$CONTAINER_NAME" "ghb"; then
      dbx_log "Export successful (verified)."
    else
      dbx_err "Export failed."
      return 1
    fi
  fi
}

main "$@"
