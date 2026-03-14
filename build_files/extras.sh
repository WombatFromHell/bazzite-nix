#!/usr/bin/env bash

# include niri + DMS and friends from a verified repo
dnf5 -y copr enable avengemedia/dms-git &&
  dnf5 -y install niri dms danksearch dgop fuzzel kanshi cava matugen cups-pk-helper xdg-desktop-portal-kde

# use our niri-portals.conf override customized for KDE
install -Z -b -m 644 \
  /ctx/overrides/usr/share/xdg-desktop-portal/niri-portals.conf \
  /usr/share/xdg-desktop-portal/niri-portals.conf
# include our 'spawn-browser.sh' helper referenced by niri
install -Z -m 755 \
  /ctx/overrides/usr/bin/spawn-browser.sh \
  /usr/bin/spawn-browser.sh
# use our niri config override as well
install -Z -D -m 644 \
  /ctx/overrides/etc/niri/config.kdl \
  /etc/niri/config.kdl
