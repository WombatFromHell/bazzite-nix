# Install virt-manager/libvirt via distrobox
[group("virtualization")]
install-libvirt ACTION="":
    /usr/bin/install-libvirt.sh --install

# Uninstall virt-manager/libvirt via distrobox
[group("virtualization")]
uninstall-libvirt ACTION="":
    /usr/bin/install-libvirt.sh --uninstall
