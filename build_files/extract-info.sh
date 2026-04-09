#!/usr/bin/env bash
set -euo pipefail

mkdir -p /usr/share/ublue-os
# Extract kernel version from base image kernel
KERNEL_VERSION="$(rpm -qa --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)"
echo "$KERNEL_VERSION" >/usr/share/ublue-os/kernel-version
echo "Kernel version written: $KERNEL_VERSION"

# Generate package manifest for changelog generation
# Output format: {"packages": {"name": "version-release", ...}}
# Strips Fedora release suffixes like .fc40, .fc41, etc.
filter='{ "packages": [inputs | split(" ") | select(length==2) | { (.[0]): .[1] }] | sort_by(keys) | add }'
rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' |
  sed -e 's/\.fc[0-9][0-9]*$//' |
  jq -Rnc "$filter" \
    >/usr/share/ublue-os/manifest.json
echo "Package manifest written to /usr/share/ublue-os/manifest.json"
