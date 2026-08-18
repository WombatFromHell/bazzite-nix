#!/usr/bin/env bash
# just-helpers.sh — Extracted shell functions for Justfile targets.
# All functions are designed to be testable in isolation.
#
# Usage:
#   source scripts/just-helpers.sh
#   clean_artifacts
#   resolve_variant "testing"

set -euo pipefail

# Path to shared build helpers (used by build functions)
# Can be overridden via environment: JUST_HELPERS_BUILD=/path/to/helpers.sh
readonly JUST_HELPERS_BUILD="${JUST_HELPERS_BUILD:-scripts/build-helpers.bash}"

# Path to push/sign helpers (skopeo retry, cosign)
readonly JUST_HELPERS_PUSH="${JUST_HELPERS_PUSH:-scripts/push-helpers.bash}"

# Path to variant-resolution helpers (resolve_variant lives here, not duplicated)
# Can be overridden via environment: CHECK_VARIANTS_HELPERS=/path/to/helpers.sh
readonly CHECK_VARIANTS_HELPERS="${CHECK_VARIANTS_HELPERS:-scripts/check-variants-helpers.bash}"
# shellcheck disable=SC1090
source "$CHECK_VARIANTS_HELPERS"

# ── Clean functions ─────────────────────────────────────────────────────────

# Clean root filesystem build artifacts
clean_artifacts() {
  find "$PWD" -maxdepth 1 -name "*_build*" -exec rm -rf {} \; 2>/dev/null || true
  rm -rf .pytest_cache .ruff_cache
  find "$PWD" -name "__pycache__" -type d -exec rm -rf {} \; 2>/dev/null || true
  rm -f previous.manifest.json changelog.md output.env
  rm -rf output/
}

# Clean OCI layout directory if it exists
clean_oci_layout() {
  local oci_output_dir="${1:?oci_output_dir required}"
  if [[ -d "$oci_output_dir" && -f "$oci_output_dir/index.json" ]]; then
    echo "  Removing OCI layout: $oci_output_dir"
    sudo rm -rf "$oci_output_dir"
  fi
}

# Clean containers-storage images from rechunking
clean_rechunk_images() {
  local img tag
  for img in localhost/chunked-img localhost/rechunk-img; do
    while read -r tag; do
      [[ -z "$tag" ]] && continue
      echo "  Removing rechunked image: $img:$tag"
      sudo podman rmi --force "$img:$tag" 2>/dev/null || true
    done < <(sudo podman images --no-trunc "$img" 2>/dev/null | tail -n +2 | awk '{print $2}')
  done
}

# Clean podman images (light): removes only locally generated images, keeps pulled base images
clean_podman_images_light() {
  # Remove build output images (localhost/bazzite-nix:*)
  local tag
  while read -r tag; do
    [[ -z "$tag" ]] && continue
    echo "  Removing build output: localhost/bazzite-nix:$tag"
    sudo buildah rmi --force "localhost/bazzite-nix:$tag" 2>/dev/null || true
  done < <(sudo buildah images --no-trunc "localhost/bazzite-nix" 2>/dev/null | tail -n +2 | awk '{print $2}')

  # Remove localhost/raw-img (all tags)
  local raw_tag
  while read -r raw_tag; do
    [[ -z "$raw_tag" ]] && continue
    echo "  Removing build output: localhost/raw-img:$raw_tag"
    sudo podman rmi --force "localhost/raw-img:$raw_tag" 2>/dev/null || true
  done < <(sudo podman images --no-trunc localhost/raw-img 2>/dev/null | tail -n +2 | awk '{print $2}')

  # Remove dangling (<none>:<none>) intermediate build layers
  local id
  while read -r id; do
    [[ -z "$id" ]] && continue
    echo "  Removing dangling buildah layer: $id"
    sudo buildah rmi --force "$id" 2>/dev/null || true
  done < <(sudo buildah images --filter "dangling=true" --no-trunc 2>/dev/null | tail -n +2 | awk '{print $3}')
}

# Clean podman images: removes all including pulled base images, dangling layers, build inputs/outputs
clean_podman_images() {
  local bib_image="${1:?bib_image required}"

  # Remove known build input images that accumulate across builds
  local img tag
  for img in "ghcr.io/ublue-os/bazzite" "quay.io/centos-bootc/centos-bootc"; do
    while read -r tag; do
      [[ -z "$tag" ]] && continue
      echo "  Removing build input: $img:$tag"
      sudo podman rmi --force "$img:$tag" 2>/dev/null || true
    done < <(sudo podman images --no-trunc "$img" 2>/dev/null | tail -n +2 | awk '{print $2}')
  done

  # Remove BIB image if present
  sudo podman rmi --force "$bib_image" 2>/dev/null || true

  # Remove build output images (localhost/bazzite-nix:*)
  while read -r tag; do
    [[ -z "$tag" ]] && continue
    echo "  Removing build output: localhost/bazzite-nix:$tag"
    sudo buildah rmi --force "localhost/bazzite-nix:$tag" 2>/dev/null || true
  done < <(sudo buildah images --no-trunc "localhost/bazzite-nix" 2>/dev/null | tail -n +2 | awk '{print $2}')

  # Remove localhost/raw-img (all tags)
  local raw_tag
  while read -r raw_tag; do
    [[ -z "$raw_tag" ]] && continue
    echo "  Removing build output: localhost/raw-img:$raw_tag"
    sudo podman rmi --force "localhost/raw-img:$raw_tag" 2>/dev/null || true
  done < <(sudo podman images --no-trunc localhost/raw-img 2>/dev/null | tail -n +2 | awk '{print $2}')

  # Remove dangling (<none>:<none>) intermediate build layers
  while read -r id; do
    [[ -z "$id" ]] && continue
    echo "  Removing dangling buildah layer: $id"
    sudo buildah rmi --force "$id" 2>/dev/null || true
  done < <(sudo buildah images --filter "dangling=true" --no-trunc 2>/dev/null | tail -n +2 | awk '{print $3}')
}

# Clean dangling buildah images (<none>:<none>) — intermediate build artifacts
# Safety: skip any dangling image that is still referenced as a container's base image
clean_buildah_images() {
  local container_images=()
  local dangling=()
  local id cimg in_use

  mapfile -t container_images < <(sudo buildah ps -a --format '{{.ImageID}}' | awk '{print $1}')
  mapfile -t dangling < <(sudo buildah images -a --no-trunc | awk '$1 == "<none>" && $2 == "<none>" {print $3}')

  for id in "${dangling[@]}"; do
    [[ -z "$id" ]] && continue
    in_use=false
    for cimg in "${container_images[@]}"; do
      if [[ "$cimg" == "$id"* ]]; then
        in_use=true
        echo "  Skipping (container base): $id"
        break
      fi
    done
    if [[ "$in_use" == "false" ]]; then
      echo "  Removing dangling buildah image: $id"
      sudo buildah rmi --force "$id" 2>/dev/null || true
    fi
  done
}

# Remove intermediate build containers (working-container, *-working-container, scratch)
# Skip named containers like distroboxes (e.g. 'libvirtbox')
clean_buildah_containers() {
  local cid cname
  sudo buildah ps --all | tail -n +2 | awk '{print $1}' | while read -r cid; do
    [[ -z "$cid" ]] && continue
    cname=$(sudo buildah inspect "$cid" --format '{{.Container}}' 2>/dev/null || true)
    case "$cname" in
    working-container | *-working-container | scratch)
      echo "  Removing build container: $cname ($cid)"
      sudo buildah rm "$cid" 2>/dev/null || true
      ;;
    *)
      if [[ -n "$cname" && "$cname" != "$cid" ]]; then
        echo "  Skipping named container: $cname ($cid)"
      fi
      ;;
    esac
  done
}

