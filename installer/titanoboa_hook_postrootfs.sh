#!/usr/bin/env bash
# Titanoboa Post-Rootfs Hook for bazzite-nix
# This hook runs after rootfs is prepared
set -exo pipefail

# Try to remount /proc/sys for bwrap (may fail in nested containers)
mount -o remount,rw /proc/sys 2>/dev/null || true

# Remove all versionlocks, in order to avoid dependency issues
dnf -qy versionlock clear

# Install Anaconda installer for the live ISO
dnf install -qy --enable-repo=fedora-cisco-openh264 --allowerasing firefox anaconda-live libblockdev-{btrfs,lvm,dm}
mkdir -p /var/lib/rpm-state

# Utilities for installer UI
dnf install -qy --setopt=install_weak_deps=0 qrencode yad

# Variables
imageref="$(podman images --format '{{ index .Names 0 }}\n' 'bazzite-nix*' | head -1)"
imageref="${imageref##*://}"
imageref="${imageref%%:*}"
imagetag="$(podman images --format '{{ .Tag }}\n' "$imageref" | head -1)"

# Default kickstart for anaconda - switches to the target image after install
cat <<EOF >/usr/share/anaconda/interactive-defaults.ks
# Create log directory
%pre
mkdir -p /tmp/anaconda_custom_logs
%end

# Remove the efi dir, must match efi_dir from the profile config
%pre-install --erroronfail
rm -rf /mnt/sysroot/boot/efi/EFI/fedora
%end

# Relabel the boot partition
%pre-install --erroronfail --log=/tmp/anaconda_custom_logs/repartitioning.log
set -x
xboot_dev=\$(findmnt -o SOURCE --nofsroot --noheadings -f --target /mnt/sysroot/boot)
if [[ -z \$xboot_dev ]]; then
    echo "ERROR: xboot_dev not found"
    exit 1
fi
e2label "\$xboot_dev" "bazzite-nix_xboot"
%end

# Switch to target container image after installation
%post --erroronfail --log=/tmp/anaconda_custom_logs/bootc-switch.log
bootc switch --mutate-in-place --transport registry ${imageref}:${imagetag:-latest}
%end

# Error handling - show logs on failure
%onerror
run0 --user=liveuser yad \
    --timeout=0 \
    --text-info \
    --no-buttons \
    --width=600 \
    --height=400 \
    --text="An error occurred during installation. Please report this issue to the developers." \
    < /tmp/anaconda.log
%end
EOF

### Live session tweaks ###

# Disable services that shouldn't run in live session
(
    set +e
    for s in \
        rpm-ostree-countme.service \
        rpm-ostreed-automatic.timer \
        podman-auto-update.timer; do
        systemctl disable "$s" 2>/dev/null || true
    done
)

# Clean up dnf cache
dnf clean all
