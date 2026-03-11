#!/usr/bin/env bash
set -ouex pipefail

cd /ctx || exit 1

source ./init.sh
source ./tools.sh
source ./extras.sh

# Extract kernel version from base image kernel
export KERNEL_VERSION
KERNEL_VERSION="$(rpm -qa --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)"
source ./extract-kver.sh

source ./cleanup.sh
