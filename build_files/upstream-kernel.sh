#!/usr/bin/env bash

setsebool -P domain_kernel_load_modules on

# Remove base kernel packages to prevent conflicts
dnf5 -y remove --no-autoremove \
  --setopt=protect_running_kernel=0 \
  --setopt=clean_requirements_on_remove=false \
  kernel \
  kernel-core \
  kernel-devel \
  kernel-devel-matched \
  kernel-modules \
  kernel-modules-akmods \
  kernel-modules-core \
  kernel-modules-extra || exit 1

# Install latest fedora kernel from updates-testing repository
dnf5 -y install --enablerepo=updates-testing --setopt=tsflags=noscripts \
  kernel \
  kernel-core \
  kernel-modules \
  kernel-modules-core \
  kernel-modules-extra \
  kernel-devel \
  kernel-devel-matched || exit 1

export KERNEL_VERSION
KERNEL_VERSION="$(rpm -qa --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)"

source ./dracut-kernel-fix.sh
