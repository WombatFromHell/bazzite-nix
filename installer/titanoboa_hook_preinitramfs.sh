#!/usr/bin/env bash
# Titanoboa Pre-Initramfs Hook for bazzite-nix
# This hook runs before initramfs regeneration
set -exo pipefail

# For bazzite-nix, we keep the existing kernel from the base image
# This is a simplified hook - extend as needed for custom kernel handling

# Clean up kernel modules directory if needed
# (cd /usr/lib/modules && rm -rf -- ./*)

# If you need to install a custom kernel, uncomment and modify:
# dnf -y versionlock delete kernel kernel-core kernel-devel kernel-modules
# dnf --setopt=protect_running_kernel=False -y remove kernel kernel-core kernel-devel kernel-modules
# dnf -y --repo fedora,updates install kernel kernel-core

# depmod "$(find /usr/lib/modules -maxdepth 1 -type d -printf '%P\n' | grep .)"

# Clean up dnf cache
dnf clean all -yq
