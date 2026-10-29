#!/usr/bin/env bash
# helpers.sh — shared functions for build-reusable action.
# Exposes functions for building, labeling, rechunking, and extracting digests.

set -euo pipefail

# shellcheck source=scripts/log-helpers.bash
source "$(dirname "${BASH_SOURCE[0]}")/log-helpers.bash"

# Home for one run's OCI layouts and VM images. The Justfile's cache_dir points
# at the same place; this is the only default, and every reader is a plain read.
export CACHE_DIR="${CACHE_DIR:-$HOME/.cache/bazzite-nix}"

# Base dir for one variant's OCI layout: the pipeline writes <dir>/<variant>/chunked, and
# clean/VM readers look in the same place. Override OCI_OUTPUT_DIR to relocate a run.
oci_output_root() { echo "${OCI_OUTPUT_DIR:-${CACHE_DIR}/oci}"; }

# Variant selector for a caller that named none: the Justfile exports DEFAULT_TAG, so a
# bare `just build`/`just rechunk` keeps meaning the same variant. The literal here is
# only the fallback for sourcing helpers outside the Justfile.
default_variant() { echo "${DEFAULT_TAG:-testing}"; }

# No --source-date-epoch anywhere: rpm-ostree derives the deployment timestamp shown by
# `rpm-ostree status -v` from the image manifest creation time, and a pinned epoch of 0
# leaves that timestamp unset, which aborts rpm-ostreed. Upstream bazzite stamps images
# with the wall clock too; finalize.sh still clamps /usr /etc /opt mtimes for chunkah's
# layer plan. The devShell exports SOURCE_DATE_EPOCH (nixpkgs reproducible-builds hook),
# which buildah and rpm-ostree would otherwise pick up and stamp 2000-01-01.
unset SOURCE_DATE_EPOCH

# ── image identity ──────────────────────────────────────────────────────────────────
# The one spelling of a local image reference: localhost/<name>[:tag].
# Usage: image_ref <name> [tag]
image_ref() {
  local name="${1:?name required}" tag="${2:-}"
  echo "localhost/${name}${tag:+:${tag}}"
}

# The digest of a local image, as podman spells it (sha256:...).
# Usage: image_digest <ref>
image_digest() {
  podman image inspect --format '{{.Digest}}' "${1:?ref required}"
}

# The alias every build leaves behind.
# Usage: image_tag <name>
image_tag() {
  image_ref "${1:?name required}" latest
}

# ── sudo credential cache ──────────────────────────────────────────────────
# Prime the sudo credential cache once before the first `sudo podman` in the
# VM path so users aren't prompted for a password per step.
sudo_cache() {
  sudo -v
}

# ── build image ─────────────────────────────────────────────────────────────
# Usage: build_image <base_image> <build_script> <version_tag> <variant> <containerfile_path> <raw_tag>
# Tags the result as both `raw-img` (default/latest) and `raw-img:<raw_tag>`.
# raw_tag should be the variant's full primary versioned tag (e.g. "testing-44.20260814"),
# not the bare canonical_tag — canonical_tag is branch-stripped and only correct
# as a label value, not as the registry tag.
# version_tag carries the branch prefix, which init.sh strips back off for the
# ostree/os-release version.
build_image() {
  local base_image="$1" build_script="$2" version_tag="$3" variant="$4" containerfile_path="$5"
  local raw_tag="${6:-$version_tag}"

  buildah build \
    --tag raw-img \
    --tag "raw-img:${raw_tag}" \
    --build-arg BASE_IMAGE="${base_image}" \
    --build-arg BUILD_SCRIPT="${build_script}" \
    --build-arg CANONICAL_TAG="${version_tag}" \
    --build-arg VARIANT="${variant}" \
    --file "${containerfile_path}" .
}

# ── build raw-img unless it already exists (or force rebuilds) ──────────────
# Usage: build_image_or_skip <base_image> <build_script> <version_tag> <variant> [force_rebuild]
build_image_or_skip() {
  local base_image="$1" build_script="$2" version_tag="$3" variant="$4"
  local force_rebuild="${5:-0}"

  if [[ "$force_rebuild" == "1" ]] || ! buildah images --format '{{.Name}}' raw-img >/dev/null 2>&1; then
    if [[ "$force_rebuild" == "1" ]]; then
      echo "Force rebuild: removing existing container image..."
      buildah rmi --force raw-img 2>/dev/null || true
    fi
    build_image "$base_image" "$build_script" "$version_tag" "$variant" "./Containerfile" "$variant"
  else
    echo "Container image raw-img already exists, skipping build"
  fi
}

