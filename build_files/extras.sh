#!/usr/bin/env bash

# bring in some useful qt5/qt6 tools
dnf5 -y install --enable-repo=terra \
  qt5-qttools qt6-qttools tmux gvfs-smb gvfs-fuse

# include niri + DMS and friends from a verified repo
dnf5 -y copr enable avengemedia/dms-git &&
  dnf5 -y copr disable avengemedia/dms-git &&
  dnf5 -y install --enable-repo="*avengemedia*" \
    niri dms danksearch dgop fuzzel kanshi cava matugen cups-pk-helper xdg-desktop-portal-kde qt6ct-kde \
    ghostty

# include hyprpicker so we get a magnifying glass with our color picker
dnf5 -y copr enable solopasha/hyprland &&
  dnf5 -y copr disable solopasha/hyprland &&
  dnf5 -y install --enable-repo="*solopasha*" hyprpicker

OVERRIDES_ROOT="/ctx/overrides"
# use our niri-portals.conf override customized for KDE
install -Z -b -m 644 \
  "$OVERRIDES_ROOT"/usr/share/xdg-desktop-portal/niri-portals.conf \
  /usr/share/xdg-desktop-portal/niri-portals.conf
# include our helpers referenced by niri
install -Z -m 755 \
  "$OVERRIDES_ROOT"/usr/bin/chromium-flags.sh \
  "$OVERRIDES_ROOT"/usr/bin/spawn-browser.sh \
  "$OVERRIDES_ROOT"/usr/bin/hyprpicker.sh \
  /usr/bin/
# use our niri config override as well
install -Z -D -m 644 \
  "$OVERRIDES_ROOT"/etc/niri/config.kdl \
  /etc/niri/config.kdl
# use our qt6ct override customized for the default Bazzite KDE theme
install -Z -D -m 644 \
  "$OVERRIDES_ROOT"/etc/xdg/qt6ct/qt6ct.conf \
  /etc/xdg/qt6ct/qt6ct.conf

# use a workaround to avoid the "white dialog" problem in xwaylandvideobridge
XWVB_GLOBAL_TGT="/usr/share/applications/org.kde.xwaylandvideobridge.desktop"
XWVB_XDG_TGT="/etc/xdg/autostart/org.kde.xwaylandvideobridge.desktop"
sed -i '/^OnlyShowIn=/d' "$XWVB_GLOBAL_TGT" && echo "OnlyShowIn=KDE;GNOME;" | tee -a "$XWVB_GLOBAL_TGT"
sed -i '/^OnlyShowIn=/d' "$XWVB_XDG_TGT" && echo "OnlyShowIn=KDE;GNOME;" | tee -a "$XWVB_XDG_TGT"

# append our justfile fragment to our existing ujust file
cat "$OVERRIDES_ROOT"/usr/share/ublue-os/justfile.fragment \
  >>/usr/share/ublue-os/justfile
# include a few distrobox related helpers (and .just files for ease of use)
install -Z -m 0755 \
  "$OVERRIDES_ROOT"/usr/bin/install-brave.sh \
  "$OVERRIDES_ROOT"/usr/bin/install-handbrake.sh \
  "$OVERRIDES_ROOT"/usr/bin/install-libvirt.sh \
  "$OVERRIDES_ROOT"/usr/bin/install-neovim.sh \
  /usr/bin/
install -Z -m 0644 \
  "$OVERRIDES_ROOT"/usr/share/ublue-os/just/92-bazzite-verify.just \
  "$OVERRIDES_ROOT"/usr/share/ublue-os/just/93-bazzite-nix-brave.just \
  "$OVERRIDES_ROOT"/usr/share/ublue-os/just/93-bazzite-nix-handbrake.just \
  "$OVERRIDES_ROOT"/usr/share/ublue-os/just/93-bazzite-nix-libvirt.just \
  "$OVERRIDES_ROOT"/usr/share/ublue-os/just/93-bazzite-nix-neovim.just \
  /usr/share/ublue-os/just/
