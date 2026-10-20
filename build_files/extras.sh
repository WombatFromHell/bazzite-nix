#!/usr/bin/env bash

OVERRIDES_ROOT="/ctx/overrides"

# Chunking: chunkah groups files into layers out of components, and two component
# repos are active at once - the rpm database and the user.component xattr
# (upstream bazzite tags its trees the same way in build_files/finalize). Only
# files we install get tagged: tagging a shared directory such as /usr/bin would
# claim the RPM-owned content next to ours.
# Three buckets, split by what the file is for, not by where it lands:
#   beryl-utils  the /usr/bin helpers, products of the beryl-utils repo (.sh, .py, .pyz)
#   session      the session stack: portal configs, session launchers, uwsm env, user
#                units, niri and qt6ct config, gamescope env, service overrides, and our
#                own gamescope-session-plus shim in /usr/bin
#   extras       the ujust recipes
# One interval per component: chunkah errors out if two files of a component
# disagree, so the interval lives in this map and every install names a component.
declare -A COMPONENT_INTERVAL=(
  ["beryl-utils"]=weekly
  ["session"]=weekly
  ["extras"]=weekly
)

# install_tag <component> <mode> <dest> [src...]
# Install, then mark every installed path with that component.
# A dest ending in / is a directory, one installed file per src basename.
install_tag() {
  local component=$1 mode=$2 dest=$3
  shift 3
  local interval="${COMPONENT_INTERVAL[$component]:-}"
  local installed=() src path
  if [[ -z "$interval" ]]; then
    echo "install_tag: no interval for component $component" >&2
    return 1
  fi
  if [[ "$dest" == */ ]]; then
    for src in "$@"; do
      installed+=("$dest${src##*/}")
    done
  else
    installed+=("$dest")
  fi
  install -Z -D -m "$mode" "$@" "$dest"
  for path in "${installed[@]}"; do
    setfattr -n user.component -v "$component" "$path"
    setfattr -n user.update-interval -v "$interval" "$path"
  done
}

# Retry dnf5, clearing the metadata cache between attempts. Mirror metadata
# checksum mismatches (repomd.xml out of sync) are transient; the cache clean
# forces a fresh fetch that resolves to a synced mirror. Fails hard if the
# package is genuinely unavailable.
# Usage: dnf5_retry <dnf5 args...>
dnf5_retry() {
  local attempts=3 attempt=1
  until dnf5 "$@"; do
    if [[ $attempt -ge $attempts ]]; then
      return 1
    fi
    echo "dnf5 failed (attempt ${attempt}/${attempts}); cleaning metadata and retrying..." >&2
    dnf5 clean all 2>/dev/null || true
    sleep $((attempt * 10))
    attempt=$((attempt + 1))
  done
}

# bring in some useful tools from Terra
# shellcheck disable=SC2140
dnf5 config-manager setopt "*terra*".exclude=""
# Terra's metalink checksums have been unreliable; bypass it and use the origin
# baseurl so dnf trusts the fetched repomd.xml as authoritative. Scoped to the
# `terra` section only (not `terra-source`) via config-manager, which edits
# the correct section directly instead of blindly sed/grep/echo-ing the file.
dnf5 config-manager setopt terra.metalink=
dnf5 config-manager setopt terra.baseurl="https://repos.fyralabs.com/terra\$releasever"
dnf5_retry -y install --refresh --enable-repo=terra \
  rocm-smi uwsm qt5-qttools qt6-qttools \
  tmux gvfs-smb gvfs-fuse openrgb openrgb-udev-rules \
  gamescope-session-steam
# shellcheck disable=SC2140
dnf5 config-manager setopt "*terra*".exclude="nerd-fonts scx-tools scx-scheds python3-protobuf zlib-devel uupd"

