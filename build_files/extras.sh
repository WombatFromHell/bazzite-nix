#!/usr/bin/env bash

# include niri + DMS and friends from a verified repo
dnf5 -y copr enable avengemedia/dms-git &&
  dnf5 -y install niri dms danksearch dgop fuzzel kanshi cava matugen cups-pk-helper xdg-desktop-portal-kde

# use our niri-portals.conf override customized for KDE
PORTALS_GLOBAL="/usr/share/xdg-desktop-portal"
PORTALS_OVERRIDE="/ctx/override/usr/share/xdg-desktop-portal"
if [ -r "$PORTALS_GLOBAL"/niri-portals.conf ]; then
  # backup our default niri-portals.conf
  mv "$PORTALS_GLOBAL"/niri-portals.conf "$PORTALS_GLOBAL"/niri-portals.conf.bak
  cp -f "$PORTALS_OVERRIDE"/niri-portals.conf "$PORTALS_GLOBAL"/niri-portals.conf
fi

# use our niri config override as well
NIRI_GLOBAL="/etc/niri"
NIRI_OVERRIDE="/ctx/override/etc/niri"
mkdir -p "$NIRI_GLOBAL"
cp -f "$NIRI_OVERRIDE"/config.kdl "$NIRI_GLOBAL"/config.kdl
