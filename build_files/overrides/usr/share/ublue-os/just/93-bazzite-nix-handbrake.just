# Install Handbrake with VCN acceleration via distrobox
[group("virtualization")]
install-handbrake ACTION="":
    /usr/bin/install-handbrake.sh --install

# Uninstall Handbrake with VCN acceleration via distrobox
[group("virtualization")]
uninstall-handbrake ACTION="":
    /usr/bin/install-handbrake.sh --uninstall
