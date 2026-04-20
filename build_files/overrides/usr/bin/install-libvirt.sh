#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

#==============================================================================
# CONFIGURATION
#==============================================================================
CONTAINER_NAME="${CONTAINER_NAME:-libvirtbox}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-fedora:43}"
readonly TPM_DEVICE="${TPM_DEVICE:-/dev/tpm0}"
DBX_USE_ROOT="true"
DBX_EXPORT_APP="virt-manager"
DBX_INIT="systemd"
DBX_UNSHARE_ALL="true"

DBX_PACKAGES="qemu-system-x86-core qemu-img libvirt libvirt-daemon libvirt-daemon-config-network virt-manager virt-install virt-viewer edk2-ovmf swtpm swtpm-tools qemu-device-display-virtio-gpu"

DBX_FLAGS="--volume ${TPM_DEVICE}:${TPM_DEVICE} --device /dev/dri --device /dev/kvm --security-opt label=disable"

_dbx_libvirt_add_vhost_net() {
  [[ -e /dev/vhost-net ]] && echo "--device /dev/vhost-net"
}

DBX_CHECK_APP="virt-manager"

DBX_INIT_HOOKS=(
  "useradd -m -s /bin/bash ${USER} 2>/dev/null || true"
  "usermod -aG libvirt,kvm,wheel ${USER} 2>/dev/null || true"
  "echo 'seccomp_sandbox = 0' >> /etc/libvirt/qemu.conf || true"
  "setenforce 0 || true"
  "systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket virtnodedevd.socket || true"
)

DBX_POST_HOOKS=(
  "distrobox-export -a virt-manager"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/distrobox-installer.sh"

# Also add vhost-net if available
DBX_FLAGS="${DBX_FLAGS} $(_dbx_libvirt_add_vhost_net)"

#==============================================================================
# HELP
#==============================================================================

show_help() {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]

Options:
  --recreate     Force recreation of the container
  --freshen     Re-run post-hooks, refresh exports
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
  ${0##*/} --freshen        # Re-run post-hooks

Description:
  Installs QEMU with TPM passthrough support, libvirt, and virt-manager
  inside a Fedora 43 distrobox container, then exports virt-manager to host.

Requirements:
  - TPM device at ${TPM_DEVICE}
  - Rootful container support
EOF
}

#==============================================================================
# MAIN
#==============================================================================

main() {
  dbx_main "$(show_help)" "$@"
}

main "$@"
