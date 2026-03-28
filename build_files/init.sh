#!/usr/bin/env bash

# nix installer enablement
mkdir -p /nix

# disable Wants/After 'systemd-udev-settle' override for sddm.service
SDDM_OVERRIDE="/usr/lib/systemd/system/sddm.service.d"
mkdir -p "${SDDM_OVERRIDE}" &&
  ln -sf /dev/null "${SDDM_OVERRIDE}"/override.conf

# place the public key on our image for local cosign verification
PUBLIC_KEY_FILE="/usr/share/ublue-os/signing/etc/pki/containers/cosign.pub"
curl -L \
  "https://raw.githubusercontent.com/WombatFromHell/bazzite-nix/refs/heads/main/cosign.pub" \
  -o "${PUBLIC_KEY_FILE}"
cp -f "${PUBLIC_KEY_FILE}" /etc/pki/containers/

# add our .json fragment to our existing `policy.json` file
SIGNING_ROOT="/ctx/signing"
FRAGMENT_FILE="$SIGNING_ROOT/usr/etc/containers/repo-fragment.json"
REGISTRY_FILE="$SIGNING_ROOT/etc/containers/registries.d/wombatfromhell.yaml"
GLOBAL_POLICY_FILE="/usr/share/ublue-os/signing/usr/etc/containers/policy.json"
# copy our registry config to the appropriate location
cp -f "${REGISTRY_FILE}" "/usr/share/ublue-os/signing/etc/containers/registries.d/"
cp -f "${REGISTRY_FILE}" "/etc/containers/registries.d/"
if [[ -f "$FRAGMENT_FILE" ]] && [[ -f "$GLOBAL_POLICY_FILE" ]]; then
  jq --slurpfile fragment "$FRAGMENT_FILE" \
    '.transports.docker += $fragment[0]' \
    "$GLOBAL_POLICY_FILE" >"${GLOBAL_POLICY_FILE}.tmp" &&
    mv "${GLOBAL_POLICY_FILE}.tmp" "$GLOBAL_POLICY_FILE"
  cp -f "${GLOBAL_POLICY_FILE}" "/etc/containers/policy.json"
fi

# try to fix our downstream os-release so bootloader entries are more accurate
VARIANT="${VARIANT:-stable}" # pick this up from our VARIANT build-arg
# Use downstream canonical_tag if provided (handles collision suffixes like .1, .2)
if [ -n "${CANONICAL_TAG:-}" ]; then
  OSTREE_VERSION="${CANONICAL_TAG}"
else
  OSTREE_VERSION=$(grep -oP "(?<=OSTREE_VERSION=')[^']+" /usr/lib/os-release)
fi

sed -i "s/^PRETTY_NAME=.*/PRETTY_NAME=\"Bazzite-Nix ${VARIANT}-${OSTREE_VERSION}\"/" \
  /usr/lib/os-release
