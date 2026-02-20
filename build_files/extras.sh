#!/usr/bin/env bash

# include 'niri', 'dms', 'fuzzel', 'kanshi', and 'quickshell' from a verified repo
dnf5 -y copr enable avengemedia/dms &&
  dnf5 -y install quickshell niri dms fuzzel kanshi
# include 'noctalia-shell' and 'cliphist' from third-party (unverified) repo
dnf5 -y copr enable zhangyi6324/noctalia-shell &&
  dnf5 -y install noctalia-shell cliphist
