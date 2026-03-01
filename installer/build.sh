#!/usr/bin/env bash
# Titanoboa Live ISO Build Script for bazzite-nix
# This script runs INSIDE a container created from the payload image
# and modifies the container's rootfs in place.
set -exo pipefail
{ export PS4='+( ${BASH_SOURCE}:${LINENO} ): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'; } 2>/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE=${BASE_IMAGE:?}
INSTALL_IMAGE_PAYLOAD=${INSTALL_IMAGE_PAYLOAD:?}

mkdir -p "$(realpath /root)"

# Try to remount /proc/sys for bwrap (may fail in nested containers)
mount -o remount,rw /proc/sys 2>/dev/null || echo "Note: Could not remount /proc/sys"

mkdir -p /var/tmp

echo "Live ISO will install: $INSTALL_IMAGE_PAYLOAD"

# Find kernel version by locating vmlinuz (iterate through all module dirs)
KERNEL_VERSION=""
for dir in /usr/lib/modules/*/; do
    if [[ -f "${dir}vmlinuz" ]]; then
        KERNEL_VERSION=$(basename "$dir")
        break
    fi
done

KERNEL_DIR="/usr/lib/modules/${KERNEL_VERSION}"
if [[ -z "$KERNEL_VERSION" ]]; then
    echo "ERROR: Could not find kernel vmlinuz in /usr/lib/modules/"
    exit 1
fi
echo "Found kernel: $KERNEL_VERSION"

# Verify initramfs exists
if [[ ! -f "${KERNEL_DIR}/initramfs.img" ]]; then
    echo "ERROR: Could not find initramfs.img at ${KERNEL_DIR}/initramfs.img"
    exit 1
fi
echo "Found initramfs: ${KERNEL_DIR}/initramfs.img"

# The kernel and initramfs from the base image are used directly by titanoboa
# We just need to install live session packages

# Install livesys-scripts for live session support
dnf install -y livesys-scripts
if [[ ${BASE_IMAGE} == *-gnome* ]]; then
    sed -i "s/^livesys_session=.*/livesys_session=gnome/" /etc/sysconfig/livesys
else
    sed -i "s/^livesys_session=.*/livesys_session=kde/" /etc/sysconfig/livesys
fi
systemctl enable livesys.service livesys-late.service

# Run postrootfs hook (anaconda, kickstart)
"$SCRIPT_DIR/titanoboa_hook_postrootfs.sh"

# EFI setup for ISO boot
dnf install -y grub2-efi-x64-cdboot
mkdir -p /boot/efi
cp -av /usr/lib/efi/*/*/EFI /boot/efi/
cp -v /boot/efi/EFI/fedora/grubx64.efi /boot/efi/EFI/BOOT/fbx64.efi

# Timezone
rm -f /etc/localtime
systemd-firstboot --timezone UTC

# tmpfs mount for /var/tmp (live ISO runtime)
cat >/etc/systemd/system/var-tmp.mount <<'EOF'
[Unit]
Description=Larger tmpfs for /var/tmp on live system

[Mount]
What=tmpfs
Where=/var/tmp
Type=tmpfs
Options=size=50%%,nr_inodes=1m,x-systemd.graceful-option=usrquota

[Install]
WantedBy=local-fs.target
EOF
systemctl enable var-tmp.mount

# ISO config for titanoboa
mkdir -p /usr/lib/bootc-image-builder
cp /src/iso.yaml /usr/lib/bootc-image-builder/iso.yaml

dnf clean all
