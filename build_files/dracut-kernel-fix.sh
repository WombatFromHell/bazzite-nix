#!/usr/bin/env bash

if ! grep -q layout=ostree /usr/lib/kernel/install.conf; then
  echo "Enabling kernel-install for ostree/bootc images..."
  echo layout=ostree >>/usr/lib/kernel/install.conf
fi

# Create dracut config directory and add ostree module configuration
mkdir -p /usr/lib/dracut/dracut.conf.d
cat >/usr/lib/dracut/dracut.conf.d/99-bootc.conf <<EOF
# Required modules for ostree/bootc boot
add_dracutmodules+=" ostree "
# Include virtio drivers for qemu
add_drivers+=" virtio virtio_blk virtio_scsi virtio_pci "
# Include filesystem drivers needed for root mount
filesystems+=" btrfs ext4 ext3 xfs squashfs overlay "
# Disable hostonly mode for container builds - we need generic initramfs
# that can boot on any hardware, not just the build host
hostonly="no"
hostonly_cmdline="no"
EOF

# Set up dracut configuration for ostree/bootc images
# Disable xattr preservation to avoid errors in container build environment
export DRACUT_NO_XATTR=1
# Run depmod to generate module dependencies
depmod -a "${KERNEL_VERSION}"

# Generate initramfs with ostree support and host-specific modules
# This is required because tsflags=noscripts skips the kernel RPM postinst that runs dracut
echo "Generating initramfs for kernel ${KERNEL_VERSION}..."
dracut -f \
  "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img" \
  "${KERNEL_VERSION}"

# Verify initramfs was created
if [[ ! -f "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img" ]]; then
  echo "ERROR: initramfs.img was not created for kernel ${KERNEL_VERSION}"
  exit 1
else
  echo "initramfs.img created successfully"
fi
