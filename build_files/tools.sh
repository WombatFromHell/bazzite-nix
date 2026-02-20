#!/usr/bin/env bash

# install some extra tools
dnf5 -y install --enable-repo=terra \
  qt5-qttools qt6-qttools \
  tmux \
  ghostty ghostty-bat-syntax ghostty-shell-integration ghostty-terminfo
