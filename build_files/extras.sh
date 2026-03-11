#!/usr/bin/env bash

# include niri + DMS and friends from a verified repo
dnf5 -y copr enable avengemedia/dms-git &&
  dnf5 -y install niri dms danksearch dgop fuzzel kanshi cava matugen cups-pk-helper xdg-desktop-portal-kde
