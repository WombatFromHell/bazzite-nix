#!/usr/bin/env bash

# nix installer enablement
mkdir -p /nix

# place the public key on our image for local cosign verification
PUBLIC_KEY_FILE="/usr/share/ublue-os/signing/etc/pki/containers/cosign.pub"
curl -L \
  "https://raw.githubusercontent.com/WombatFromHell/bazzite-nix/refs/heads/main/cosign.pub" \
  -o "${PUBLIC_KEY_FILE}"
cp -f "${PUBLIC_KEY_FILE}" /etc/pki/containers/

# add our .json fragment to our existing `policy.json` file
FRAGMENT_FILE="./ublue-os/signing/usr/etc/containers/repo-fragment.json"
REGISTRY_FILE="./ublue-os/signing/etc/containers/registries.d/wombatfromhell.yaml"
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
