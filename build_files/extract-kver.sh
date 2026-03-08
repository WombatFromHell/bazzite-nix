#!/usr/bin/env bash

# Extract kernel version and write to file for OCI label extraction
# This script should be sourced after KERNEL_VERSION is set

if [ -n "$KERNEL_VERSION" ]; then
	mkdir -p /usr/share/ublue-os
	echo "$KERNEL_VERSION" >/usr/share/ublue-os/kernel-version
	echo "Kernel version written: $KERNEL_VERSION"
else
	echo "::warning::KERNEL_VERSION not set, skipping kernel version file creation"
fi
