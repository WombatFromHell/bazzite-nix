#!/usr/bin/env bash
set -exo pipefail
{ export PS4='+( ${BASH_SOURCE}:${LINENO} ): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'; } 2>/dev/null

# Signal handler for clean cancellation
cleanup() {
  echo ""
  echo "Received interrupt signal, cleaning up..."
  # Kill any background processes
  jobs -p | xargs -r kill 2>/dev/null || true
  exit 130
}

trap cleanup INT TERM

apk add --no-cache \
  bash \
  coreutils \
  dosfstools \
  e2fsprogs \
  jq \
  mtools \
  squashfs-tools \
  util-linux \
  xorriso \
  yq

mkdir -p \
  /work \
  /work/iso-root \
  /work/iso-root/boot/grub2 \
  /work/iso-root/boot/grub2/i386-pc \
  /work/iso-root/images/pxeboot \
  /work/iso-root/LiveOS

cd /work || exit 1

# Find the kernel
KERNEL_VERSION=""
KERNEL_DIR=""
for dir in /rootfs/usr/lib/modules/*/; do
  if [[ -f "${dir}vmlinuz" ]]; then
    KERNEL_DIR="${dir%/}"
    KERNEL_VERSION=$(basename "$dir")
    break
  fi
done

if [[ -z "$KERNEL_VERSION" ]]; then
  echo "ERROR: Could not find kernel"
  exit 1
fi

echo "Found kernel: $KERNEL_VERSION"
echo "Using pre-built initramfs with live boot support..."

# Create the squashfs directly from /rootfs
echo "Creating squashfs from rootfs..."
mksquashfs /rootfs /work/iso-root/LiveOS/squashfs.img -all-root -noappend -e sysroot -e ostree -comp zstd -Xcompression-level 12

# Copy kernel and initramfs from /rootfs to the ISO boot location
cp -av "${KERNEL_DIR}/vmlinuz" /work/iso-root/images/pxeboot/vmlinuz
cp -av "${KERNEL_DIR}/initramfs.img" /work/iso-root/images/pxeboot/initrd.img

echo "Boot files copied:"
ls -lh /work/iso-root/images/pxeboot/

# Copy GRUB modules from /rootfs
cp -avT /rootfs/usr/lib/grub/i386-pc /work/iso-root/boot/grub2/i386-pc

# Copy efi dir from /rootfs
cp -avT /rootfs/boot/efi/EFI /work/EFI

iso_config_file=/rootfs/usr/lib/bootc-image-builder/iso.yaml
if [[ ! -f $iso_config_file ]]; then
  echo >&2 "ERROR: Missing /usr/lib/bootc-image-builder/iso.yaml file"
  exit 1
fi

iso_label=$(yq '.label' <"$iso_config_file")

# Generate grub.cfg for ISO filesystem (BIOS boot)
# Uses lowercase paths to match Rock Ridge filenames on ISO
{
  echo "set default=$(yq '.grub2.default' <"$iso_config_file")"
  echo "set timeout=$(yq '.grub2.timeout' <"$iso_config_file")"
  echo ""
  yq -o=json '.grub2.entries' <"$iso_config_file" | jq -c '.[]' | while read -r entry; do
    name=$(echo "$entry" | jq -r '.name')
    linux=$(echo "$entry" | jq -r '.linux')
    initrd=$(echo "$entry" | jq -r '.initrd')
    cat <<EOF
menuentry "$name" {
    linux $linux
    initrd $initrd
}
EOF
  done
} >"/work/iso-root/boot/grub2/grub.cfg"

# Generate grub.cfg for EFI partition (UEFI boot)
# EFI partition uses lowercase paths and different prefix
mkdir -p /work/EFI/BOOT
{
  echo "set default=$(yq '.grub2.default' <"$iso_config_file")"
  echo "set timeout=$(yq '.grub2.timeout' <"$iso_config_file")"
  echo ""
  yq -o=json '.grub2.entries' <"$iso_config_file" | jq -c '.[]' | while read -r entry; do
    name=$(echo "$entry" | jq -r '.name')
    linux=$(echo "$entry" | jq -r '.linux')
    initrd=$(echo "$entry" | jq -r '.initrd')
    cat <<EOF
menuentry "$name" {
    linux $linux
    initrd $initrd
}
EOF
  done
} >"/work/EFI/BOOT/grub.cfg"

# For some reason, fedora also copies EFI into /boot/EFI (?), probably because of hardcoded prefix in grub/shim
cp -avT /work/EFI /work/iso-root/EFI

# Generate uefi.img
pushd /work || exit 1
truncate -s 100M /work/uefi.img
mkfs.fat -F32 /work/uefi.img
mcopy -v -i /work/uefi.img -s /work/EFI ::

xorriso -as mkisofs \
  -R \
  -V "$iso_label" \
  -partition_offset 16 \
  -appended_part_as_gpt \
  -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B ./uefi.img \
  -iso_mbr_part_type EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
  -e --interval:appended_partition_2:all:: \
  -no-emul-boot \
  -iso-level 3 \
  -o "/output/$iso_label.iso" \
  iso-root
