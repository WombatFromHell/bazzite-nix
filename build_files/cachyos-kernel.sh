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

# use cachyos kernel for fedora instead of bazzite kernel
dnf5 -y copr enable bieszczaders/kernel-cachyos &&
  dnf5 -y copr disable bieszczaders/kernel-cachyos &&
  dnf5 -y install --setopt=tsflags=noscripts --enable-repo="*kernel-cachyos*" \
    kernel-cachyos-core \
    kernel-cachyos \
    kernel-cachyos-modules \
    kernel-cachyos-devel-matched \
    kernel-cachyos-devel || exit 1

source ./dracut-kernel-fix.sh
