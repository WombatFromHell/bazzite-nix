#!/usr/bin/env bash
# helpers.sh — shared functions for build-reusable action.
# Exposes functions for building, labeling, rechunking, and extracting digests.

set -euo pipefail

# Source shared SBOM helpers
# shellcheck source=../sbom-reusable/helpers.sh
source "${BASH_SOURCE[0]%/*}/../sbom-reusable/helpers.sh"

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
    --security-opt label=disable \
    --file "${containerfile_path}" .
}

# ── extract kernel and manifest info ────────────────────────────────────────
# Usage: extract_image_info [manifest_output_file]
# If manifest_output_file is provided, writes manifest JSON to that file.
# Prints to stdout:
#   CI (GITHUB_OUTPUT set): lowercase key=value for >> "$GITHUB_OUTPUT"
#   Local (no GITHUB_OUTPUT): uppercase KEY=value for eval

extract_image_info() {
  local manifest_output_file="${1:-}"

  local kernel_version
  kernel_version=$(sudo podman run --rm --security-opt label=disable localhost/raw-img \
    cat /usr/share/ublue-os/kernel-version) || {
    echo "::error::Failed to read /usr/share/ublue-os/kernel-version from image"
    exit 1
  }
  if [ -z "$kernel_version" ]; then
    echo "::error::/usr/share/ublue-os/kernel-version is empty in image"
    exit 1
  fi

  local manifest
  manifest=$(sudo podman run --rm --security-opt label=disable localhost/raw-img \
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

  # Output format depends on context: lowercase for CI, uppercase for local eval
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "kernel_version=${kernel_version}"
    echo "manifest_packages=${packages_count}"
  else
    echo "KERNEL_VERSION=${kernel_version}"
    echo "MANIFEST_PACKAGES=${packages_count}"
  fi

  # Write manifest to file if path provided (avoids shell quoting issues)
  if [ -n "$manifest_output_file" ]; then
    printf '%s' "$manifest" >"$manifest_output_file"
  fi
}

# ── assemble labels file ────────────────────────────────────────────────────
# Usage: assemble_labels <date> <image_desc> <variant> <parent_version> \
#                        <repo_owner> <repo_name> <kernel_version> \
#                        <manifest_file_path> <output_file>
# Reads manifest JSON from manifest_file_path and writes labels to output_file.

assemble_labels() {
  local date="$1"
  local image_desc="$2"
  local variant="$3"
  local parent_version="$4"
  local repo_owner="$5"
  local repo_name="$6"
  local kernel_version="$7"
  local manifest_file="$8"
  local output_file="$9"

  # Read manifest from file to avoid shell quoting issues with JSON
  # Compact to single line so it survives label file write/read correctly
  local manifest
  manifest=$(jq -c '.' "$manifest_file") || {
    echo "::error::Failed to parse manifest file: $manifest_file"
    exit 1
  }

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
    --security-opt label=disable \
    --volume /var/lib/containers:/var/lib/containers \
    quay.io/centos-bootc/centos-bootc:stream10 \
    rpm-ostree compose build-chunked-oci \
    --bootc --max-layers 128 --format-version 2 \
    --from localhost/raw-img \
    --output oci:/var/lib/containers/oci:latest \
    "${label_args[@]}"

  # Only remove source image in CI (ephemeral runner). Locally, leave it so
  # the user can re-run or inspect without rebuilding.
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    sudo podman image exists localhost/raw-img &&
      sudo podman rmi --force localhost/raw-img
  fi
}

# ── extract final image ref ─────────────────────────────────────────────────
# Usage: extract_final_ref
# Prints to stdout:
#   CI (GITHUB_OUTPUT set): lowercase key=value for >> "$GITHUB_OUTPUT"
#   Local (no GITHUB_OUTPUT): uppercase KEY=value for eval

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
    full_digest=$(sudo skopeo inspect --raw "$source_ref" | jq -r '.digest // empty')
  fi
  if [ -z "$full_digest" ]; then
    echo "::error::Could not determine image digest from ${source_ref}"
    exit 1
  fi

  local short_digest="${full_digest#sha256:}"

  # Output format depends on context: lowercase for CI, uppercase for local eval
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "source_ref=${source_ref}"
    echo "full_build_digest=${full_digest}"
    echo "build_digest=${short_digest}"
  else
    echo "SOURCE_REF=${source_ref}"
    echo "FULL_BUILD_DIGEST=${full_digest}"
    echo "BUILD_DIGEST=${short_digest}"
  fi
}

# ── generate and embed SBOM ─────────────────────────────────────────────────
# Usage: generate_and_embed_sbom <image_name> <version_tag> <syft_cmd>
# Generates an SBOM from the image filesystem and embeds it at /usr/share/ublue-os/sbom.json

generate_and_embed_sbom() {
  local image="$1"
  local version_tag="$2"
  local syft_cmd="$3"

  echo "::group::Generate and embed SBOM"

  local mount_point
  mount_point=$(sudo podman image mount "${image}") || {
    echo "::error::Failed to mount image ${image}"
    exit 1
  }

  local sbom_dir
  sbom_dir="$(mktemp -d)"
  local sbom_file="${sbom_dir}/sbom.json"

  echo "  Mounted image at: ${mount_point}"

  generate_sbom_to_file \
    "dir:${mount_point}" \
    "${version_tag}" \
    "${syft_cmd}" \
    "${sbom_file}"

  sudo podman image unmount "${image}"

  echo "  Injecting SBOM into image layer with buildah..."

  local container
  container=$(sudo buildah from --security-opt label=disable --name "sbom-working-${RANDOM}" "${image}") || {
    echo "::error::Failed to create buildah container from ${image}"
    rm -rf "${sbom_dir}"
    exit 1
  }

  mount_point=$(sudo buildah mount "${container}") || {
    echo "::error::Failed to mount buildah container"
    sudo buildah rm "${container}"
    rm -rf "${sbom_dir}"
    exit 1
  }

  sudo mkdir -p "${mount_point}/usr/share/ublue-os"
  sudo cp "${sbom_file}" "${mount_point}/usr/share/ublue-os/sbom.json"
  sudo buildah unmount "${container}"
  sudo buildah commit --quiet "${container}" "${image}"
  sudo buildah rm "${container}"

  rm -rf "${sbom_dir}"

  echo "::endgroup::"
  echo "✓ SBOM embedded successfully at /usr/share/ublue-os/sbom.json"
}