# Clean cached VM disk images
clean_vm_cache() {
  local cache_dir="${1:?cache_dir required}"
  if [[ -d "$cache_dir" ]]; then
    echo "Removing VM cache from $cache_dir..."
    sudo rm -rf "$cache_dir"/
    echo "VM cache cleaned"
  else
    echo "VM cache does not exist: $cache_dir"
  fi
}

# ── Build pipeline functions ────────────────────────────────────────────────

# Build a container image (stages to localhost/raw-img)
# Sources helpers_build for build_image function
run_build() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local base_image_override="${4:-}"
  local helpers_build="$JUST_HELPERS_BUILD"
  local TARGET_IMAGE TAG BASE_IMAGE BUILD_SCRIPT VARIANT_NAME CANONICAL_TAG TAGS
  # shellcheck disable=SC1090
  source "$helpers_build"
  sudo_cache
  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name")"
  [[ -n "$base_image_override" ]] && BASE_IMAGE="$base_image_override"
  build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile" "$VARIANT_NAME"
}

# Force-rebuild a container image, evicting any cached local image first
run_rebuild() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local base_image_override="${4:-}"
  local helpers_build="$JUST_HELPERS_BUILD"
  local TARGET_IMAGE TAG BASE_IMAGE BUILD_SCRIPT VARIANT_NAME CANONICAL_TAG TAGS
  # shellcheck disable=SC1090
  source "$helpers_build"
  sudo_cache
  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name" "1")"
  [[ -n "$base_image_override" ]] && BASE_IMAGE="$base_image_override"
  sudo buildah rmi localhost/raw-img 2>/dev/null || true
  build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile" "$VARIANT_NAME"
}

# Shared build-pipeline core: extract info → assemble labels → relabel →
# [rechunk] → relabel chunked-img → extract final ref. The single implementation
# used by the local pipeline (run_pipeline), standalone rechunk (run_rechunk), and
# CI (build_variant_ci) so local runs exercise the same code as the workflow.
#
# Rechunk is opt-in (rechunk=0 default). Re-enabling it was a one-switch change:
# SECURITY_OPTS (--security-opt label=disable) was the hardlink-blowup root cause
# and is gone; CI now passes rechunk=1.
#
# Usage: build_variant_core <variant> <date> <image_desc> <version_label> \
#                           <repo_owner> <repo_name> [force_rebuild] [rechunk]
# PRECONDITION: localhost/raw-img exists (built by the caller) and build-helpers.bash
# is sourced ($JUST_HELPERS_BUILD). Requires GITHUB_OUTPUT unset so extract_* emit
# uppercase vars for eval.
# Prints eval-able uppercase assignments (KERNEL_VERSION, MANIFEST_PACKAGES,
# SOURCE_REF, FULL_BUILD_DIGEST, BUILD_DIGEST). Call with: eval "$(build_variant_core ...)"
build_variant_core() {
  local variant="${1:?variant required}"
  local date="${2:?date required}"
  local image_desc="${3:?image_desc required}"
  local version_label="${4:?version_label required}"
  local repo_owner="${5:?repo_owner required}"
  local repo_name="${6:?repo_name required}"
  local force_rebuild="${7:-0}"
  local rechunk="${8:-0}"
  local manifest_file="/tmp/bazzite-nix-manifest.json"
  local labels_file="/tmp/bazzite-nix-labels.txt"
  local KERNEL_VERSION MANIFEST_PACKAGES SOURCE_REF FULL_BUILD_DIGEST BUILD_DIGEST
  local anchor_tag image_name_ref

  unset GITHUB_OUTPUT
  eval "$(extract_image_info "$manifest_file")"

  # Anchor on the variant name so different variant pipelines never clobber
  # each other's working images (raw-img:<variant> / chunked-img:<variant>).
  anchor_tag="$variant"
  if [[ "$rechunk" == "1" ]]; then
    image_name_ref="chunked-img"
  else
    image_name_ref="raw-img"
  fi

  # Skip relabel & rechunk only when a prior rechunked image already exists
  # (raw-img always exists after the build phase, so it's always relabeled).
  if [[ "$rechunk" == "1" && "$force_rebuild" != "1" ]] && sudo buildah images --format '{{.Name}}:{{.Tag}}' "localhost/chunked-img:${anchor_tag}" >/dev/null 2>&1; then
    echo "containers-storage image localhost/chunked-img:${anchor_tag} already exists, skipping relabel & rechunk" >&2
  else
    assemble_labels \
      "$date" "$image_desc" "$variant" "$version_label" \
      "$repo_owner" "$repo_name" "$KERNEL_VERSION" \
      "$manifest_file" "$labels_file"
    if [[ "$rechunk" == "1" ]]; then
      rechunk_image "$anchor_tag"
      # rpm-ostree build-chunked-oci does not carry the source image's labels
      # into the chunked output, so the labels are applied to the rechunked
      # image itself (relabel_image re-points the anchor tag after commit).
      relabel_image "$labels_file" "$KERNEL_VERSION" "chunked-img" "$anchor_tag"
    else
      relabel_image "$labels_file" "$KERNEL_VERSION" "raw-img" "$anchor_tag"
    fi
  fi

  eval "$(extract_final_ref "$anchor_tag" "$image_name_ref")"

  echo "KERNEL_VERSION=${KERNEL_VERSION}"
  echo "MANIFEST_PACKAGES=${MANIFEST_PACKAGES}"
  echo "SOURCE_REF=${SOURCE_REF}"
  echo "FULL_BUILD_DIGEST=${FULL_BUILD_DIGEST}"
  echo "BUILD_DIGEST=${BUILD_DIGEST}"
}

# Relabel and rechunk raw-img to containers-storage with bootc chunking
# Prints eval-able uppercase assignments (KERNEL_VERSION, MANIFEST_PACKAGES,
# SOURCE_REF, FULL_BUILD_DIGEST, BUILD_DIGEST); the human summary goes to
# stderr. Call with: eval "$(run_rechunk ...)"
run_rechunk() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local image_desc="${4:-Customized Bazzite image with Nix mount support and other sugar}"
  local repo_organization="${5:?repo_organization required}"
  local force_build="${6:-0}"
  local TAG VARIANT_NAME CANONICAL_TAG TAGS
  local KERNEL_VERSION MANIFEST_PACKAGES SOURCE_REF FULL_BUILD_DIGEST BUILD_DIGEST

  # shellcheck disable=SC1090
  source "$JUST_HELPERS_BUILD"
  sudo_cache

  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name" "$force_build")"

  if ! sudo buildah images --format '{{.Name}}' raw-img >/dev/null 2>&1; then
    echo "ERROR: Base image 'localhost/raw-img' not found. Run build step first." >&2
    return 1
  fi

  # force=1 so this always rechunks (never takes the skip-if-chunked-exists path)
  eval "$(build_variant_core "$VARIANT_NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$image_desc" "$CANONICAL_TAG" "$repo_organization" "$image_name" "1" "1")"

  # Human summary goes to stderr; stdout carries the eval-able assignments so
  # run_pipeline can capture them (mirrors build_variant_core's contract).
  echo ""
  echo "=== Rechunk complete ===" >&2
  echo "  Variant      : $VARIANT_NAME" >&2
  echo "  Version      : $CANONICAL_TAG" >&2
  echo "  Tags         : $TAGS" >&2
  echo "  Kernel       : $KERNEL_VERSION" >&2
  echo "  Manifest pkgs: $MANIFEST_PACKAGES" >&2
  echo "  Source ref   : $SOURCE_REF" >&2
  echo "  Full digest  : $FULL_BUILD_DIGEST" >&2
  echo "  Short digest : $BUILD_DIGEST" >&2

  echo "KERNEL_VERSION=${KERNEL_VERSION}"
  echo "MANIFEST_PACKAGES=${MANIFEST_PACKAGES}"
  echo "SOURCE_REF=${SOURCE_REF}"
  echo "FULL_BUILD_DIGEST=${FULL_BUILD_DIGEST}"
  echo "BUILD_DIGEST=${BUILD_DIGEST}"
}

