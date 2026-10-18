#!/usr/bin/env bash
set -euo pipefail

dnf5 clean all
# Remove stale temporary and cache directories, then recreate /var/tmp.
rm -rf /tmp/* || true
find /var/* -maxdepth 0 -type d \! -name cache -exec rm -fr {} \;
mkdir -p /var/tmp
chmod -R 1777 /var/tmp
# Normalize filesystem timestamps without affecting chunkah's layer plan.
# See: https://github.com/coreos/chunkah/issues/160
find /usr /etc /opt -newermt '1970-01-01T00:00:00Z' -exec touch -h -a -m -d '1970-01-01T00:00:00Z' {} +
