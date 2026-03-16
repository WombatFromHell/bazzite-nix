#!/usr/bin/env bash

# include niri + DMS and friends from a verified repo
dnf5 -y copr enable avengemedia/dms-git &&
  dnf5 -y install niri dms danksearch dgop fuzzel kanshi cava matugen cups-pk-helper xdg-desktop-portal-kde qt6ct-kde

# include some extra hyprland tools for wlroots desktops
dnf5 -y copr enable solopasha/hyprland &&
  dnf5 -y install hyprpicker hyprshot

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

# use a workaround to avoid the "white dialog" problem in xwaylandvideobridge
XWVB_GLOBAL_TGT="/usr/share/applications/org.kde.xwaylandvideobridge.desktop"
XWVB_XDG_TGT="/etc/xdg/autostart/org.kde.xwaylandvideobridge.desktop"
sed -i '/^OnlyShowIn=/d' "$XWVB_GLOBAL_TGT" && echo "OnlyShowIn=KDE;GNOME;" | tee -a "$XWVB_GLOBAL_TGT"
sed -i '/^OnlyShowIn=/d' "$XWVB_XDG_TGT" && echo "OnlyShowIn=KDE;GNOME;" | tee -a "$XWVB_XDG_TGT"