# Relabel an existing image without rebuilding or rechunking, for iterating on
# the relabel flow. Auto-detects the image to relabel: chunked-img when one
# exists for the variant (rechunk path), else raw-img (non-rechunk path). Pass
# an explicit image name (raw-img | chunked-img) to force the target.
# Usage: run_relabel <variant_or_spec> <variants_config> <image_name> <image_desc> \
#                     <repo_organization> [image_name_ref]
# PRECONDITION: the target image exists and build-helpers.bash is sourced
# ($JUST_HELPERS_BUILD). Requires GITHUB_OUTPUT unset so extract_* emit
# uppercase vars for eval.
# Prints eval-able uppercase assignments (KERNEL_VERSION, MANIFEST_PACKAGES,
# SOURCE_REF, FULL_BUILD_DIGEST, BUILD_DIGEST). Call with: eval "$(run_relabel ...)"
run_relabel() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local image_desc="${4:-Customized Bazzite image with Nix mount support and other sugar}"
  local repo_organization="${5:?repo_organization required}"
  local image_name_ref="${6:-}"
  local TAG VARIANT_NAME CANONICAL_TAG TAGS
  local anchor_tag manifest_file labels_file

  # shellcheck disable=SC1090
  source "$JUST_HELPERS_BUILD"
  sudo_cache

  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name")"

  # Anchor on the variant name so different variant pipelines never clobber
  # each other's working images (raw-img:<variant> / chunked-img:<variant>).
  anchor_tag="$VARIANT_NAME"
  if [[ -z "$image_name_ref" ]]; then
    if sudo buildah images --format '{{.Name}}:{{.Tag}}' "localhost/chunked-img:${VARIANT_NAME}" >/dev/null 2>&1; then
      image_name_ref="chunked-img"
    elif sudo buildah images --format '{{.Name}}:{{.Tag}}' "localhost/raw-img:${VARIANT_NAME}" >/dev/null 2>&1; then
      image_name_ref="raw-img"
    else
      echo "ERROR: neither localhost/chunked-img:${VARIANT_NAME} nor localhost/raw-img:${VARIANT_NAME} exists; run 'just pipeline' first" >&2
      return 1
    fi
  fi

  echo "Relabeling existing localhost/${image_name_ref}:${anchor_tag}" >&2

  manifest_file="/tmp/bazzite-nix-manifest.json"
  labels_file="/tmp/bazzite-nix-labels.txt"
  unset GITHUB_OUTPUT
  eval "$(extract_image_info "$manifest_file" "localhost/${image_name_ref}:${anchor_tag}")"
  assemble_labels \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$image_desc" "$VARIANT_NAME" "$CANONICAL_TAG" \
    "$repo_organization" "$image_name" "$KERNEL_VERSION" \
    "$manifest_file" "$labels_file"
  relabel_image "$labels_file" "$KERNEL_VERSION" "$image_name_ref" "$anchor_tag"
  eval "$(extract_final_ref "$anchor_tag" "$image_name_ref")"

  # Human summary goes to stderr; stdout carries the eval-able assignments so
  # run_pipeline can capture them (mirrors build_variant_core's contract).
  echo ""
  echo "=== Relabel complete ===" >&2
  echo "  Variant      : $VARIANT_NAME" >&2
  echo "  Version      : $CANONICAL_TAG" >&2
  echo "  Tags         : $TAGS" >&2
  echo "  Kernel       : $KERNEL_VERSION" >&2
  echo "  Manifest pkgs: $MANIFEST_PACKAGES" >&2
  echo "  Source ref   : $SOURCE_REF" >&2
  echo "  Full digest  : $FULL_BUILD_DIGEST" >&2
  echo "  Short digest : $BUILD_DIGEST" >&2

  echo "KERNEL_VERSION=${KERNEL_VERSION}"
  echo "MANIFEST_PACKAGES=${MANIFEST_PACKAGES}"
  echo "SOURCE_REF=${SOURCE_REF}"
  echo "FULL_BUILD_DIGEST=${FULL_BUILD_DIGEST}"
  echo "BUILD_DIGEST=${BUILD_DIGEST}"
}

# Run the full build pipeline for a single variant:
#   build → extract image info → assemble labels → relabel → [rechunk] → extract final ref
# Rechunk is disabled by default; pass rechunk=1 to enable.
run_pipeline() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local image_desc="${4:-Customized Bazzite image with Nix mount support and other sugar}"
  local repo_organization="${5:?repo_organization required}"
  local base_image_override="${7:-}"
  local force_rebuild="${8:-0}"
  local rechunk="${9:-0}"
  local helpers_build="$JUST_HELPERS_BUILD"
  local TARGET_IMAGE TAG BASE_IMAGE BUILD_SCRIPT VARIANT_NAME CANONICAL_TAG TAGS
  local KERNEL_VERSION MANIFEST_PACKAGES SOURCE_REF FULL_BUILD_DIGEST BUILD_DIGEST

  # shellcheck disable=SC1090
  source "$helpers_build"
  sudo_cache

  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name" "$force_rebuild")"
  [[ -n "$base_image_override" ]] && BASE_IMAGE="$base_image_override"

  # Preview which alias tags this build will generate (mirrors the workflow's Preview step)
  preview_tags "$variant_or_spec" "$variants_config" "$image_name" "$repo_organization"

  # Phase 1: Build container image (skip if exists and not forcing)
  echo "=== Phase 1: Build ==="
  if [[ "$force_rebuild" == "1" ]]; then
    echo "Force rebuild: removing existing container image..."
    sudo buildah rmi raw-img 2>/dev/null || true
    build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile" "$VARIANT_NAME"
  elif sudo buildah images --format '{{.Name}}' raw-img >/dev/null 2>&1; then
    echo "Container image raw-img already exists, skipping build"
  else
    build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile" "$VARIANT_NAME"
  fi

  # Phases 2-4: extract → assemble labels → relabel raw-img → [rechunk] → final ref (shared core).
  # Rechunk routes through run_rechunk (always rechunks); relabel routes through
  # run_relabel (always relabels) so the pipeline shares the standalone entry
  # points; the skip-if-chunked-exists guard remains for CI.
  echo "=== Phase 2-4: Rechunk, assemble labels, relabel & extract final ref ==="
  local core_output
  if [[ "$rechunk" == "1" ]]; then
    core_output="$(run_rechunk "$variant_or_spec" "$variants_config" "$image_name" "$image_desc" "$repo_organization" "$force_rebuild")" || return $?
  else
    core_output="$(run_relabel "$variant_or_spec" "$variants_config" "$image_name" "$image_desc" "$repo_organization" "raw-img")" || return $?
  fi
  eval "$core_output"

  echo ""
  echo "=== Pipeline complete ==="
  echo "  Variant      : $VARIANT_NAME"
  echo "  Version      : $CANONICAL_TAG"
  echo "  Tags         : $TAGS"
  echo "  Kernel       : $KERNEL_VERSION"
  echo "  Manifest pkgs: $MANIFEST_PACKAGES"
  echo "  Source ref   : $SOURCE_REF"
  echo "  Full digest  : $FULL_BUILD_DIGEST"
  echo "  Short digest : $BUILD_DIGEST"
}

