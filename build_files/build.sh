#!/usr/bin/env bash
set -ouex pipefail

# nix installer enablement
mkdir -p /nix

# use cachyos kernel for fedora instead of bazzite kernel
export TMPDIR=/var/tmp
mkdir -p $TMPDIR
#
setsebool -P domain_kernel_load_modules on
#
dnf5 -y copr enable bieszczaders/kernel-cachyos &&
  dnf5 -y remove \
    kernel kernel-core \
    kernel-devel-matched kernel-devel \
    kernel-modules \
    kernel-modules-akmods \
    kernel-modules-core \
    kernel-modules-extra &&
  dnf5 -y install --setopt=tsflags=noscripts kernel-cachyos
#
KERNEL_VERSION=$(rpm -qa --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-cachyos-core)
depmod -a "${KERNEL_VERSION}" &&
  kernel-install add "${KERNEL_VERSION}" "/lib/modules/${KERNEL_VERSION}/vmlinuz"

# install some extra tools
dnf5 -y install --enable-repo=terra \
  qt5-qttools \
  qt6-qttools \
  tmux \
  alacritty \
  kitty kitty-shell-integration kitty-terminfo \
  ghostty ghostty-bat-syntax ghostty-shell-integration ghostty-terminfo

# include 'niri', 'dms', 'fuzzel', 'kanshi', and 'quickshell' from a verified repo
dnf5 -y copr enable avengemedia/dms &&
  dnf5 -y install quickshell niri dms fuzzel kanshi
# include 'noctalia-shell' and 'cliphist' from third-party (unverified) repo
dnf5 -y copr enable zhangyi6324/noctalia-shell &&
  dnf5 -y install noctalia-shell cliphist

# include faugus-launcher
dnf5 -y copr enable faugus/faugus-launcher &&
  dnf5 -y install faugus-launcher

# clean up after ourselves
dnf5 clean all &&
  rm -rf /var/cache/dnf /var/lib/dnf /var/lib/waydroid /var/lib/selinux /var/log/* /var/tmp