# include KDE-Rounded-Corners in case the user wants to use 'karousel'
dnf5 -y copr enable matinlotfali/KDE-Rounded-Corners
dnf5 -y copr disable matinlotfali/KDE-Rounded-Corners
dnf5_retry -y install --refresh --enable-repo="*matinlotfali*" \
  kwin-effect-roundcorners

# bring in hyprland via copr
# dnf5 -y copr enable lionheartp/Hyprland
# dnf5 -y copr disable lionheartp/Hyprland
# dnf5_retry -y install --refresh --enable-repo="*lionheartp*" \
#   hyprland hyprland-guiutils hyprland-qt-support \
#   hyprcursor hypridle hyprlock hyprpaper hyprpicker hyprpolkitagent hyprqt6engine \
#   hyprshot hyprshutdown hyprutils kitty
#
# ensure we install a uwsm session variant for hyprland
# install -Z -D -m 0644 \
#   "$OVERRIDES_ROOT"/usr/share/wayland-sessions/hyprland-uwsm.desktop \
#   /usr/share/wayland-sessions/
#
# install -Z -b -m 0644 \
#   "$OVERRIDES_ROOT"/usr/share/xdg-desktop-portal/niri-portals.conf \
#   /usr/share/xdg-desktop-portal/hyprland-portals.conf
#
# install -Z -D -m 0644 \
#   "$OVERRIDES_ROOT"/usr/share/uwsm/env-niri \
#   /usr/share/uwsm/env-hyprland

# use our pre-built niri-spicy RPM's
dnf5_retry install -y https://github.com/WombatFromHell/niri-spicy-builder/releases/download/v26.04.git%2B1bfaa83-1.fc44/xwayland-satellite-0.8.3.git+b83eab9-1.fc44.x86_64.rpm
dnf5_retry install -y https://github.com/WombatFromHell/niri-spicy-builder/releases/download/v26.04.git%2B1bfaa83-1.fc44/niri-26.04.git+1bfaa83-1.fc44.x86_64.rpm

# include DMS and friends from a verified repo
dnf5 -y copr enable avengemedia/dms-git &&
  dnf5 -y copr disable avengemedia/dms-git &&
  dnf5_retry -y install --refresh --enable-repo="*avengemedia*" \
    quickshell-git dms danksearch dankcalendar-git dgop fuzzel \
    cava matugen cups-pk-helper xdg-desktop-portal-kde \
    xdg-desktop-portal-gnome qt6ct-kde ghostty swayidle

# use our niri-portals.conf override customized for KDE
install_tag session 0644 \
  /usr/share/xdg-desktop-portal/niri-portals.conf \
  "$OVERRIDES_ROOT"/usr/share/xdg-desktop-portal/niri-portals.conf
# include our helpers referenced by niri
install_tag beryl-utils 0755 /usr/bin/ \
  "$OVERRIDES_ROOT"/usr/bin/chromium-flags.sh \
  "$OVERRIDES_ROOT"/usr/bin/spawn-browser.sh \
  "$OVERRIDES_ROOT"/usr/bin/hyprpicker.sh
# ensure we install a uwsm session variant for niri
install_tag session 0644 \
  /usr/share/wayland-sessions/niri-uwsm.desktop \
  "$OVERRIDES_ROOT"/usr/share/wayland-sessions/niri-uwsm.desktop
install_tag session 0644 \
  /usr/share/uwsm/env-niri \
  "$OVERRIDES_ROOT"/usr/share/uwsm/env-niri
