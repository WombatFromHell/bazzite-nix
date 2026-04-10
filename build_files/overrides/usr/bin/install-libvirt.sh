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

#==============================================================================
# UTILITIES
#==============================================================================
log() { printf "\e[1;34m>>\e[0m %s\n" "$@"; }
err() { printf "\e[1;31m!!\e[0m %s\n" "$@" >&2; }

is_inside_container() { [[ -f /var/run/.containerenv ]]; }

container_exists() {
  # grep -q is quiet, -w matches whole words (prevents matching 'libvirtbox-2')
  distrobox list --root 2>/dev/null | grep -qw "${CONTAINER_NAME}"
}

is_exported() {
  local desktop_file="$HOME/.local/share/applications/${CONTAINER_NAME}-virt-manager.desktop"
  [[ -f "$desktop_file" ]]
}

#==============================================================================
# ACTIONS
#==============================================================================

show_help() {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]

Options:
  --recreate     Force recreation of the container
  --install      Export virt-manager to host (idempotent)
  --uninstall    Remove virt-manager export from host (idempotent)
  --help         Show this help message

Description:
  Installs QEMU with TPM passthrough support, libvirt, and virt-manager
  inside a Fedora 43 distrobox container, then exports virt-manager to host.

Requirements:
  - TPM device at ${TPM_DEVICE}
  - Rootful container support
EOF
}

do_uninstall() {
  log "Removing virt-manager export..."

  # Attempt to unexport via distrobox if container exists
  if container_exists; then
    distrobox-enter --root "${CONTAINER_NAME}" -- distrobox-export -d -a virt-manager 2>/dev/null || true
  fi

  # Ensure local desktop file is removed
  rm -f "$HOME/.local/share/applications/${CONTAINER_NAME}-virt-manager.desktop"
  log "Uninstall complete."
}

do_export() {
  log "Exporting virt-manager..."
  if distrobox-enter --root "${CONTAINER_NAME}" -- distrobox-export -a virt-manager 2>&1; then
    log "Export successful."
  else
    # Validate manually in case of benign warnings
    if is_exported; then
      log "Export successful (verified)."
    else
      err "Export failed."
      return 1
    fi
  fi
}

create_container() {
  local assemble_file
  assemble_file=$(mktemp)

  # Ensure cleanup on function exit
  trap 'rm -f "${assemble_file:-}"' RETURN

  # Prepare dynamic flags
  local additional_flags=(
    "--volume ${TPM_DEVICE}:${TPM_DEVICE}"
    "--device /dev/dri"
    "--device /dev/kvm"
    "--security-opt label=disable"
  )

  # Add vhost-net conditionally
  if [[ -e /dev/vhost-net ]]; then
    additional_flags+=("--device /dev/vhost-net")
  fi

  # Join flags into a single string for the INI file
  local flags_str="${additional_flags[*]}"
  local pkgs_str="${PACKAGES[*]}"

  log "Creating container configuration..."
  cat >"${assemble_file}" <<EOF
[${CONTAINER_NAME}]
image=${CONTAINER_IMAGE}
pull=true
init=true
root=true
start_now=true
unshare_all=true
additional_packages="${pkgs_str}"
additional_flags="${flags_str}"
init_hooks=useradd -m -s /bin/bash ${USER} 2>/dev/null || true;
init_hooks=usermod -aG libvirt,kvm,wheel ${USER} 2>/dev/null || true;
init_hooks=echo 'seccomp_sandbox = 0' >> /etc/libvirt/qemu.conf;
init_hooks=systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket virtnodedevd.socket || true;
init_hooks=setenforce 0 || true;
exported_apps="virt-manager"
EOF

  log "Assembling container..."
  distrobox assemble create --file "${assemble_file}" --replace
}

#==============================================================================
# MAIN
#==============================================================================

main() {
  # Guard: Do not run inside the container
  if is_inside_container; then
    exit 0
  fi

  local action="default"

  # Parse Arguments
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

  # Dispatch Actions
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
      log "virt-manager already exported."
    else
      do_export
    fi
    exit 0
    ;;
  recreate)
    log "Recreating container..."
    # distrobox assemble --replace handles removal, but we can be explicit if needed
    create_container
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
      do_export
      log "Installation complete."
    fi
    ;;
  esac
}

main "$@"
