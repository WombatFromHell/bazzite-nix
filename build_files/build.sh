#!/usr/bin/env bash
set -ouex pipefail

# nix installer enablement
mkdir -p /nix

# install some extra tools
dnf5 install --enable-repo=terra -y \
  qt5-qttools \
  qt6-qttools \
  tmux \
  alacritty \
  kitty kitty-shell-integration kitty-terminfo \
  ghostty ghostty-bat-syntax ghostty-shell-integration ghostty-terminfo

# include 'niri', 'dms', 'fuzzel', and 'quickshell' from a verified repo
dnf5 -y copr enable avengemedia/dms &&
  dnf5 -y install quickshell niri dms fuzzel
# include 'noctalia-shell' and 'cliphist' from third-party (unverified) repo
dnf5 -y copr enable zhangyi6324/noctalia-shell &&
  dnf5 -y install noctalia-shell cliphist

# include faugus-launcher
dnf5 -y copr enable faugus/faugus-launcher &&
  dnf5 -y install faugus-launcher

# clean up after ourselves
dnf5 clean all &&
  rm -rf /var/cache/dnf /var/lib/dnf /var/lib/waydroid /var/lib/selinux /var/log/*
