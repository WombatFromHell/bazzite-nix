#!/usr/bin/env bash
# helpers.sh — shared functions for build-reusable action.
# Exposes functions for building, labeling, rechunking, and extracting digests.

set -euo pipefail

# ── build image ─────────────────────────────────────────────────────────────
# Usage: build_image <base_image> <build_script> <canonical_tag> <variant> <containerfile_path>

build_image() {
  local base_image="$1"
  local build_script="$2"
  local canonical_tag="$3"
  local variant="$4"
  local containerfile_path="$5"

  sudo podman build \
    --tag localhost/raw-img \
    --build-arg BASE_IMAGE="${base_image}" \
    --build-arg BUILD_SCRIPT="${build_script}" \
    --build-arg CANONICAL_TAG="${canonical_tag}" \
    --build-arg VARIANT="${variant}" \
    --file "${containerfile_path}" .
}

# ── extract kernel and manifest info ────────────────────────────────────────
# Usage: extract_image_info
# Prints to stdout for $GITHUB_OUTPUT:
#   kernel_version=<version>
#   manifest_packages=<count>
#   manifest=<json>

extract_image_info() {
  local kernel_version
  kernel_version=$(sudo podman run --rm localhost/raw-img \
    cat /usr/share/ublue-os/kernel-version)
  echo "kernel_version=${kernel_version}"

  local manifest
  manifest=$(sudo podman run --rm localhost/raw-img \
    cat /usr/share/ublue-os/manifest.json 2>/dev/null) || {
    echo "::error::/usr/share/ublue-os/manifest.json not found in image"
    exit 1
  }

  # Validate the manifest contains a valid {"packages": {...}} object
  local packages_count
  packages_count=$(echo "$manifest" | jq -r '.packages | if type == "object" then length else empty end' 2>/dev/null) || {
    echo "::error::/usr/share/ublue-os/manifest.json does not contain a valid {\"packages\": {...}} object"
    exit 1
  }
  if [ -z "$packages_count" ] || [ "$packages_count" -eq 0 ]; then
    echo "::error::/usr/share/ublue-os/manifest.json contains no packages (count=${packages_count})"
    exit 1
  fi
  echo "manifest_packages=${packages_count}"
  # Use heredoc syntax for multiline-safe $GITHUB_OUTPUT
  echo "manifest<<MANIFEST_EOF"
  echo "$manifest"
  echo "MANIFEST_EOF"
}

# ── assemble labels file ────────────────────────────────────────────────────
# Usage: assemble_labels <date> <image_desc> <variant> <parent_version> \
#                        <repo_owner> <repo_name> <kernel_version> <manifest> <output_file>
# Writes labels to the specified output file.

assemble_labels() {
  local date="$1"
  local image_desc="$2"
  local variant="$3"
  local parent_version="$4"
  local repo_owner="$5"
  local repo_name="$6"
  local kernel_version="$7"
  local manifest="$8"
  local output_file="$9"

  local labels=(
    "org.opencontainers.image.created=${date}"
    "org.opencontainers.image.description=${image_desc}"
    "org.opencontainers.image.documentation=https://raw.githubusercontent.com/${repo_owner}/${repo_name}/refs/heads/main/README.md"
    "org.opencontainers.image.source=https://github.com/${repo_owner}/${repo_name}/blob/main/Containerfile"
    "org.opencontainers.image.title=${variant}"
    "org.opencontainers.image.url=https://github.com/${repo_owner}/${repo_name}"
    "org.opencontainers.image.vendor=${repo_owner}"
    "org.opencontainers.image.version=${parent_version}"
    "org.opencontainers.image.kernel-version=${kernel_version}"
    "containers.bootc=1"
    "ostree.rechunk.info=${manifest}"
  )
  printf '%s\n' "${labels[@]}" >"${output_file}"
}

# ── rechunk image ───────────────────────────────────────────────────────────
# Usage: rechunk_image <labels_file>
# Rechunks localhost/raw-img with the provided labels file.

rechunk_image() {
  local labels_file="$1"

  local label_args=()
  while IFS= read -r line; do
    [ -n "$line" ] && label_args+=(--label "$line")
  done <"${labels_file}"

  # Initialize OCI layout on host (shared into container via the volume)
  sudo mkdir -p /var/lib/containers/oci
  echo '{"imageLayoutVersion":"1.0.0"}' | sudo tee /var/lib/containers/oci/oci-layout >/dev/null
  echo '{"schemaVersion":2,"manifests":[]}' | sudo tee /var/lib/containers/oci/index.json >/dev/null

  sudo podman run --rm --privileged \
    --volume /var/lib/containers:/var/lib/containers \
    quay.io/centos-bootc/centos-bootc:stream10 \
    rpm-ostree compose build-chunked-oci \
    --bootc --max-layers 128 --format-version 2 \
    --from localhost/raw-img \
    --output oci:/var/lib/containers/oci:latest \
    "${label_args[@]}"

  sudo podman image exists localhost/raw-img &&
    sudo podman rmi localhost/raw-img
}

# ── extract final image ref ─────────────────────────────────────────────────
# Usage: extract_final_ref
# Prints to stdout for $GITHUB_OUTPUT:
#   source_ref=<ref>
#   full_build_digest=<digest>
#   build_digest=<short_digest>

extract_final_ref() {
  local source_ref="oci:/var/lib/containers/oci:latest"
  sudo skopeo inspect --raw "$source_ref" >/dev/null || {
    echo "::error::Expected OCI layout ${source_ref} not found after rechunk"
    exit 1
  }

  local full_digest
  full_digest=$(sudo skopeo inspect --raw "$source_ref" | jq -r '.config.digest // empty')
  # Fall back to manifest digest if config digest unavailable
  if [ -z "$full_digest" ]; then
    full_digest=$(sudo sha256sum /var/lib/containers/oci/index.json | awk '{print "sha256:"$1}')
  fi

  local short_digest="${full_digest#sha256:}"
  echo "source_ref=${source_ref}"
  echo "full_build_digest=${full_digest}"
  echo "build_digest=${short_digest}"
}
