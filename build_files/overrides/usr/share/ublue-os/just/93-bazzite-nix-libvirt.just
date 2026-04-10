# Install virt-manager/libvirt via distrobox
[group("virtualization")]
install-libvirt ACTION="":
    /usr/bin/install-libvirt.sh --recreate --install

# Uninstall virt-manager/libvirt via distrobox
[group("virtualization")]
uninstall-libvirt ACTION="":
    /usr/bin/install-libvirt.sh --uninstall --rm
