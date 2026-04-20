# Install Brave browser (stable) via distrobox
[group("apps")]
install-brave-dbx:
    /usr/bin/install-brave.sh --recreate --install

# Install Brave browser (stable) via flatpak
[group("apps")]
install-brave-flatpak:
    /usr/bin/install-brave.sh --flatpak --install

# Uninstall Brave browser (stable) via distrobox
[group("apps")]
uninstall-brave-dbx:
    /usr/bin/install-brave.sh --uninstall --rm

# Uninstall Brave browser (stable) via flatpak
[group("apps")]
uninstall-brave-flatpak:
    /usr/bin/install-brave.sh --flatpak --uninstall
