#!/usr/bin/env bash
set -euo pipefail

#==============================================================================
# CONFIGURATION
#==============================================================================
readonly CONTAINER_NAME="${CONTAINER_NAME:-encoderbox}"
readonly CONTAINER_IMAGE="${CONTAINER_IMAGE:-archlinux:latest}"

#==============================================================================
# UTILITIES
#==============================================================================
log() { printf "\e[1;34m>>\e[0m %s\n" "$@"; }
err() { printf "\e[1;31m!!\e[0m %s\n" "$@" >&2; }

is_inside_container() { [[ -f /var/run/.containerenv ]]; }

container_exists() {
  distrobox list 2>/dev/null | grep -qw "${CONTAINER_NAME}"
}

is_exported() {
  local desktop_file="$HOME/.local/share/applications/${CONTAINER_NAME}-ghb.desktop"
  [[ -f "$desktop_file" ]]
}

# Shortcut for distrobox-enter commands
dbxe() { distrobox-enter "${CONTAINER_NAME}" -- "$@"; }

#==============================================================================
# ACTIONS
#==============================================================================

show_help() {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]

Options:
  --recreate     Force recreation of the container
  --install      Export HandBrake (ghb) to host (idempotent)
  --uninstall    Remove HandBrake export from host (idempotent)
  --help         Show this help message

Description:
  Installs HandBrake with AMDGPU Pro support inside an Arch Linux
  distrobox container using yay (AUR helper), then exports ghb to host.
EOF
}

do_uninstall() {
  log "Removing HandBrake export..."

  if container_exists; then
    dbxe distrobox-export -d -a ghb 2>/dev/null || true
  fi

  rm -f "$HOME/.local/share/applications/${CONTAINER_NAME}-ghb.desktop"
  log "Uninstall complete."
}

do_export() {
  log "Exporting HandBrake (ghb)..."
  if dbxe distrobox-export -a ghb 2>&1; then
    log "Export successful."
  else
    if is_exported; then
      log "Export successful (verified)."
    else
      err "Export failed."
      return 1
    fi
  fi
}

setup_handbrake() {
  log "Installing HandBrake inside container..."

  # Step 1: Install git, base-devel, and yay-bin from AUR
  dbxe bash -c '
    sudo pacman -S --needed --noconfirm git base-devel && \
    git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin && \
    cd /tmp/yay-bin && \
    makepkg -si --noconfirm && \
    cd .. && rm -rf /tmp/yay-bin
  '

  # Step 2: Install amf-amdgpu-pro and handbrake via yay
  dbxe yay -Syu --noconfirm amf-amdgpu-pro handbrake gst-plugins-good gst-libav xdg-desktop-portal-gtk

  log "HandBrake installation complete."
}

create_container() {
  log "Creating container '${CONTAINER_NAME}'..."
  distrobox create -i "${CONTAINER_IMAGE}" --name "${CONTAINER_NAME}"
}

#==============================================================================
# MAIN
#==============================================================================

main() {
  if is_inside_container; then
    exit 0
  fi

  local action="default"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --recreate) action="recreate" ;;
    --install) action="install" ;;
    --uninstall) action="uninstall" ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      show_help
      exit 1
      ;;
    esac
    shift
  done

  case "$action" in
  uninstall)
    do_uninstall
    exit 0
    ;;
  install)
    if ! container_exists; then
      err "Container '${CONTAINER_NAME}' not found. Run without flags first."
      exit 1
    fi
    if is_exported; then
      log "HandBrake already exported."
    else
      do_export
    fi
    exit 0
    ;;
  recreate)
    log "Recreating container..."
    distrobox rm -f "${CONTAINER_NAME}" 2>/dev/null || true
    create_container
    setup_handbrake
    do_export
    log "Installation complete."
    ;;
  default)
    if container_exists; then
      log "Container '${CONTAINER_NAME}' exists."
      if ! is_exported; then
        log "Export missing. Re-exporting..."
        do_export
      fi
    else
      log "Container not found. Creating..."
      create_container
      setup_handbrake
      do_export
      log "Installation complete."
    fi
    ;;
  esac
}

main "$@"
