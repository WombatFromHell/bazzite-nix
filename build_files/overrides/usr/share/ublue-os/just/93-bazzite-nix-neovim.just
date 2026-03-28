# Install neovim via AppImage and link to /usr/local/bin
[group("apps")]
install-neovim ACTION="":
    /usr/bin/install-neovim.sh --install nightly

# Uninstall neovim AppImage
[group("apps")]
uninstall-neovim ACTION="":
    /usr/bin/install-neovim.sh --uninstall nightly
