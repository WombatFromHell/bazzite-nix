#!/usr/bin/env bash
set -euo pipefail

dnf5 clean all
find /tmp /run /boot /var/log -mindepth 1 -delete 2>/dev/null || true
rm -rf /var/lib/dnf

mkdir -p /var/tmp
chmod 1777 /var/tmp

ostree container commit
