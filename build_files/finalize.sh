#!/usr/bin/env bash
set -euo pipefail

dnf5 clean all
dnf5 config-manager setopt keepcache=0
find /tmp /run /boot /var/log -mindepth 1 -delete 2>/dev/null || true
rm -rf /var/tmp/* /var/cache/* /var/lib/dnf 2>/dev/null || true

mkdir -p /var/tmp
chmod -R 1777 /var/tmp

ostree container commit