# ship some critical Niri (UWSM) support services as user defaults
install_tag session 0644 /usr/lib/systemd/user/ \
  "$OVERRIDES_ROOT"/usr/lib/systemd/user/*.service
systemctl --global enable \
  dms-uwsm.service \
  kwallet-pam-init-uwsm.service \
  polkit-kde-agent-uwsm.service
systemctl --global disable dms.service fumon.service
# use our niri config override as well
install_tag session 0644 \
  /usr/share/factory/etc/niri/config.kdl \
  "$OVERRIDES_ROOT"/usr/share/factory/etc/niri/config.kdl
# use our qt6ct override customized for the default Bazzite KDE theme
install_tag session 0644 \
  /usr/share/factory/etc/xdg/qt6ct/qt6ct.conf \
  "$OVERRIDES_ROOT"/usr/share/factory/etc/xdg/qt6ct/qt6ct.conf

# use a workaround to avoid the "white dialog" problem in xwaylandvideobridge
XWVB_GLOBAL_TGT="/usr/share/applications/org.kde.xwaylandvideobridge.desktop"
XWVB_XDG_TGT="/etc/xdg/autostart/org.kde.xwaylandvideobridge.desktop"
sed -i '/^OnlyShowIn=/d' "$XWVB_GLOBAL_TGT" && echo "OnlyShowIn=KDE;GNOME;" | tee -a "$XWVB_GLOBAL_TGT"
sed -i '/^OnlyShowIn=/d' "$XWVB_XDG_TGT" && echo "OnlyShowIn=KDE;GNOME;" | tee -a "$XWVB_XDG_TGT"

# append our justfile fragment to our existing ujust file
cat "$OVERRIDES_ROOT"/usr/share/ublue-os/justfile.fragment \
  >>/usr/share/ublue-os/justfile
# include some helpers (and .just files for ease of use)
install_tag beryl-utils 0755 /usr/bin/ \
  "$OVERRIDES_ROOT"/usr/bin/distrobox-installer.sh \
  "$OVERRIDES_ROOT"/usr/bin/distrobox-browser.sh \
  "$OVERRIDES_ROOT"/usr/bin/install-brave.sh \
  "$OVERRIDES_ROOT"/usr/bin/install-handbrake.sh \
  "$OVERRIDES_ROOT"/usr/bin/install-libvirt.sh \
  "$OVERRIDES_ROOT"/usr/bin/install-neovim.sh
install_tag extras 0644 /usr/share/ublue-os/just/ \
  "$OVERRIDES_ROOT"/usr/share/ublue-os/just/92-bazzite-verify.just \
  "$OVERRIDES_ROOT"/usr/share/ublue-os/just/93-bazzite-nix-brave.just \
  "$OVERRIDES_ROOT"/usr/share/ublue-os/just/93-bazzite-nix-handbrake.just \
  "$OVERRIDES_ROOT"/usr/share/ublue-os/just/93-bazzite-nix-libvirt.just \
  "$OVERRIDES_ROOT"/usr/share/ublue-os/just/93-bazzite-nix-neovim.just

# include useful helpers
install_tag beryl-utils 0755 /usr/bin/ \
  "$OVERRIDES_ROOT"/usr/bin/urh.pyz \
  "$OVERRIDES_ROOT"/usr/bin/nscb.pyz \
  "$OVERRIDES_ROOT"/usr/bin/niri-hdr.py \
  "$OVERRIDES_ROOT"/usr/bin/gamemode.pyz \
  "$OVERRIDES_ROOT"/usr/bin/protonfetcher.pyz

#
# gamescope-session-steam enablement
#
# include our global-default 'gamescope-session' env vars
install_tag session 0644 \
  /usr/lib/environment.d/99-gamescope-session.conf \
  "$OVERRIDES_ROOT"/usr/lib/environment.d/99-gamescope-session.conf
#
# install an override for 'bluetoothd' for advanced Bluetooth panel enablement
install_tag session 0644 \
  /usr/lib/systemd/system/bluetooth.service.d/override.conf \
  "$OVERRIDES_ROOT"/usr/lib/systemd/system/bluetooth.service.d/override.conf
#
# ensure exiting the gamescope-session doesn't prevent Niri (UWSM) from starting up
#
# catch some leftovers the packaged 'gamescope-session-plus' leaves behind
install_tag session 0755 \
  /usr/bin/gamescope-session-plus \
  "$OVERRIDES_ROOT"/usr/bin/gamescope-session-plus
