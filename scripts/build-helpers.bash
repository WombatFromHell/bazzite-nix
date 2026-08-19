#!/usr/bin/env bash
# helpers.sh — shared functions for build-reusable action.
# Exposes functions for building, labeling, rechunking, and extracting digests.

set -euo pipefail

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

  buildah build \
    --tag raw-img \
    --tag "raw-img:${raw_tag}" \
    --build-arg BASE_IMAGE="${base_image}" \
    --build-arg BUILD_SCRIPT="${build_script}" \
    --build-arg CANONICAL_TAG="${canonical_tag}" \
    --build-arg VARIANT="${variant}" \
    --file "${containerfile_path}" .
}

# ── build raw-img unless it already exists (or force rebuilds) ──────────────
# Usage: build_image_or_skip <base_image> <build_script> <canonical_tag> <variant> [force_rebuild]
build_image_or_skip() {
  local base_image="$1"
  local build_script="$2"
  local canonical_tag="$3"
  local variant="$4"
  local force_rebuild="${5:-0}"

  if [[ "$force_rebuild" == "1" ]]; then
    echo "Force rebuild: removing existing container image..."
    buildah rmi --force raw-img 2>/dev/null || true
    build_image "$base_image" "$build_script" "$canonical_tag" "$variant" "./Containerfile" "$variant"
  elif buildah images --format '{{.Name}}' raw-img >/dev/null 2>&1; then
    echo "Container image raw-img already exists, skipping build"
  else
    build_image "$base_image" "$build_script" "$canonical_tag" "$variant" "./Containerfile" "$variant"
  fi
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
  output=$(podman run --rm "$image_ref" \
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
  container=$(buildah from "$image")
  buildah config --label "-" "$container"
  buildah commit --identity-label=false --rm "$container" "$image" >/dev/null

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
  container=$(buildah from "$image")
  for line in "${labels[@]}"; do
    [ -z "$line" ] && continue
    buildah config --label "$line" --annotation "$line" "$container"
  done
  buildah commit --identity-label=false --rm "$container" "$image" >/dev/null

  # buildah commit updates only the bare reference; re-point the anchor/alias
  # tags so downstream lookups (extract_final_ref, run_vm) see the relabeled image.
  if [[ -n "$anchor_tag" ]]; then
    podman tag "localhost/${image}" "localhost/${image}:${anchor_tag}" 2>/dev/null || true
    podman tag "localhost/${image}" "localhost/${image}:latest" 2>/dev/null || true
  fi
}

# ── rechunk image ───────────────────────────────────────────────────────────
# Usage: rechunk_image <comma_separated_tags> [labels_file]
# Rechunks raw-img into containers-storage via coreos/chunkah (the upstream
# ublue rechunk tool), mirroring the bazzite build step: labels are applied at
# chunk time (--label) so the separate post-rechunk relabel is unnecessary, and
# the config comes from `podman image inspect` so Env/Cmd/containers.bootc carry
# over. The chunked output is an OCI layout written to a host temp dir (mounted
# into the container), pulled back as chunked-img, and all other tags are applied
# as aliases after (the tag loop mirrors relabel_image's).
rechunk_image() {
  local tags_csv="${1:-latest}"
  local labels_file="${2:-}"
  local tags=()
  IFS=',' read -ra tags <<<"$tags_csv"
  local rechunk_dir chunkah_config chunkah_image chunkah_ref chunked
  local label_args=()
  local stale

  rechunk_dir="$(mktemp -d "${TMPDIR:-/tmp}/rechunk-XXXXXX")"
  chunkah_config="$(mktemp "${TMPDIR:-/tmp}/chunkah-config-XXXXXX.json")"
  # shellcheck disable=SC2064  # Intentional: capture local var values at definition time
  trap "rm -rf '${rechunk_dir}' '${chunkah_config}'" EXIT

  chunkah_image="quay.io/coreos/chunkah:latest"
  echo "Pulling ${chunkah_image}..." >&2
  podman pull "${chunkah_image}" >/dev/null
  chunkah_ref="$(podman image inspect --format '{{index .RepoDigests 0}}' "${chunkah_image}")"
  # ponytail: cosign skipped when absent so machines without it can still rechunk
  if command -v cosign >/dev/null 2>&1; then
    echo "Verifying ${chunkah_ref} signature..." >&2
    cosign verify \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      --certificate-identity-regexp '^https://github\.com/coreos/chunkah/' \
      "${chunkah_ref}" >/dev/null
  fi

  # Carries Env, Cmd and containers.bootc over to the chunked image
  # shellcheck disable=SC2024  # Intentional: write as user; root container reads it ro
  podman image inspect localhost/raw-img >"${chunkah_config}"

  if [[ -n "$labels_file" && -f "$labels_file" ]]; then
    while IFS= read -r line; do
      [ -n "$line" ] && label_args+=(--label "$line")
    done <"$labels_file"
  fi
  # Drop stale OSTree/build metadata labels inherited from the base image
  for stale in ostree.commit ostree.final-diffid rpmostree.inputhash \
    quay.expires-after io.buildah.version; do
    label_args+=(--label "${stale}-")
  done

  echo "Running 'chunkah build' -> ${rechunk_dir}/chunked..." >&2
  if podman run --rm --pull=never \
    --mount=type=image,src=localhost/raw-img,target=/chunkah \
    --volume "${chunkah_config}:/chunkah-config.json:ro,Z" \
    --volume "${rechunk_dir}:/run/out:Z" \
    "${chunkah_ref}" \
    build \
    --verbose \
    --compressed \
    --max-layers 128 \
    --prune /sysroot/ \
    --prune /run/ \
    --prune /tmp/ \
    "${label_args[@]}" \
    --config /chunkah-config.json \
    --output oci:/run/out/chunked 1>&2; then

    chunked=$(podman pull "oci:${rechunk_dir}/chunked")
    if [[ -z "$chunked" ]]; then
      echo "::error::Failed to load rechunked OCI layout from ${rechunk_dir}/chunked" >&2
      exit 1
    fi
    podman tag "${chunked}" localhost/chunked-img

    local t
    for t in "${tags[@]}"; do
      [[ -z "$t" || "$t" == "latest" ]] && continue
      podman tag localhost/chunked-img "localhost/chunked-img:${t}"
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
  full_digest=$(skopeo inspect --format '{{.Digest}}' "$source_ref") || {
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
