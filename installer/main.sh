#!/usr/bin/env bash
#
# Project Titanoboa
#
# Description: Create bootable ISOs from bootc container images.
# Container-native ISO contract v0.1.0
# See https://github.com/ondrejbudai/bootc-isos/tree/main
#
# This spec is inspired by the layout of Fedora bootc images and Fedora live ISO images.
#
# - The kernel is expected to be in /usr/lib/module/*/vmlinuz. If there are multiple kernels, the behavior is unspecified.
# - The initramfs is expected to be next to the kernel with the filename initramfs.img.
# - The UEFI vendor is specified by a directory name in /usr/lib/efi/shim/*/EFI/$VENDOR.
# - Shim and grub2 EFI binaries (shimx64.efi, mmx64.efi, gcdx64.efi) are expected to be in /boot/efi/EFI/$VENDOR.
# - GRUB2 modules are expected to be in /usr/lib/grub/i386-pc.
# - Required executables are podman, mksquashfs, xorriso, implantisomd5, grub2-mkimage, and python.
# - The container image is converted to a squashfs archive and put into /LiveOS/squashfs.img in the ISO.
# - Additional configuration can be written into /usr/lib/bootc-image-builder/iso.yaml in YAML format.

set -eo pipefail

# Signal handler for clean cancellation
cleanup() {
  echo ""
  echo "Received interrupt signal, stopping..."
  if [[ -n "${CONTAINER_PID:-}" ]]; then
    kill "$CONTAINER_PID" 2>/dev/null || true
    wait "$CONTAINER_PID" 2>/dev/null || true
  fi
  exit 130
}

trap cleanup INT TERM

{
  # Image to be injected on the iso as squashfs. Example: localhost/live_env:latest
  TITANOBOA_CTR_IMAGE=${1:-${TITANOBOA_CTR_IMAGE}}

  # Directory where the ISO will be stored
  TITANOBOA_OUTPUT_DIR=${TITANOBOA_OUTPUT_DIR:-./output}

  # Whenever Titanoboa is running inside a container
  TITANOBOA_INSIDE_CONTAINER=${TITANOBOA_INSIDE_CONTAINER:-false}

  SCRIPT_DIR=$(dirname "$0")
  mkdir -p "$TITANOBOA_OUTPUT_DIR"

  # If we are running inside a container
  if [ "$TITANOBOA_INSIDE_CONTAINER" = "true" ]; then
    TITANOBOA_OUTPUT_DIR=/output
    if ! mountpoint -q "$TITANOBOA_OUTPUT_DIR"; then
      echo "Error: output directory must be a volume mountpoint"
      exit 1
    fi
    if ! mountpoint -q /usr/lib/containers/storage; then
      echo "Error: /usr/lib/containers/storage must be a volume mountpoint"
      exit 1
    fi
    if ! mountpoint -q /rootfs; then
      echo "Error: /rootfs must be a volume mountpoint"
      exit 1
    fi
    /app/bin/build_iso.sh
  else
    if [ -z "$TITANOBOA_CTR_IMAGE" ]; then
      echo "Error: container image in param 1 nor TITANOBOA_CTR_IMAGE environment variable"
      exit 1
    fi
    # Run podman in foreground with --init for proper signal handling
    sudo podman run --rm --init \
      --cap-add sys_admin --security-opt label=disable \
      -v "$SCRIPT_DIR"/build_iso.sh:/src/build_iso.sh:ro \
      --mount type=image,source="$TITANOBOA_CTR_IMAGE",dst=/rootfs \
      -v "$TITANOBOA_OUTPUT_DIR":/output \
      docker.io/library/alpine:latest sh -c 'apk add --no-cache bash && exec /src/build_iso.sh'
  fi
} >&2

realpath "$TITANOBOA_OUTPUT_DIR"/*.iso | head -1