# ── CI parity (mirrors the old build-reusable / push-reusable / release-reusable actions) ──

# Build a single variant from pre-resolved values (the CI matrix), mirroring the
# old build-reusable action. No re-resolution — preserves matrix collision handling.
# Usage: build_variant_ci <variant> <base_image> <build_script> <canonical_tag> \
#                         <date> <image_desc> <parent_version> [repo_owner] [repo_name] [rechunk]
# rechunk=1 would enable rpm-ostree chunking here too (currently reworked, out of scope).
# Writes to $GITHUB_OUTPUT (source_ref, full_build_digest, build_digest, kernel_version,
# manifest_packages) when set.
build_variant_ci() {
  local variant="${1:?variant required}"
  local base_image="${2:?base_image required}"
  local build_script="${3:-build.sh}"
  local canonical_tag="${4:?canonical_tag required}"
  local date="${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  local image_desc="${6:-}"
  local parent_version="${7:-}"
  local repo_owner="${8:-}"
  local repo_name="${9:-}"
  local rechunk="${10:-0}"

  local helpers_build="$JUST_HELPERS_BUILD"
  local KERNEL_VERSION MANIFEST_PACKAGES SOURCE_REF FULL_BUILD_DIGEST BUILD_DIGEST
  local gh_output="${GITHUB_OUTPUT:-}"

  # shellcheck disable=SC1090
  source "$helpers_build"

  build_image "$base_image" "$build_script" "$canonical_tag" "$variant" "./Containerfile" "$variant"

  # build_variant_core unsets GITHUB_OUTPUT so extract_* emit uppercase vars we can eval
  eval "$(build_variant_core "$variant" "$date" "$image_desc" "$parent_version" "$repo_owner" "$repo_name" "0" "$rechunk")"

  if [[ -n "$gh_output" ]]; then
    {
      echo "source_ref=${SOURCE_REF}"
      echo "full_build_digest=${FULL_BUILD_DIGEST}"
      echo "build_digest=${BUILD_DIGEST}"
      echo "kernel_version=${KERNEL_VERSION}"
      echo "manifest_packages=${MANIFEST_PACKAGES}"
    } >>"$gh_output"
  fi
}

# Push, sign, and verify a built image (mirrors old push-reusable action).
# Usage: push_variant <source_ref> <tags_csv> <registry> <repo> <suffix> \
#                     <variant_name> <date> <parent_version> [cosign_pub]
# Env required: GITHUB_ACTOR, GITHUB_TOKEN, SIGNING_SECRET.
# Writes to $GITHUB_OUTPUT (remote_digest, remote_digest_ref, status) when set.
push_variant() {
  local source_ref="${1:?source_ref required}"
  local tags_csv="${2:?tags_csv required}"
  local registry="${3:?registry required}"
  local repo="${4:?repo required}"
  local suffix="${5:-}"
  local variant_name="${6:?variant_name required}"
  local date="${7:-}"
  local parent_version="${8:-}"
  local cosign_pub="${9:-cosign.pub}"

  : "${GITHUB_ACTOR:?GITHUB_ACTOR required}"
  : "${GITHUB_TOKEN:?GITHUB_TOKEN required}"
  if [[ -z "${SIGNING_SECRET:-}" ]]; then
    echo "::error::SIGNING_SECRET required for cosign signing" >&2
    return 1
  fi

  local authfile="/tmp/skopeo-auth/auth.json"
  local base_img="${registry}/${repo}${suffix}"
  local helpers_push="$JUST_HELPERS_PUSH"
  local push_output sign_output remote_digest_ref

  # shellcheck disable=SC1090
  source "$helpers_push"

  export MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
  export RETRY_DELAY="${RETRY_DELAY:-15}"

  mkdir -p /tmp/skopeo-auth
  run_with_retry "skopeo login ghcr.io" \
    --stdin-data "${GITHUB_TOKEN}" \
    skopeo login ghcr.io \
    --username "${GITHUB_ACTOR}" \
    --password-stdin \
    --authfile "$authfile"

  push_output="$(push_image_with_tags "$source_ref" "$tags_csv" "$base_img")"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf '%s\n' "$push_output" >>"$GITHUB_OUTPUT"
  eval "$push_output"

  sign_output="$(sign_and_verify_image "$remote_digest_ref" "$cosign_pub" "$authfile" \
    "$GITHUB_ACTOR" "$GITHUB_TOKEN" "${GITHUB_STEP_SUMMARY:-}" \
    "$variant_name" "$tags_csv" "$date" "$parent_version" "$registry" "$repo" "$suffix")"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf '%s\n' "$sign_output" >>"$GITHUB_OUTPUT"
  eval "$sign_output"
}

# Generate a GitHub release for a variant (mirrors old release-reusable action).
# Usage: release_variant <variant> [handwritten] [variants_config] [allow_disabled] [registry] [repo] [dry_run]
# Auth: ambient gh session (gh auth login) or GH_TOKEN/GITHUB_TOKEN.
# Only publishes a release when the computed version tag isn't already released.
# dry_run=1 previews (WOULD CREATE / SKIP) without publishing anything.
# Requires a git checkout with recent history.
# Writes to $GITHUB_OUTPUT (title, tag) when set.
release_variant() {
  local variant="${1:?variant required}"
  local handwritten="${2:-}"
  local variants_config="${3:-.github/variants.json}"
  local allow_disabled="${4:-false}"
  local registry="${5:-}"
  local repo="${6:-}"
  local dry_run="${7:-0}"

  local owner found disabled target gh_repo
  owner="${GITHUB_REPOSITORY_OWNER:-${repo_organization:-}}"
  registry="${registry:-ghcr.io/${owner}}"
  registry="${registry,,}"
  gh_repo="${GITHUB_REPOSITORY:-}"
  repo="${repo:-${gh_repo#*/}}"
  repo="${repo,,}"

  found=$(jq -r --arg v "$variant" '.variants[] | select(.name == $v) | .name' "$variants_config")
  if [[ -z "$found" ]]; then
    echo "::error::Variant '${variant}' not found in variants.json. Available: $(jq -r '.variants[].name' "$variants_config" | paste -sd ', ' -)" >&2
    return 1
  fi
  if [[ "$allow_disabled" != "true" ]]; then
    disabled=$(jq -r --arg v "$variant" '.variants[] | select(.name == $v) | .disabled // false' "$variants_config")
    if [[ "$disabled" == "true" ]]; then
      echo "::error::Variant '${variant}' is disabled in variants.json" >&2
      return 1
    fi
  fi

  target="${variant##*/}"
  [[ "$target" == "main" ]] && target="stable"

  export IMAGE_PREFIX="${registry}/${repo}"
  [[ -z "${GITHUB_REPOSITORY:-}" ]] && export GITHUB_REPOSITORY="${owner}/${repo}"

  python3 scripts/changelog.py "$target" ./output.env ./changelog.md \
    --workdir . --handwritten "$handwritten" --variants-config "$variants_config"

  # shellcheck disable=SC1091
  source ./output.env

  local gh_args=(-t "$TITLE" --notes-file ./changelog.md)
  if [[ "$target" == "stable" ]]; then
    gh_args+=(--latest)
  else
    gh_args+=(--prerelease)
  fi

  # Only publish a release for a version tag that isn't already documented.
  # changelog.py computes TAG as the newest version tag; gh release view tells
  # us whether that version already has a release (same gate for all variants).
  if gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    echo "::notice::Release for $TAG already exists — skipping" >&2
    return 0
  fi

  if [[ "$dry_run" == "1" ]]; then
    echo "WOULD CREATE release: $TAG"
    echo "  Title   : $TITLE"
    echo "  Latest  : $([[ "$target" == "stable" ]] && echo true || echo false)"
    echo "  Notes   : ./changelog.md"
    echo "  (dry run — nothing published)"
    return 0
  fi

  gh release create "$TAG" --repo "$GITHUB_REPOSITORY" "${gh_args[@]}"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "title=${TITLE}" >>"$GITHUB_OUTPUT"
    echo "tag=${TAG}" >>"$GITHUB_OUTPUT"
  fi
}