# ── extract kernel and manifest info ────────────────────────────────────────
# Usage: extract_image_info [manifest_output_file] [image_ref]
# image_ref defaults to localhost/raw-img; pass the chunked image when raw-img
# no longer exists (relabeling a prior rechunked image).
# If manifest_output_file is provided, writes manifest JSON to that file.
# Prints eval-able assignments (KERNEL_VERSION, MANIFEST_PACKAGES) to stdout.

extract_image_info() {
  local manifest_output_file="${1:-}"
  local image_ref="${2:-$(image_ref raw-img)}"

  # Read kernel version and package manifest in a single container run.
  # manifest.json is single-line (jq -c) so the first line is the kernel,
  # the remainder is the manifest.
  local output kernel_version manifest
  output=$(podman run --rm "$image_ref" \
    sh -c 'cat /usr/share/ublue-os/kernel-version; echo; cat /usr/share/ublue-os/manifest.json') || {
    fail "Failed to read image metadata from image"
    exit 1
  }
  kernel_version=${output%%$'\n'*}
  manifest=${output#*$'\n'}
  if [ -z "$kernel_version" ]; then
    fail "/usr/share/ublue-os/kernel-version is empty in image"
    exit 1
  fi

  # Validate the manifest contains a valid {"packages": {...}} object
  local packages_count
  packages_count=$(echo "$manifest" | jq -r '.packages | if type == "object" then length else empty end' 2>/dev/null) || {
    fail "/usr/share/ublue-os/manifest.json does not contain a valid {\"packages\": {...}} object"
    exit 1
  }
  if [ -z "$packages_count" ] || [ "$packages_count" -eq 0 ]; then
    fail "/usr/share/ublue-os/manifest.json contains no packages (count=${packages_count})"
    exit 1
  fi

  echo "KERNEL_VERSION=${kernel_version}"
  echo "MANIFEST_PACKAGES=${packages_count}"

  # Write manifest to file if path provided (avoids shell quoting issues)
  if [ -n "$manifest_output_file" ]; then
    printf '%s' "$manifest" >"$manifest_output_file"
  fi
}

# ── assemble labels file ────────────────────────────────────────────────────
# Usage: assemble_labels <date> <image_desc> <variant> <version_tag> \
#                        <repo_owner> <repo_name> <kernel_version> \
#                        <manifest_file_path> <output_file> [revision] [parent_version]
# Reads manifest JSON from manifest_file_path and writes labels to output_file.
# revision (optional) is the upstream commit SHA, preserved from the base image.
# version_tag is our own version ({branch}-{canonical}, e.g. "unstable-45.20261020.3"),
# so the embedded version never reads identical to upstream's.
# parent_version (optional) is the upstream tag this image was cut from
# (`unstable-45.20261020.2`, or bare `44.20261012.1` for stable); images built
# without a resolved identity omit it.

assemble_labels() {
  local date="$1" image_desc="$2" variant="$3" version_tag="$4" repo_owner="$5"
  local repo_name="$6" kernel_version="$7" manifest_file="$8" output_file="$9"
  local revision="${10:-}"
  local parent_version="${11:-}"

  # Read manifest from file to avoid shell quoting issues with JSON
  # Compact to single line so it survives label file write/read correctly
  local manifest
  manifest=$(jq -c '.' "$manifest_file") || {
    fail "Failed to parse manifest file: $manifest_file"
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
    "org.opencontainers.image.version=${version_tag}"
    "org.opencontainers.image.revision=${revision}"
    "org.opencontainers.image.kernel-version=${kernel_version}"
    "containers.bootc=1"
    "ostree.rechunk.info=${manifest}"
  )
  if [[ -n "$parent_version" ]]; then
    labels+=("org.opencontainers.image.parent-version=${parent_version}")
  fi
  printf '%s\n' "${labels[@]}" >"${output_file}"
}

# ── relabel image ───────────────────────────────────────────────────────────
# Usage: relabel_image <labels_file> <kernel_version> [image] [anchor_tag]
# Clears inherited labels, then re-applies new labels and annotations via
# buildah in one from/config/commit pass. Operates on raw-img
# (before rechunking); pass chunked-img to relabel an existing rechunked image.
# When anchor_tag is given, re-points it (and :latest) at the relabeled image,
# since buildah commit only updates the bare reference.

relabel_image() {
  local labels_file="$1" kernel_version="$2" image="${3:-raw-img}" anchor_tag="${4:-}"

  local labels=()
  while IFS= read -r line; do
    [ -n "$line" ] && labels+=("$line")
  done <"${labels_file}"

  # Add bootc/ostree labels
  labels+=(
    "ostree.bootc=true"
    "ostree.linux=${kernel_version}"
  )

  echo "Relabeling ${image}: clearing inherited labels, then applying ${#labels[@]} labels and annotations..." >&2
  local container
  container=$(buildah from "$image")
  buildah config --label "-" "$container"
  for line in "${labels[@]}"; do
    buildah config --label "$line" --annotation "$line" "$container"
  done
  buildah commit --identity-label=false --rm "$container" "$image" >/dev/null

  # buildah commit updates only the bare reference; re-point the anchor/alias
  # tags so downstream lookups (extract_final_ref, run_vm) see the relabeled image.
  if [[ -n "$anchor_tag" ]]; then
    podman tag "$(image_ref "$image")" "$(image_ref "$image" "$anchor_tag")" 2>/dev/null || true
    podman tag "$(image_ref "$image")" "$(image_tag "$image")" 2>/dev/null || true
  fi
}

# ── rechunk image ───────────────────────────────────────────────────────────
# Usage: rechunk_image <comma_separated_tags> [labels_file] [variant] [oci_base_dir]
# Rechunks raw-img via coreos/chunkah (the upstream ublue rechunk tool),
# mirroring the bazzite build step: labels are applied at
# chunk time (--label) so the separate post-rechunk relabel is unnecessary, and
# the config comes from `podman image inspect` so Env/Cmd/containers.bootc carry
# over. The chunked output is an OCI layout written to <oci_base_dir>/<variant>/chunked
# (per-variant so concurrent pipelines never clobber each other), pulled back as
# chunked-img, and all other tags are applied as aliases after (the tag loop
# mirrors relabel_image's). VM builds consume the layout directly.
rechunk_image() {
  local tags_csv="${1:-latest}" labels_file="${2:-}" variant="${3:-latest}"
  local oci_base_dir="${4:-$(oci_output_root)}"
  local tags=()
  IFS=',' read -ra tags <<<"$tags_csv"
  local layout_dir chunkah_config chunkah_image chunkah_ref chunked
  local label_args=()
  local stale

  layout_dir="${oci_base_dir}/${variant}/chunked"
  # Wipe any stale layout so an old index.json can't confuse the pull
  rm -rf "$layout_dir"
  mkdir -p "${oci_base_dir}/${variant}"
  chunkah_config="$(mktemp "${TMPDIR:-/tmp}/chunkah-config-XXXXXX.json")"
  # shellcheck disable=SC2064  # Intentional: capture local var values at definition time
  trap "rm -rf '${chunkah_config}'" EXIT

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
  podman image inspect "$(image_ref raw-img)" >"${chunkah_config}"

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

  echo "Running 'chunkah build' -> ${layout_dir}..." >&2
  # Chunkah emits one layer per component (rpmdb-owned packages plus our tagged
  # trees) and packs components together once they exceed this cap, so headroom
  # is what keeps our extras in layers of their own. containers-storage caps at 500.
  if podman run --rm --pull=never \
    --mount=type=image,src="$(image_ref raw-img)",target=/chunkah \
    --volume "${chunkah_config}:/chunkah-config.json:ro,Z" \
    --volume "${oci_base_dir}/${variant}:/run/out:Z" \
    "${chunkah_ref}" \
    build \
    --verbose \
    --compressed \
    --max-layers 256 \
    --prune /sysroot/ \
    --prune /run/ \
    --prune /tmp/ \
    "${label_args[@]}" \
    --config /chunkah-config.json \
    --output oci:/run/out/chunked 1>&2; then

    chunked=$(podman pull "oci:${layout_dir}")
    if [[ -z "$chunked" ]]; then
      fail "Failed to load rechunked OCI layout from ${layout_dir}"
      exit 1
    fi
    podman tag "${chunked}" "$(image_ref chunked-img)"

    local t
    for t in "${tags[@]}"; do
      [[ -z "$t" || "$t" == "latest" ]] && continue
      podman tag "$(image_ref chunked-img)" "$(image_ref chunked-img "$t")"
    done
  else
    echo "Something went wrong during rechunking!" >&2
    exit 1
  fi
}

# ── extract final image ref ─────────────────────────────────────────────────
# Usage: extract_final_ref <tag> [image_name]
# Prints eval-able assignments (SOURCE_REF, FULL_BUILD_DIGEST, BUILD_DIGEST) to stdout.

extract_final_ref() {
  local tag="${1:-latest}"
  local image_name="${2:-chunked-img}"
  local source_ref
  source_ref="containers-storage:$(image_ref "$image_name" "$tag")"

  local full_digest
  full_digest=$(image_digest "$(image_ref "$image_name" "$tag")") || {
    fail "Expected containers-storage image ${source_ref} not found after rechunk"
    exit 1
  }
  if [ -z "$full_digest" ]; then
    fail "Could not determine image digest from ${source_ref}"
    exit 1
  fi

  local short_digest="${full_digest#sha256:}"

  echo "SOURCE_REF=${source_ref}"
  echo "FULL_BUILD_DIGEST=${full_digest}"
  echo "BUILD_DIGEST=${short_digest}"
}
