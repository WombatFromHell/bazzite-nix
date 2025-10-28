#!/usr/bin/env bash
set -ouex pipefail

# nix installer enablement
mkdir -p /nix

# install some extra tools
dnf5 install --enable-repo=terra -y \
  qt5-qttools \
  qt6-qttools \
  tmux \
  kitty kitty-shell-integration kitty-terminfo

# clean up after ourselves
dnf5 clean all &&
  rm -rf /var/cache/dnf /var/lib/dnf /var/lib/waydroid /var/lib/selinux /var/log/*
