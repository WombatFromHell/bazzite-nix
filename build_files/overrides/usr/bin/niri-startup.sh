#!/usr/bin/env bash

# avoid a race when Niri doesn't have sockets up yet
sleep 1

# 1. Import vital display variables to systemd and dbus activation environments
dbus-update-activation-environment --systemd \
  WAYLAND_DISPLAY \
  XDG_CURRENT_DESKTOP \
  DISPLAY \
  QT_QPA_PLATFORMTHEME \
  QT_QPA_PLATFORM \
  QT_WAYLAND_DISABLE_WINDOWDECORATION

# 2. Restart portals (which now have the correct environment variables)
systemctl --user restart xdg-desktop-portal{,-gtk,-gnome} plasma-xdg-desktop-portal-kde 2>/dev/null

# 3. Unlock KWallet. We use a login shell context to grab the PAM wallet key.
if [ -x "/usr/libexec/pam_kwallet_init" ]; then
  bash -lc "/usr/libexec/pam_kwallet_init" &
fi

# 4. Start your Polkit authentication agent in the background
if [ -x "/usr/libexec/kf6/polkit-kde-authentication-agent-1" ]; then
  /usr/libexec/kf6/polkit-kde-authentication-agent-1 &
fi

# do not uncomment the command below unless you're okay with no PAM security for kwallet
# /usr/bin/qdbus org.kde.kwalletd6 /modules/kwalletd6 org.kde.KWallet.open kdewallet 0 login
