#!/usr/bin/env bash
set -ouex pipefail

cd /ctx || exit 1

source ./init.sh
source ./cachyos-kernel.sh
source ./tools.sh
# source ./extras.sh
source ./cleanup.sh
