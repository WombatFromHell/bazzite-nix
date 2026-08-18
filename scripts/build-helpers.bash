#!/usr/bin/env bash
# helpers.sh — shared functions for build-reusable action.
# Exposes functions for building, labeling, rechunking, and extracting digests.

set -euo pipefail

# ── sudo credential caching ─────────────────────────────────────────────────
# Prompt once at pipeline start; refresh the timestamp non-interactively
# before long ops so a stale sudo session never interrupts a build.
sudo_cache() { sudo -v; }

sudo_refresh() { sudo -n true 2>/dev/null || true; }

# ── build image ─────────────────────────────────────────────────────────────
# Usage: build_image <base_image> <build_script> <canonical_tag> <variant> <containerfile_path> <raw_tag>
# Tags the result as both `raw-img` (default/latest) and `raw-img:<raw_tag>`.
# raw_tag should be the variant's full primary versioned tag (e.g. "testing-44.20260814"),
# not the bare canonical_tag — canonical_tag is branch-stripped and only correct
# as a label value, not as the registry tag (that's reserved for stable).
build_image() {
  local base_image="$1"
  local build_script="$2"
  local canonical_tag="$3"
  local variant="$4"
  local containerfile_path="$5"
  local raw_tag="${6:-$canonical_tag}"

  sudo_refresh
  sudo buildah build \
    --tag raw-img \
    --tag "raw-img:${raw_tag}" \
    --build-arg BASE_IMAGE="${base_image}" \
    --build-arg BUILD_SCRIPT="${build_script}" \
    --build-arg CANONICAL_TAG="${canonical_tag}" \
    --build-arg VARIANT="${variant}" \
    --file "${containerfile_path}" .
}

# ── extract kernel and manifest info ────────────────────────────────────────
# Usage: extract_image_info [manifest_output_file] [image_ref]
# image_ref defaults to localhost/raw-img; pass the chunked image when raw-img
# no longer exists (relabeling a prior rechunked image).
# If manifest_output_file is provided, writes manifest JSON to that file.
# Prints to stdout:
#   CI (GITHUB_OUTPUT set): lowercase key=value for >> "$GITHUB_OUTPUT"
#   Local (no GITHUB_OUTPUT): uppercase KEY=value for eval

