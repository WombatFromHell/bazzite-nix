#!/usr/bin/env bash

# use cachyos kernel for fedora instead of bazzite kernel
export TMPDIR=/var/tmp
mkdir -p $TMPDIR
setsebool -P domain_kernel_load_modules on

dnf5 -y copr enable bieszczaders/kernel-cachyos &&
  dnf5 -y remove --no-autoremove \
    kernel kernel-core \
    kernel-devel-matched kernel-devel \
    kernel-modules \
    kernel-modules-akmods \
    kernel-modules-core \
    kernel-modules-extra &&
  rm -rf /usr/lib/modules/* &&
  dnf5 -y install --setopt=tsflags=noscripts kernel-cachyos kernel-cachyos-devel-matched

KERNEL_VERSION=$(rpm -qa --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-cachyos-core)
depmod -a "${KERNEL_VERSION}"
# DRACUT_NO_XATTR=1 dracut -vf /usr/lib/modules/"${KERNEL_VERSION}"/initramfs.img "${KERNEL_VERSION}"
