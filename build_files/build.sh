#!/bin/bash

set -ouex pipefail

# extras installed:
# qt5-qttools (to fix 'xdg-mime-update')
# ghostty (for a sane modern terminal)
# tmux
dnf5 install --enable-repo=terra -y qt5-qttools ghostty tmux

#### Example for enabling a System Unit File
systemctl enable podman.socket