extract_image_info() {
  local manifest_output_file="${1:-}"
  local image_ref="${2:-localhost/raw-img}"

  # Read kernel version and package manifest in a single container run.
  # manifest.json is single-line (jq -c) so the first line is the kernel,
  # the remainder is the manifest.
  local output kernel_version manifest
  output=$(sudo podman run --rm "$image_ref" \
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

# ── tag variants ────────────────────────────────────────────────────────────
# Usage: tag_variants <image_name> <canonical_tag>
# Given a canonical tag "<branch>-<major>.<YYMMDD>.<minor>" (e.g. testing-44.20260814.1),
# tags the image so downstream lookups can resolve by, in preference order:
#   full canonical tag -> branch+major -> branch
# Never touches ":latest" — that stays an explicit, caller-chosen tag.
tag_variants() {
  local image="$1" tag="$2"
  local base="localhost/${image}"
  if [[ "$tag" =~ ^([A-Za-z0-9]+)-([0-9]+)\.[0-9]{8}\.[0-9]+$ ]]; then
    local branch="${BASH_REMATCH[1]}" major="${BASH_REMATCH[2]}"
    sudo podman tag "${base}:${tag}" "${base}:${branch}-${major}" 2>/dev/null || true
    sudo podman tag "${base}:${tag}" "${base}:${branch}" 2>/dev/null || true
  fi
}

# ── relabel image ───────────────────────────────────────────────────────────
# Usage: relabel_image <labels_file> <kernel_version> [image] [anchor_tag]
# Clears inherited labels, then re-applies new labels and annotations via
# buildah, in two separate from/config/commit passes. Operates on raw-img
# (before rechunking); pass chunked-img to relabel an existing rechunked image.
# When anchor_tag is given, re-points it (and :latest) at the relabeled image,
# since buildah commit only updates the bare reference.

relabel_image() {
  local labels_file="$1"
  local kernel_version="$2"
  local image="${3:-raw-img}"
  local anchor_tag="${4:-}"

  echo "Relabeling ${image}: clearing inherited labels..." >&2
  # Clear all inherited labels from base image
  local container
  container=$(sudo buildah from "$image")
  sudo buildah config --label "-" "$container"
  sudo buildah commit --identity-label=false --rm "$container" "$image" >/dev/null

  # Read new labels from file
  local labels=()
  while IFS= read -r line; do
    [ -n "$line" ] && labels+=("$line")
  done <"${labels_file}"

  # Add bootc/ostree labels
  labels+=(
    "ostree.bootc=true"
    "ostree.linux=${kernel_version}"
  )

  echo "Relabeling ${image}: applying ${#labels[@]} labels and annotations..." >&2
  # Apply labels and annotations via buildah
  container=$(sudo buildah from "$image")
  for line in "${labels[@]}"; do
    [ -z "$line" ] && continue
    sudo buildah config --label "$line" --annotation "$line" "$container"
  done
  sudo buildah commit --identity-label=false --rm "$container" "$image" >/dev/null

  # buildah commit updates only the bare reference; re-point the anchor/alias
  # tags so downstream lookups (extract_final_ref, run_vm) see the relabeled image.
  if [[ -n "$anchor_tag" ]]; then
    sudo podman tag "localhost/${image}" "localhost/${image}:${anchor_tag}" 2>/dev/null || true
    sudo podman tag "localhost/${image}" "localhost/${image}:latest" 2>/dev/null || true
  fi
}

# ── rechunk image ───────────────────────────────────────────────────────────
# Usage: rechunk_image <comma_separated_tags>
# Rechunks raw-img into containers-storage. The compose output is written as an
# oci-archive to a host temp dir (mounted into the container) so it survives the
# run, then pulled back into rootful storage as chunked-img; all other tags are
# applied as aliases after (the tag loop mirrors relabel_image's).
rechunk_image() {
  local tags_csv="${1:-latest}"
  local tags=()
  IFS=',' read -ra tags <<<"$tags_csv"
  local rechunk_dir chunked

  rechunk_dir="$(mktemp -d "${TMPDIR:-/tmp}/rechunk-XXXXXX")"
  # shellcheck disable=SC2064  # Intentional: capture local var value at definition time
  trap "sudo rm -rf '${rechunk_dir}'" EXIT

  echo "Running 'rpm-ostree compose build-chunked-oci' -> ${rechunk_dir}..." >&2
  sudo_refresh
  if sudo podman run --rm --pull=never --privileged \
    -i --init --sig-proxy \
    --mount=type=image,src=localhost/raw-img,target=/rpm-ostree \
    --volume "${rechunk_dir}:/run/out:Z" \
    --entrypoint /usr/bin/rpm-ostree \
    localhost/raw-img \
    compose build-chunked-oci \
    --bootc --format-version 2 \
    --max-layers 100 \
    --rootfs /rpm-ostree --output oci-archive:/run/out/chunked.oci 1>&2; then

    chunked=$(sudo podman pull "oci-archive:${rechunk_dir}/chunked.oci")
    if [[ -z "$chunked" ]]; then
      echo "::error::Failed to load rechunked oci-archive from ${rechunk_dir}/chunked.oci" >&2
      exit 1
    fi
    sudo podman tag "${chunked}" localhost/chunked-img

    local t
    for t in "${tags[@]}"; do
      [[ -z "$t" || "$t" == "latest" ]] && continue
      sudo podman tag localhost/chunked-img "localhost/chunked-img:${t}"
    done
  else
    echo "Something went wrong during rechunking!" >&2
    exit 1
  fi
}

# ── extract final image ref ─────────────────────────────────────────────────
# Usage: extract_final_ref <tag> [image_name]
# Prints to stdout:
#   CI (GITHUB_OUTPUT set): lowercase key=value for >> "$GITHUB_OUTPUT"
#   Local (no GITHUB_OUTPUT): uppercase KEY=value for eval

extract_final_ref() {
  local tag="${1:-latest}"
  local image_name="${2:-chunked-img}"
  local source_ref="containers-storage:localhost/${image_name}:${tag}"

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
