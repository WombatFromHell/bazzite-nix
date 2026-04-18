[group("security")]
verify-image:
    #!/usr/bin/bash
    set -euo pipefail

    echo "Checking image verification status..."

    # Define variables
    DEPLOYMENTS=$(rpm-ostree status --json | jq -r '.deployments')
    # Staged deployment (index 1) takes priority over booted (index 0)
    REF=$(echo "$DEPLOYMENTS" | jq -r '.[1]["container-image-reference"] // .[0]["container-image-reference"] // ""')
    DIGEST=$(echo "$DEPLOYMENTS" | jq -r '.[1]["container-image-reference"] | if . then 1 else 0 end' | xargs -I{} sh -c \
        'echo "$0"' "$(echo "$DEPLOYMENTS" | jq -r 'if .[1]["container-image-reference"] then .[1].checksum else .[0].checksum end')")

    BAD="ostree-unverified-registry:"
    GOOD="ostree-image-signed:docker://"
    COSIGN_KEY="/etc/pki/containers/cosign.pub"

    # Extract the bare docker URL (strip ostree prefix variants)
    _extract_url() {
        local ref="$1"
        # Strip known ostree prefixes
        local stripped="${ref#ostree-image-signed:docker://}"
        stripped="${stripped#ostree-unverified-registry:}"
        echo "$stripped"
    }

    # Verify the current/staged image signature with cosign
    _cosign_verify() {
        local ref="$1"
        local url
        url=$(_extract_url "$ref")

        # Extract tag and base to build the digest ref
        local base="${url%%:*}"   # e.g. ghcr.io/wombatfromhell/bazzite-nix
        local tag="${url##*:}"    # e.g. unstable

        echo ""
        echo "🔍 Verifying cosign signature for current image..."
        echo "   Image: ${url}"

        # Fetch the digest from the registry (the local rpm-ostree digest is the
        # image config digest, not necessarily the manifest digest cosign signed)
        local remote_digest
        remote_digest=$(skopeo inspect --format json "docker://${url}" 2>/dev/null | jq -r '.Digest') || {
            echo "⚠️  Could not fetch remote digest — are you online?"
            return 1
        }

        local digest_ref="${base}@${remote_digest}"
        echo "   Digest ref: ${digest_ref}"
        echo ""

        if cosign verify \
            --key "$COSIGN_KEY" \
            --new-bundle-format=false \
            "${digest_ref}"; then
            echo ""
            echo "✅ Cosign signature verification successful!"
        else
            echo ""
            echo "❌ Cosign signature verification FAILED for ${digest_ref}"
            return 1
        fi
    }

    # Logic: Check for Unverified AND Official
    if [[ "$REF" == *"$BAD"* ]] && [[ "$REF" == *"ghcr.io/ublue-os/"* ]]; then
        echo "⚠️  UNVERIFIED OFFICIAL IMAGE DETECTED"
        echo "Current: $REF"

        CLEAN_REF=${REF#*$BAD}
        TARGET="$GOOD$CLEAN_REF"

        echo ""
        echo "Target:  $TARGET"
        echo ""
        echo "This will rebase your system to the signed image."
        echo "This allows you to receive secure updates."
        echo ""

        read -p "Proceed with rebase? [y/N] " -n 1 -r
        echo ""

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Requesting root permission to rebase..."
            pkexec rpm-ostree rebase "$TARGET"
        else
            echo "Cancelled."
        fi
    else
        echo "✅ System is either verified or a custom user image, verifying deployed image..."
        # Still run cosign verify so the user gets confirmation
        _cosign_verify "$REF" || true
    fi

# Verify attestation of currently deployed ostree image
[group("security")]
verify-attestation *args="-d 0":
    /usr/bin/verify-attestation {{ args }}
