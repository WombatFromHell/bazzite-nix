#!/usr/bin/env bash
set -euo pipefail

#==============================================================================
# CONFIGURATION
#==============================================================================
readonly CONTAINER_NAME="${CONTAINER_NAME:-libvirtbox}"
readonly CONTAINER_IMAGE="${CONTAINER_IMAGE:-fedora:43}"
readonly TPM_DEVICE="${TPM_DEVICE:-/dev/tpm0}"

# Packages to install (Fedora naming). Systemd is required for init.
readonly PACKAGES=(
  "systemd"
  "qemu-system-x86-core"
  "qemu-img"
  "libvirt"
  "libvirt-daemon"
  "libvirt-daemon-config-network"
  "virt-manager"
  "virt-install"
  "virt-viewer"
  "edk2-ovmf"
  "swtpm"
  "swtpm-tools"
  "qemu-device-display-virtio-gpu"
)

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
  --install      Install and export virt-manager to host (idempotent)
  --uninstall    Remove virt-manager export from host (does not uninstall from container)
  --rm           Also remove container (use with --uninstall)
  --help         Show this help message

Examples:
  ${0##*/}                   # Install virt-manager and export
  ${0##*/} --install         # Same as above (idempotent)
  ${0##*/} --uninstall       # Remove export from host
  ${0##*/} --rm --uninstall  # Remove export and delete container
  ${0##*/} --recreate        # Recreate container and reinstall

Description:
  Installs QEMU with TPM passthrough support, libvirt, and virt-manager
  inside a Fedora 43 distrobox container, then exports virt-manager to host.

Requirements:
  - TPM device at ${TPM_DEVICE}
  - Rootful container support
EOF
}

create_container() {
  local additional_flags=""

  additional_flags="--volume ${TPM_DEVICE}:${TPM_DEVICE}"
  additional_flags="${additional_flags} --device /dev/dri"
  additional_flags="${additional_flags} --device /dev/kvm"
  additional_flags="${additional_flags} --security-opt label=disable"

  # Add vhost-net conditionally
  if [[ -e /dev/vhost-net ]]; then
    additional_flags="${additional_flags} --device /dev/vhost-net"
  fi

  dbx_log "Creating container..."
  distrobox create \
    --root \
    -Y \
    --name "${CONTAINER_NAME}" \
    --image "${CONTAINER_IMAGE}" \
    --pull \
    --init \
    --additional-packages "${PACKAGES[*]}" \
    --additional-flags "${additional_flags}"

  # Enter to trigger init system startup
  dbx_log "Starting container..."
  distrobox enter --root "${CONTAINER_NAME}" -- echo "Container started"

  # Run initialization hooks (already root in --root mode)
  dbx_log "Running init hooks..."
  distrobox enter --root "${CONTAINER_NAME}" -- bash -c '
    sudo useradd -m -s /bin/bash '"${USER}"' 2>/dev/null || true;
    sudo usermod -aG libvirt,kvm,wheel '"${USER}"' 2>/dev/null || true;
    sudo grep -q "seccomp_sandbox = 0" /etc/libvirt/qemu.conf || echo "seccomp_sandbox = 0" | sudo tee -a /etc/libvirt/qemu.conf;
    sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket virtnodedevd.socket || true;
    sudo setenforce 0 || true;
  '
}

do_export() {
  dbx_log "Exporting virt-manager..."
  if distrobox-enter --root "${CONTAINER_NAME}" -- distrobox-export -a virt-manager 2>&1; then
    dbx_log "Export successful."
  else
    if dbx_is_exported "$CONTAINER_NAME" "virt-manager"; then
      dbx_log "Export successful (verified)."
    else
      dbx_err "Export failed."
      return 1
    fi
  fi
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
      dbx_do_remove "$CONTAINER_NAME" "virt-manager" "true"
    else
      dbx_do_uninstall "$CONTAINER_NAME" "virt-manager" "true"
    fi
    exit 0
    ;;
  install)
    if [[ "$RECREATE" == "true" ]]; then
      if dbx_container_exists "$CONTAINER_NAME" "true"; then
        if ! dbx_confirm "This will recreate the '${CONTAINER_NAME}' container. All existing data and exports will be lost."; then
          dbx_log "Recreation cancelled."
          exit 0
        fi
      fi
      dbx_log "Recreating container..."
      dbx_remove_container "$CONTAINER_NAME" "true"
      dbx_cleanup_desktop_files "$CONTAINER_NAME"
      create_container
    elif dbx_container_exists "$CONTAINER_NAME" "true"; then
      dbx_log "Container '${CONTAINER_NAME}' exists."
      # Check if virt-manager is actually installed
      if ! distrobox-enter --root "${CONTAINER_NAME}" -- which virt-manager &>/dev/null; then
        dbx_log "virt-manager not found in container, reinstalling..."
        create_container
      fi
    else
      dbx_log "Container not found. Creating..."
      create_container
    fi
    if dbx_is_exported "$CONTAINER_NAME" "virt-manager"; then
      dbx_log "virt-manager already exported."
    else
      do_export
    fi
    dbx_log "Installation complete."
    ;;
  recreate)
    if dbx_container_exists "$CONTAINER_NAME" "true"; then
      if ! dbx_confirm "This will recreate the '${CONTAINER_NAME}' container. All existing data and exports will be lost."; then
        dbx_log "Recreation cancelled."
        exit 0
      fi
    fi
    dbx_log "Recreating container..."
    dbx_remove_container "$CONTAINER_NAME" "true"
    dbx_cleanup_desktop_files "$CONTAINER_NAME"
    create_container
    do_export
    dbx_log "Installation complete."
    ;;
  default)
    if dbx_container_exists "$CONTAINER_NAME" "true"; then
      dbx_log "Container '${CONTAINER_NAME}' exists."
      # Check if virt-manager is actually installed
      if ! distrobox-enter --root "${CONTAINER_NAME}" -- which virt-manager &>/dev/null; then
        dbx_log "virt-manager not found in container, reinstalling..."
        create_container
      fi
      if ! dbx_is_exported "$CONTAINER_NAME" "virt-manager"; then
        dbx_log "Export missing. Re-exporting..."
        do_export
      fi
    else
      dbx_log "Container not found. Creating..."
      create_container
      do_export
      dbx_log "Installation complete."
    fi
    ;;
  esac
}

main "$@"
