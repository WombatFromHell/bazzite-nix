#!/usr/bin/env bash
# helpers.sh — shared functions for build-reusable action.
# Exposes functions for building, labeling, rechunking, and extracting digests.

set -euo pipefail

# SECURITY_OPTS array — set to --security-opt label=disable when running
# outside CI. CI runners (Ubuntu) don't enforce SELinux, so the flag is
# unnecessary there. Use as: sudo podman run --rm "${SECURITY_OPTS[@]}" ...
if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
  SECURITY_OPTS=(--security-opt label=disable)
else
  SECURITY_OPTS=()
fi

# ── build image ─────────────────────────────────────────────────────────────
# Usage: build_image <base_image> <build_script> <canonical_tag> <variant> <containerfile_path>
# Tags the result as both `raw-img` (default/latest) and `raw-img:<canonical_tag>`.

build_image() {
  local base_image="$1"
  local build_script="$2"
  local canonical_tag="$3"
  local variant="$4"
  local containerfile_path="$5"

  sudo buildah build \
    --tag raw-img \
    --tag "raw-img:${canonical_tag}" \
    --build-arg BASE_IMAGE="${base_image}" \
    --build-arg BUILD_SCRIPT="${build_script}" \
    --build-arg CANONICAL_TAG="${canonical_tag}" \
    --build-arg VARIANT="${variant}" \
    "${SECURITY_OPTS[@]}" \
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

  # Read kernel version and package manifest in a single container run.
  # manifest.json is single-line (jq -c) so the first line is the kernel,
  # the remainder is the manifest.
  local output kernel_version manifest
  output=$(sudo podman run --rm "${SECURITY_OPTS[@]}" localhost/raw-img \
    sh -c 'cat /usr/share/ublue-os/kernel-version; echo; cat /usr/share/ublue-os/manifest.json') || {
    echo "::error::Failed to read image metadata from image"
    exit 1
  }
  kernel_version=${output%%$'\n'*}
  manifest=${output#*$'\n'}
  if [ -z "$kernel_version" ]; then
    echo "::error::/usr/share/ublue-os/kernel-version is empty in image"
    exit 1
  fi

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

# ── relabel image ───────────────────────────────────────────────────────────
# Usage: relabel_image <labels_file> <kernel_version> <tag>
# Clears inherited labels, then applies new labels and annotations via buildah.
# Operates on the rechunked image, not raw-img.

relabel_image() {
  local labels_file="$1"
  local kernel_version="$2"
  local tag="${3:-latest}"
  local image="chunked-img:${tag}"

  local labels=()
  while IFS= read -r line; do
    [ -n "$line" ] && labels+=("--label" "$line" "--annotation" "$line")
  done <"${labels_file}"

  echo "Relabeling ${image}: creating working container..."
  local container
  container=$(sudo buildah from "localhost/${image}")

  echo "Relabeling ${image}: applying ${#labels[@]} labels and annotations..."
  sudo buildah config --label "-" \
    "${labels[@]}" \
    --label "ostree.bootc=true" \
    --label "ostree.linux=${kernel_version}" \
    --annotation "ostree.bootc=true" \
    --annotation "ostree.linux=${kernel_version}" \
    "$container"

  echo "Relabeling ${image}: committing updated image..."
  sudo buildah commit --identity-label=false --rm "$container" "localhost/${image}"

  # Ensure untagged canonical ref exists for downstream digest extraction
  if [[ -n "$tag" && "$tag" != "latest" ]]; then
    sudo podman tag "localhost/${image}" "localhost/chunked-img:latest" 2>/dev/null || true
  fi

  echo "Relabeling ${image}: done"
}

# ── rechunk image ───────────────────────────────────────────────────────────
# Usage: rechunk_image [tag]
# Rechunks raw-img using containers-storage output.
# If tag is provided, also tags the result as localhost/chunked-img:<tag>
# so downstream steps (build_vm_image, run_vm) can find it by variant tag.

rechunk_image() {
  local tag="${1:-latest}"
  local rechunk_image="quay.io/centos-bootc/centos-bootc:stream10"
  local from_image="localhost/raw-img"
  local to_image="localhost/chunked-img:${tag}"

  # Pull the rechunk tool image explicitly
  if ! sudo podman image exists "$rechunk_image"; then
    sudo podman pull "$rechunk_image"
  fi

  # Run bootc-base-imagectl rechunk — transient /run and /tmp state was
  # already cleaned and labels applied in relabel_image
  # Storage driver/options are inherited from shared /var/lib/containers store
  sudo podman run --rm --privileged \
    "${SECURITY_OPTS[@]}" \
    --volume /var/lib/containers:/var/lib/containers \
    "$rechunk_image" \
    /usr/libexec/bootc-base-imagectl rechunk \
    --max-layers 64 \
    "$from_image" \
    "$to_image"

  # Ensure untagged canonical ref exists for downstream variant resolution
  if [[ -n "$tag" && "$tag" != "latest" ]]; then
    sudo podman tag "$to_image" "localhost/chunked-img:latest" 2>/dev/null || true
  fi
}

# ── extract final image ref ─────────────────────────────────────────────────
# Usage: extract_final_ref
# Prints to stdout:
#   CI (GITHUB_OUTPUT set): lowercase key=value for >> "$GITHUB_OUTPUT"
#   Local (no GITHUB_OUTPUT): uppercase KEY=value for eval

extract_final_ref() {
  local source_ref="containers-storage:localhost/chunked-img"

  local full_digest
  full_digest=$(sudo skopeo inspect --format '{{.Digest}}' "$source_ref") || {
    echo "::error::Expected containers-storage image ${source_ref} not found after rechunk"
    exit 1
  }
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
