# Install Handbrake with VCN acceleration via distrobox
[group("virtualization")]
install-handbrake ACTION="":
    /usr/bin/install-handbrake.sh --recreate --install

# Uninstall Handbrake with VCN acceleration via distrobox
[group("virtualization")]
uninstall-handbrake ACTION="":
    /usr/bin/install-handbrake.sh --uninstall --rm
