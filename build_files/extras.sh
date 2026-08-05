#!/usr/bin/env bash

OVERRIDES_ROOT="/ctx/overrides"

# bring in some useful tools from Terra
# shellcheck disable=SC2140
dnf5 config-manager setopt "*terra*".exclude=""
dnf5 -y install --refresh --enable-repo=terra \
  rocm-smi uwsm qt5-qttools qt6-qttools \
  tmux gvfs-smb gvfs-fuse openrgb openrgb-udev-rules \
  gamescope-session-steam
# shellcheck disable=SC2140
dnf5 config-manager setopt "*terra*".exclude="nerd-fonts scx-tools scx-scheds python3-protobuf zlib-devel uupd"

# include DMS and friends from a verified repo
dnf5 -y copr enable avengemedia/dms-git &&
  dnf5 -y copr disable avengemedia/dms-git &&
  dnf5 -y install --enable-repo="*avengemedia*" \
    quickshell-git niri dms danksearch dgop fuzzel \
    cava matugen cups-pk-helper xdg-desktop-portal-kde \
    xdg-desktop-portal-gnome qt6ct-kde ghostty swayidle

# include hyprpicker so we get a magnifying glass with our color picker
dnf5 -y copr enable solopasha/hyprland &&
  dnf5 -y copr disable solopasha/hyprland &&
  dnf5 -y install --enable-repo="*solopasha*" hyprpicker

# use our niri-portals.conf override customized for KDE
install -Z -b -m 0644 \
  "$OVERRIDES_ROOT"/usr/share/xdg-desktop-portal/niri-portals.conf \
  /usr/share/xdg-desktop-portal/niri-portals.conf
# include our helpers referenced by niri
install -Z -m 0755 \
  "$OVERRIDES_ROOT"/usr/bin/chromium-flags.sh \
  "$OVERRIDES_ROOT"/usr/bin/spawn-browser.sh \
  "$OVERRIDES_ROOT"/usr/bin/hyprpicker.sh \
  /usr/bin/
# ensure we install a uwsm session variant for niri
install -Z -D -m 0644 \
  "$OVERRIDES_ROOT"/usr/share/wayland-sessions/niri-uwsm.desktop \
  /usr/share/wayland-sessions/
install -Z -D -m 0644 \
  "$OVERRIDES_ROOT"/usr/share/uwsm/env-niri \
  /usr/share/uwsm/env-niri
# ship some critical Niri (UWSM) support services as user defaults
install -Z -D -m 0644 \
  "$OVERRIDES_ROOT"/usr/lib/systemd/user/*.service \
  /usr/lib/systemd/user/
systemctl --global enable \
  dms-niri-uwsm.service \
  kwallet-pam-init.service \
  polkit-kde-agent.service
systemctl --global disable dms.service fumon.service
# use our niri config override as well
install -Z -D -m 0644 \
  "$OVERRIDES_ROOT"/usr/share/factory/etc/niri/config.kdl \
  /usr/share/factory/etc/niri/config.kdl
# use our qt6ct override customized for the default Bazzite KDE theme
install -Z -D -m 0644 \
  "$OVERRIDES_ROOT"/usr/share/factory/etc/xdg/qt6ct/qt6ct.conf \
  /usr/share/factory/etc/xdg/qt6ct/qt6ct.conf

# use a workaround to avoid the "white dialog" problem in xwaylandvideobridge
XWVB_GLOBAL_TGT="/usr/share/applications/org.kde.xwaylandvideobridge.desktop"
XWVB_XDG_TGT="/etc/xdg/autostart/org.kde.xwaylandvideobridge.desktop"
sed -i '/^OnlyShowIn=/d' "$XWVB_GLOBAL_TGT" && echo "OnlyShowIn=KDE;GNOME;" | tee -a "$XWVB_GLOBAL_TGT"
sed -i '/^OnlyShowIn=/d' "$XWVB_XDG_TGT" && echo "OnlyShowIn=KDE;GNOME;" | tee -a "$XWVB_XDG_TGT"

# append our justfile fragment to our existing ujust file
cat "$OVERRIDES_ROOT"/usr/share/ublue-os/justfile.fragment \
  >>/usr/share/ublue-os/justfile
# include some helpers (and .just files for ease of use)
install -Z -m 0755 \
  "$OVERRIDES_ROOT"/usr/bin/verify-attestation.sh \
  "$OVERRIDES_ROOT"/usr/bin/distrobox-installer.sh \
  "$OVERRIDES_ROOT"/usr/bin/distrobox-browser.sh \
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

# include useful helpers
install -Z -m 0755 \
  "$OVERRIDES_ROOT"/usr/bin/urh.pyz \
  "$OVERRIDES_ROOT"/usr/bin/nscb.pyz \
  "$OVERRIDES_ROOT"/usr/bin/gamemode.pyz \
  "$OVERRIDES_ROOT"/usr/bin/protonfetcher.pyz \
  /usr/bin/

#
# gamescope-session-steam enablement
#
# include our global-default 'gamescope-session' env vars
install -Z -D -m 0644 \
  "$OVERRIDES_ROOT"/usr/lib/environment.d/99-gamescope-session.conf \
  /usr/lib/environment.d/99-gamescope-session.conf
#
# install an override for 'bluetoothd' for advanced Bluetooth panel enablement
install -Z -D -m 0644 \
  "$OVERRIDES_ROOT"/usr/lib/systemd/system/bluetooth.service.d/override.conf \
  /usr/lib/systemd/system/bluetooth.service.d/override.conf
#
# ensure exiting the gamescope-session doesn't prevent Niri (UWSM) from starting up
#
# catch some leftovers the packaged 'gamescope-session-plus' leaves behind
install -Z -D -m 0755 \
  "$OVERRIDES_ROOT"/usr/bin/gamescope-session-plus \
  /usr/bin/gamescope-session-plus
