# Install Brave browser (stable) via distrobox
[group("apps")]
install-brave ACTION="":
    /usr/bin/install-brave.sh --recreate --install stable

# Uninstall Brave browser (stable) via distrobox
[group("virtualization")]
uninstall-brave ACTION="":
    /usr/bin/install-brave.sh --rm --uninstall stable