# ── VM image building ───────────────────────────────────────────────────────

# Internal: Core BIB build logic (called by build_bib)
# Usage: _build_bib source_image type config out_dir bib_image
_build_bib() {
  local source_image="${1:?source_image required}"
  local type="${2:?type required}"
  local config="${3:?config required}"
  local out_dir="${4:?out_dir required}"
  local bib_image="${5:?bib_image required}"

  local disk_name disk_file BUILDTMP

  case "$type" in
  qcow2) disk_name="disk.qcow2" ;;
  raw) disk_name="disk.raw" ;;
  *) disk_name="disk.$type" ;;
  esac
  disk_file="${out_dir}/${disk_name}"
  BUILDTMP="${out_dir}/.bib-tmp"

  if [[ -f "$disk_file" ]]; then
    echo "Disk image already exists: $disk_file — skipping BIB build"
    echo "Use force_rebuild=1 to force regeneration"
    return 0
  fi

  if [[ -f "${BUILDTMP}/.bib-build-complete" && -d "$BUILDTMP" ]]; then
    local tmp_disk="${BUILDTMP}/${disk_name}"
    if [[ -f "$tmp_disk" ]]; then
      echo "Found disk in .bib-tmp from previous run, moving to final location..."
      sudo mv -f "$tmp_disk" "$disk_file"
      sudo rmdir "$BUILDTMP" 2>/dev/null || true
      sudo chown "$USER:$USER" "$disk_file"
      echo "Disk image recovered: $disk_file"
      return 0
    fi
  fi

  sudo rm -rf "$BUILDTMP"
  mkdir -p "$BUILDTMP"

  # shellcheck disable=SC2086
  if
    sudo podman run --rm -it --privileged \
      --pull=newer \
      --net=host \
      --security-opt label=type:unconfined_t \
      -v "$(pwd)/${config}:/config.toml:ro" \
      -v "$BUILDTMP:/output" \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      "$bib_image" \
      --type $type --use-librepo=True --rootfs=btrfs \
      "$source_image"
  then
    sudo touch "${BUILDTMP}/.bib-build-complete"
  else
    echo "Error: something went wrong with our BIB build!"
    return 1
  fi

  local item
  for item in "$BUILDTMP"/* "$BUILDTMP"/.*; do
    if [[ -d "$item" ]]; then
      sudo mv -f "$item"/* "$out_dir"/
      sudo rmdir "$item"
    else
      sudo mv -f "$item" "$out_dir"/
    fi
  done
  sudo rm -rf "$BUILDTMP"
  sudo chown -R "$USER:$USER" "$out_dir"
}

# Build BIB VM image (unified function for podman and OCI sources)
# Usage: build_bib <source_type> <source> <tag> <type> <config> <output_dir> <bib_image>
#   source_type: "podman" or "oci"
#   source:      image name (podman) or OCI layout ref (oci)
#   tag:         image tag
#   type:        qcow2, raw, etc.
#   config:      config.toml path
#   output_dir:  output directory (defaults to CACHE_DIR)
#   bib_image:   BIB container image
build_bib() {
  local source_type="${1:?source_type required (podman or oci)}"
  local source="${2:?source required}"
  local tag="${3:?tag required}"
  local type="${4:?type required}"
  local config="${5:?config required}"
  local output_dir="${6:-}"
  local bib_image="${7:?bib_image required}"

  local out_dir source_image

  out_dir="${output_dir}"
  if [[ -z "$out_dir" ]]; then
    out_dir="${CACHE_DIR:-$HOME/.cache/bazzite-nix}"
  fi
  mkdir -p "$out_dir"

  local disk_name
  case "$type" in
  qcow2) disk_name="disk.qcow2" ;;
  raw) disk_name="disk.raw" ;;
  *) disk_name="disk.$type" ;;
  esac
  if [[ -f "${out_dir}/${disk_name}" ]]; then
    echo "Disk image already exists: ${out_dir}/${disk_name} — skipping BIB build"
    echo "Use force_rebuild=1 to force regeneration"
    return 0
  fi

  case "$source_type" in
  podman)
    local effective_tag="$tag"
    if ! sudo buildah images --format '{{.Name}}:{{.Tag}}' "${source}:${tag}" >/dev/null 2>&1; then
      # Fallback to :latest (rechunk_image may not have tagged with $TAG)
      if sudo buildah images --format '{{.Name}}:{{.Tag}}' "${source}:latest" >/dev/null 2>&1; then
        echo "Image ${source}:${tag} not found, using ${source}:latest"
        effective_tag="latest"
      else
        echo "Image ${source}:${tag} not found in rootful storage."
        if podman image exists "${source}:${tag}" 2>/dev/null; then
          echo "Found in rootless storage, copying to rootful..."
          podman save "${source}:${tag}" | sudo podman load
        else
          echo "Image not found in rootless storage either. Pulling..."
          sudo podman pull "${source}:${tag}"
        fi
      fi
    fi

    if [[ "$source" == localhost/* ]]; then
      source_image="${source}:${effective_tag}"
    else
      source_image="localhost/${source}:${effective_tag}"
    fi
    ;;
  oci)
    local target_image="localhost/rechunked"
    sudo skopeo copy "$source" containers-storage:"${target_image}:${tag}"
    source_image="${target_image}:${tag}"
    ;;
  *)
    echo "Unknown source_type: $source_type" >&2
    return 1
    ;;
  esac

  _build_bib "$source_image" "$type" "$config" "$out_dir" "$bib_image"

  if [[ "$source_type" == "oci" ]]; then
    sudo buildah rmi --force "$source_image" 2>/dev/null || true
  fi
}

# Build VM image (shared helper for build-qcow2 and build-raw)
# Sources build-reusable helpers.sh for build_image
build_vm_image() {
  local image_spec="${1:?image_spec required}"
  local type="${2:?type required}"
  local output_dir="${3:-}"
  local force_rebuild="${4:-0}"
  # oci_output_dir is deprecated — kept for backward compatibility but no longer drives behavior
  local _oci_output_dir="${5:-/var/lib/containers/oci}"
  local cache_dir="${6:-$HOME/.cache/bazzite-nix}"
  local helpers_build="$JUST_HELPERS_BUILD"
  local bib_image="${7:-quay.io/centos-bootc/bootc-image-builder:latest}"
  local TARGET_IMAGE TAG BASE_IMAGE BUILD_SCRIPT VARIANT_NAME CANONICAL_TAG TAGS
  local _out_dir _disk_name _disk_file

  # shellcheck disable=SC1090
  source "$helpers_build"
  eval "$(resolve_variant "$image_spec" "${VARIANTS_CONFIG:-.github/variants.json}" "${IMAGE_NAME:-bazzite-nix}")"

  # Determine output dir and disk filename early
  _out_dir="${output_dir}"
  [[ -z "$_out_dir" ]] && _out_dir="$cache_dir"
  case "$type" in
  qcow2) _disk_name="disk.qcow2" ;;
  raw) _disk_name="disk.raw" ;;
  *) _disk_name="disk.$type" ;;
  esac
  _disk_file="${_out_dir}/${_disk_name}"

  # Force rebuild: evict existing disk so BIB rebuilds from scratch
  if [[ "$force_rebuild" == "1" && -f "$_disk_file" ]]; then
    echo "Force rebuild: removing existing disk: ${_disk_file}"
    sudo rm -f "$_disk_file"
  fi

  # Check for a rechunked containers-storage image first (avoids full image copy)
  if [[ "$force_rebuild" != "1" ]] && sudo buildah images --format '{{.Name}}:{{.Tag}}' "localhost/chunked-img:${TAG}" >/dev/null 2>&1; then
    echo "Using existing rechunked containers-storage image: localhost/chunked-img:${TAG}"
    build_bib "podman" "localhost/chunked-img" "${TAG}" "$type" "image.toml" "$output_dir" "$bib_image"
    return 0
  fi

  # Build container if needed (build_image stages to raw-img)
  if [[ "$force_rebuild" == "1" ]]; then
    echo "Force rebuilding container image..."
    sudo buildah rmi --force raw-img 2>/dev/null || true
    build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile" "$VARIANT_NAME"
  elif sudo buildah images --format '{{.Name}}' raw-img >/dev/null 2>&1; then
    echo "Container image raw-img already exists, skipping build"
  else
    build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile" "$VARIANT_NAME"
  fi

  # Tag for BIB — bootc-image-builder reads from podman storage
  sudo buildah tag raw-img "${TARGET_IMAGE}:${TAG}" 2>/dev/null || true
  build_bib "podman" "$TARGET_IMAGE" "$TAG" "$type" "image.toml" "$output_dir" "$bib_image"
}

# ── VM execution ────────────────────────────────────────────────────────────

# Run a VM (disk check, BIB build if needed, QEMU launch)
run_vm() {
  local target_image="${1:?target_image required}"
  local tag="${2:?tag required}"
  local type="${3:?type required}"
  local config="${4:?config required}"
  local output_dir="${5:-}"
  # shellcheck disable=SC2034
  local force_pull="${6:-0}"
  local clean="${7:-0}"
  # oci_output_dir is deprecated — kept for backward compatibility but no longer drives behavior
  local _oci_output_dir="${8:-/var/lib/containers/oci}"
  local cache_dir="${9:-$HOME/.cache/bazzite-nix}"
  local bib_image="${10:?bib_image required}"

  local OUTPUT_DIR disk_name image_file is_local QEMU_PID success i

  OUTPUT_DIR="${output_dir}"
  [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$cache_dir"
  mkdir -p "$OUTPUT_DIR"

  case "$type" in
  qcow2) disk_name="disk.qcow2" ;;
  raw) disk_name="disk.raw" ;;
  iso) disk_name="install.iso" ;;
  *) disk_name="disk.$type" ;;
  esac
  image_file="${OUTPUT_DIR}/${disk_name}"

  if [[ "$clean" == "1" ]]; then
    echo "Removing cached disk image..."
    [[ -f "$image_file" ]] && sudo rm -f "$image_file" && echo "Removed: $image_file" || echo "Nothing to clean"
  fi

  if [[ ! -f "$image_file" ]]; then
    is_local=false
    [[ "$target_image" == localhost/* ]] && is_local=true
    # Prefer rechunked containers-storage image if available (avoids podman image copy)
    if sudo buildah images --format '{{.Name}}:{{.Tag}}' "localhost/chunked-img:${tag}" >/dev/null 2>&1; then
      echo "Using existing rechunked containers-storage image: localhost/chunked-img:${tag}"
      sudo podman image exists "$bib_image" 2>/dev/null || sudo podman pull "$bib_image"
      sudo podman image exists "docker.io/qemux/qemu:latest" 2>/dev/null || sudo podman pull "docker.io/qemux/qemu:latest"
      echo "Building disk image..."
      build_bib "podman" "localhost/chunked-img" "$tag" "$type" "$config" "$OUTPUT_DIR" "$bib_image"
    elif [[ "$is_local" == "true" ]]; then
      if ! sudo podman image exists "${target_image}:${tag}" 2>/dev/null; then
        echo "Image ${target_image}:${tag} not found in rootful storage."
        echo "   Build it first with: just build-${type} ${target_image}:${tag}"
        return 1
      fi
      sudo podman image exists "$bib_image" 2>/dev/null || sudo podman pull "$bib_image"
      sudo podman image exists "docker.io/qemux/qemu:latest" 2>/dev/null || sudo podman pull "docker.io/qemux/qemu:latest"
      echo "Building disk image..."
      build_bib "podman" "$target_image" "$tag" "$type" "$config" "$OUTPUT_DIR" "$bib_image"
    else
      echo "Pulling ${target_image}:${tag}..."
      sudo podman pull "${target_image}:${tag}"
      sudo podman image exists "$bib_image" 2>/dev/null || sudo podman pull "$bib_image"
      sudo podman image exists "docker.io/qemux/qemu:latest" 2>/dev/null || sudo podman pull "docker.io/qemux/qemu:latest"
      echo "Building disk image..."
      build_bib "podman" "$target_image" "$tag" "$type" "$config" "$OUTPUT_DIR" "$bib_image"
    fi
  fi

  if [[ ! -f "$image_file" ]]; then
    echo "Disk image not found: $image_file"
    return 1
  fi

  echo "Starting VM... Connect to http://127.0.0.1:8006"
  sudo podman run --rm --privileged \
    --env CPU_CORES=4 --env RAM_SIZE=6G --env DISK_SIZE=30G \
    --env TPM=N --env GPU=N \
    --device=/dev/kvm --device=/dev/net/tun \
    --cap-add NET_ADMIN \
    -p 8006:8006 \
    --volume "$image_file:/storage/boot.img" \
    "docker.io/qemux/qemu:latest" &
  QEMU_PID=$!

  echo "Waiting for VM web interface..."
  success=false
  for i in {1..30}; do
    if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8006 | grep -q "200"; then
      echo -e "\n VM ready! Opening browser..."
      xdg-open "http://127.0.0.1:8006" >/dev/null 2>&1 &
      success=true
      break
    fi
    echo -n "."
    sleep 2
  done

  if [[ "$success" == "false" ]]; then
    echo -e "\n  Timeout: Service didn't start in time. Check logs or open http://127.0.0.1:8006 manually."
  fi

  wait "$QEMU_PID" || echo "  VM exited"
}

# Preview which alias tags (and the step-summary markdown) a build would generate
# Usage: preview_tags <variants_csv> [variants_config] [image_name] [repo_organization]
# In CI (GITHUB_STEP_SUMMARY set), appends the pending-builds markdown table to the step summary.
preview_tags() {
  local variants_csv="${1:?variants_csv required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local repo_organization="${4:?repo_organization required}"
  local specs=()
  IFS=',' read -ra specs <<<"$variants_csv"

  local registry
  registry="ghcr.io/$(echo "$repo_organization" | tr '[:upper:]' '[:lower:]')"

  local spec TAG VARIANT_NAME CANONICAL_TAG TAGS TARGET_IMAGE
  local suffix rows=()
  for spec in "${specs[@]}"; do
    eval "$(resolve_variant "$spec" "$variants_config" "$image_name")"
    suffix="${TARGET_IMAGE#localhost/"${image_name}"}"
    rows+=("| \`${VARIANT_NAME}\` | \`${registry}/${image_name}${suffix}\` | \`${TAGS}\` |")
    if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "== Tags that would be generated for '${VARIANT_NAME}' =="
      echo "Canonical tag: ${CANONICAL_TAG}"
      echo "Alias tags    : ${TAGS}"
      echo ""
    fi
  done

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## 📦 Variants to Build"
      echo ""
      echo "| Variant | Target Image | Tags |"
      echo "|---------|--------------|------|"
      printf '%s\n' "${rows[@]}"
    } >>"$GITHUB_STEP_SUMMARY"
  else
    echo "| Variant | Target Image | Tags |"
    echo "|---------|--------------|------|"
    printf '%s\n' "${rows[@]}"
  fi
}

# ── Variant aggregation ─────────────────────────────────────────────────────

# Check which variants need rebuilding (mirrors check-variants action)
# Writes results to /tmp/variants_results.json
check_variants() {
  local force_build="${1:-0}"
  local repo_organization="${2:?repo_organization required}"
  local image_name="${3:?image_name required}"
  local variants_config="${4:-.github/variants.json}"
  local variants_override="${5:-}"

  local registry date_iso image_desc

  registry="ghcr.io/$(echo "$repo_organization" | tr '[:upper:]' '[:lower:]')"
  image_desc="Customized Bazzite image with Nix mount support and other sugar"
  date_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  REGISTRY="$registry" \
    REPO="$image_name" \
    IMAGE_DESC="$image_desc" \
    DATE="$date_iso" \
    FORCE_BUILD="$force_build" \
    VARIANTS_CONFIG="$variants_config" \
    VARIANTS_OVERRIDE="$variants_override" \
    bash scripts/check-variants.sh

  echo "=== Variant check results ==="
  cat /tmp/variants_results.json | jq '.'
}

# Aggregate check-variants results into CI-style outputs (mirrors the old
# check-variants action's "Aggregate results" step).
# Usage: aggregate_variants <registry> <repo> [step_summary_file]
# Reads /tmp/variants_results.json (written by check_variants).
# Writes variants_to_build / any_builds_needed to $GITHUB_OUTPUT when set.
aggregate_variants() {
  local registry="${1:?registry required}"
  local repo="${2:?repo required}"
  local step_summary_file="${3:-${GITHUB_STEP_SUMMARY:-}}"
  local results_file="/tmp/variants_results.json"

  if [[ ! -f "$results_file" ]]; then
    echo "::error::Variant results file not found - run check-variants first" >&2
    return 1
  fi

  if [[ ! -s "$results_file" ]]; then
    echo "::error::Variant results file is empty - check job may have failed silently" >&2
    echo "::notice::Treating as no builds needed to allow workflow to continue" >&2
    generate_step_summary "[]" "false" "$registry" "$repo" "$step_summary_file"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      echo "variants_to_build=[]" >>"$GITHUB_OUTPUT"
      echo "any_builds_needed=false" >>"$GITHUB_OUTPUT"
    fi
    return 0
  fi

  local results
  results=$(cat "$results_file")
  if ! echo "$results" | jq empty 2>/dev/null; then
    echo "::error::Invalid JSON in results file - check job may have produced corrupt output" >&2
    return 1
  fi

  local variants_to_build count any_builds_needed
  variants_to_build=$(echo "$results" | jq -c '[.[] | select(.needs_build == true) | del(.needs_build)]')
  count=$(echo "$variants_to_build" | jq 'length')
  any_builds_needed="false"
  if [[ "$count" -gt 0 ]]; then
    any_builds_needed="true"
  else
    generate_step_summary "$results" "false" "$registry" "$repo" "$step_summary_file"
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "variants_to_build=${variants_to_build}" >>"$GITHUB_OUTPUT"
    echo "any_builds_needed=${any_builds_needed}" >>"$GITHUB_OUTPUT"
  fi
  echo "any_builds_needed=${any_builds_needed} (${count} variant(s))"
}

# ── Build-result collection & release resolution ────────────────────────────

# Extract successful "Build & Push" variants from a `gh run view --json jobs`
# payload. Usage: collect_successful_builds <jobs_json>
# Prints the compact JSON array of {variant} entries and writes
# successful_variants / any_successful to $GITHUB_OUTPUT when set.
collect_successful_builds() {
  local jobs_json="${1:?jobs_json required}"
  local successful count
  successful=$(echo "$jobs_json" | jq -c '[.jobs[] | select(.name | startswith("Build & Push")) | select(.conclusion == "success") | {variant: (.name | sub("^Build & Push "; ""))}]')
  count=$(echo "$successful" | jq 'length')
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "successful_variants=${successful}" >>"$GITHUB_OUTPUT"
    echo "any_successful=$([ "$count" -gt 0 ] && echo true || echo false)" >>"$GITHUB_OUTPUT"
  fi
  echo "$successful"
  echo "Found $count successful builds" >&2
}

# List variants with successful "Build & Push" jobs across the most recent runs
# of the build workflow (deduplicated).
# Usage: recent_successful_builds [limit] [repo] [workflow]
# Auth: ambient gh session or GH_TOKEN. repo defaults to GITHUB_REPOSITORY,
# else gh infers it from the git remote.
recent_successful_builds() {
  local limit="${1:-5}"
  local repo="${2:-${GITHUB_REPOSITORY:-}}"
  local workflow="${3:-build.yml}"
  local repo_args=()
  [[ -n "$repo" ]] && repo_args=(--repo "$repo")
  local run_id
  gh run list "${repo_args[@]}" --workflow "$workflow" --limit "$limit" \
    --json databaseId --jq '.[].databaseId' |
    while read -r run_id; do
      gh run view "$run_id" "${repo_args[@]}" --json jobs --jq \
        '[.jobs[] | select(.name | startswith("Build & Push")) | select(.conclusion == "success") | (.name | sub("^Build & Push "; ""))][]'
    done | sort -u
}

# Resolve the variants to make releases for.
# Usage: resolve_release_variants <variants_csv> <variants_config>
# Blank csv → all enabled variants in the config. Explicit csv → intersected
# with recent_successful_builds (variants without a recent successful build are
# warned about and dropped). Prints one variant per line.
resolve_release_variants() {
  local variants_csv="${1:-}"
  local variants_config="${2:-.github/variants.json}"
  local requested recent missing
  if [[ -z "$variants_csv" ]]; then
    jq -r '.variants[] | select(.disabled != true) | .name' "$variants_config"
    return 0
  fi
  requested=$(echo "$variants_csv" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | sort -u)
  recent=$(recent_successful_builds | sort -u)
  missing=$(comm -23 <(printf '%s\n' "$requested") <(printf '%s\n' "$recent"))
  if [[ -n "$missing" ]]; then
    echo "::warning::Skipping variant(s) with no recent successful build: $(echo "$missing" | paste -sd ',' -)" >&2
  fi
  comm -12 <(printf '%s\n' "$requested") <(printf '%s\n' "$recent")
}

# Build all variants that need rebuilding (reads /tmp/variants_results.json)
# Sources build-reusable helpers.sh for the full build pipeline
build_all_variants() {
  # oci_output_dir is deprecated — kept for backward compatibility but no longer drives behavior
  local _oci_output_dir="${1:-/var/lib/containers/oci}"
  local repo_organization="${2:?repo_organization required}"
  local image_name="${3:-bazzite-nix}"
  local image_desc="${4:-Customized Bazzite image with Nix mount support and other sugar}"
  local helpers_build="$JUST_HELPERS_BUILD"
  local results_file variants count i variant base_image build_script canonical_tag tags_csv
  local manifest_file labels_file KERNEL_VERSION SOURCE_REF BUILD_DIGEST
  # shellcheck disable=SC1090
  source "$helpers_build"
  sudo_cache

  results_file="/tmp/variants_results.json"
  if [[ ! -f "$results_file" ]]; then
    echo "::error::No variant check results found. Run check-variants first." >&2
    return 1
  fi

  variants=$(jq -c '[.[] | select(.needs_build == true)]' "$results_file")
  count=$(echo "$variants" | jq 'length')
  if [[ "$count" -eq 0 ]]; then
    echo "No variants need building"
    return 0
  fi

  echo "Building $count variant(s)..."
  for ((i = 0; i < count; i++)); do
    variant=$(echo "$variants" | jq -r ".[$i].variant")
    base_image=$(echo "$variants" | jq -r ".[$i].base_image")
    build_script=$(echo "$variants" | jq -r ".[$i].build_script // \"build.sh\"")
    canonical_tag=$(echo "$variants" | jq -r ".[$i].canonical_tag")
    tags_csv=$(echo "$variants" | jq -r ".[$i].tags")

    echo ""
    echo "========================================"
    echo "Building variant: $variant"
    echo "  Base image    : $base_image"
    echo "  Build script  : $build_script"
    echo "  Canonical tag : $canonical_tag"
    echo "  Tags          : $tags_csv"
    echo "========================================"

    manifest_file="/tmp/bazzite-nix-manifest.json"
    labels_file="/tmp/bazzite-nix-labels.txt"

    # Build container image (skip if exists)
    if sudo buildah images --format '{{.Name}}' raw-img >/dev/null 2>&1; then
      echo "Container image raw-img already exists, skipping build"
    else
      build_image "$base_image" "$build_script" "$canonical_tag" "$variant" "./Containerfile" "$variant"
    fi

    eval "$(extract_image_info "$manifest_file")"

    # Relabel & rechunk only if containers-storage doesn't already exist
    if sudo buildah images --format '{{.Name}}:{{.Tag}}' localhost/chunked-img >/dev/null 2>&1; then
      echo "containers-storage image localhost/chunked-img already exists, skipping relabel & rechunk for variant: $variant"
    else
      assemble_labels \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$image_desc" "$variant" "$canonical_tag" \
        "$repo_organization" "$image_name" "$KERNEL_VERSION" \
        "$manifest_file" "$labels_file"
      rechunk_image "$variant"
      relabel_image "$labels_file" "$KERNEL_VERSION" "chunked-img" "$variant"
    fi

    eval "$(extract_final_ref "$variant")"
    echo "Variant $variant complete: $SOURCE_REF ($BUILD_DIGEST)"
  done
}

# ── Privilege escalation ────────────────────────────────────────────────────

# Run a command with sudo, handling different privilege escalation scenarios.
# Falls back gracefully when sudo is unavailable.
# Usage: sudoif cmd arg1 arg2
sudoif() {
  if [[ "${UID}" -eq 0 ]]; then
    "$@"
  elif [[ "$(command -v sudo)" && -n "${SSH_ASKPASS:-}" ]] &&
    [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    /usr/bin/sudo --askpass "$@" || exit 1
  elif [[ "$(command -v sudo)" ]]; then
    /usr/bin/sudo "$@" || exit 1
  else
    exit 1
  fi
}

# ── Justfile target wrappers ────────────────────────────────────────────────
# Each function mirrors a Justfile target, making it callable directly for
# debugging:  bash -c 'source scripts/just-helpers.bash && check_just_files'

# Check all .just files and the Justfile for syntax errors
check_just_files() {
  local justfile="${1:-Justfile}"
  local file
  find . -type f -name "*.just" | while read -r file; do
    echo "Checking syntax: $file"
    just --unstable --fmt --check -f "$file"
  done
  echo "Checking syntax: $justfile"
  just --unstable --fmt --check -f "$justfile"
}

# Fix formatting in all .just files and the Justfile
fix_just_files() {
  local justfile="${1:-Justfile}"
  local file
  find . -type f -name "*.just" | while read -r file; do
    echo "Fixing syntax: $file"
    just --unstable --fmt -f "$file"
  done
  echo "Fixing syntax: $justfile"
  just --unstable --fmt -f "$justfile" || { exit 1; }
}

# Run shellcheck on *.sh and actionlint on workflow YAML files
lint_scripts() {
  /usr/bin/find . \
    \( -iname "*.sh" -o -iname "*.bash" \) -type f \
    -exec shellcheck "{}" +
  /usr/bin/find ./.github/workflows/ -iname "*.yml" -type f -exec actionlint "{}" +
}

# Run shfmt on *.sh and prettier on workflow YAML files
format_scripts() {
  /usr/bin/find . \
    \( -iname "*.sh" -o -iname "*.bash" \) -type f \
    -exec shfmt -w -i 2 "{}" +
  /usr/bin/find . -iname "*.yml" -type f -exec prettier -w "{}" +
  /usr/bin/find . -iname "*.py" -type f -exec ruff format "{}" +
}

# List available (non-disabled) variants from variants.json
list_available_variants() {
  local variants_config="${1:-.github/variants.json}"
  echo "Available variants:"
  jq -r '.variants[] | select((.disabled // false) == false) | "  \(.name)  →  \(.base_image)  [\(.build_script // "build.sh")]"' \
    "$variants_config"
}

# ── VM build/run wrapper functions ──────────────────────────────────────────

# Build a QCOW2 VM disk image for a variant
build_vm_image_qcow2() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local output_dir="${2:-}"
  local force_rebuild="${3:-0}"
  local oci_output_dir="${4:-/var/lib/containers/oci}"
  local cache_dir="${5:-$HOME/.cache/bazzite-nix}"
  local bib_image="${6:-quay.io/centos-bootc/bootc-image-builder:latest}"

  build_vm_image "$variant_or_spec" "qcow2" "$output_dir" "$force_rebuild" \
    "$oci_output_dir" "$cache_dir" "$bib_image"
}

# Build a RAW VM disk image for a variant
build_vm_image_raw() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local output_dir="${2:-}"
  local force_rebuild="${3:-0}"
  local oci_output_dir="${4:-/var/lib/containers/oci}"
  local cache_dir="${5:-$HOME/.cache/bazzite-nix}"
  local bib_image="${6:-quay.io/centos-bootc/bootc-image-builder:latest}"

  build_vm_image "$variant_or_spec" "raw" "$output_dir" "$force_rebuild" \
    "$oci_output_dir" "$cache_dir" "$bib_image"
}

# Run a QCOW2 VM for a variant (resolves variant, then launches QEMU)
run_vm_qcow2() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local output_dir="${4:-}"
  local force_pull="${5:-0}"
  local clean="${6:-0}"
  local oci_output_dir="${7:-/var/lib/containers/oci}"
  local cache_dir="${8:-$HOME/.cache/bazzite-nix}"
  local bib_image="${9:-quay.io/centos-bootc/bootc-image-builder:latest}"
  local TARGET_IMAGE TAG
  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name")"
  run_vm "$TARGET_IMAGE" "${TAG}" "qcow2" "image.toml" "$output_dir" \
    "$force_pull" "$clean" "$oci_output_dir" "$cache_dir" "$bib_image"
}

# Run a RAW VM for a variant (resolves variant, then launches QEMU)
run_vm_raw() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local output_dir="${4:-}"
  local force_pull="${5:-0}"
  local clean="${6:-0}"
  local oci_output_dir="${7:-/var/lib/containers/oci}"
  local cache_dir="${8:-$HOME/.cache/bazzite-nix}"
  local bib_image="${9:-quay.io/centos-bootc/bootc-image-builder:latest}"
  local TARGET_IMAGE TAG
  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name")"
  run_vm "$TARGET_IMAGE" "${TAG}" "raw" "image.toml" "$output_dir" \
    "$force_pull" "$clean" "$oci_output_dir" "$cache_dir" "$bib_image"
}
