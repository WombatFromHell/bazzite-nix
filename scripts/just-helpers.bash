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
readonly JUST_HELPERS_BUILD="${JUST_HELPERS_BUILD:-.github/actions/build-reusable/helpers.sh}"

# ── Clean functions ─────────────────────────────────────────────────────────

# Clean root filesystem build artifacts
clean_artifacts() {
  # shellcheck disable=SC2035
  find . -maxdepth 1 -name "*_build*" -exec rm -rf {} \;
  rm -f previous.manifest.json changelog.md output.env
  rm -rf output/
  touch _build
}

# Clean OCI layout directory if it exists
clean_oci_layout() {
  local oci_output_dir="${1:?oci_output_dir required}"
  if [[ -d "$oci_output_dir" && -f "$oci_output_dir/index.json" ]]; then
    echo "  Removing OCI layout: $oci_output_dir"
    sudo rm -rf "$oci_output_dir"
  fi
}

# Clean podman images: localhost/raw-img, dangling layers, build inputs/outputs
clean_podman_images() {
  local bib_image="${1:?bib_image required}"

  # Remove known build input images that accumulate across builds
  local img tag
  for img in "ghcr.io/ublue-os/bazzite" "quay.io/centos-bootc/centos-bootc"; do
    while read -r tag; do
      [[ -z "$tag" ]] && continue
      echo "  Removing build input: $img:$tag"
      sudo podman rmi --force "$img:$tag" 2>/dev/null || true
    done < <(sudo podman images "$img" --no-trunc | tail -n +2 | awk '{print $2}')
  done

  # Remove BIB image if present
  sudo podman rmi --force "$bib_image" 2>/dev/null || true

  # Remove build output images (localhost/bazzite-nix:*)
  while read -r tag; do
    [[ -z "$tag" ]] && continue
    echo "  Removing build output: localhost/bazzite-nix:$tag"
    sudo podman rmi --force "localhost/bazzite-nix:$tag" 2>/dev/null || true
  done < <(sudo podman images "localhost/bazzite-nix" --no-trunc | tail -n +2 | awk '{print $2}')

  # Remove localhost/raw-img
  sudo podman rmi --force localhost/raw-img 2>/dev/null || true

  # Remove dangling (<none>:<none>) intermediate build layers
  while read -r id; do
    [[ -z "$id" ]] && continue
    echo "  Removing dangling podman layer: $id"
    sudo podman rmi --force "$id" 2>/dev/null || true
  done < <(sudo podman images --filter "dangling=true" --no-trunc | tail -n +2 | awk '{print $3}')
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

# Remove intermediate build containers (working-container, *-working-container)
# Skip named containers like distroboxes (e.g. 'libvirtbox')
clean_buildah_containers() {
  local cid cname
  sudo buildah ps --all | tail -n +2 | awk '{print $1}' | while read -r cid; do
    [[ -z "$cid" ]] && continue
    cname=$(sudo buildah inspect "$cid" 2>/dev/null | jq -r '.Container // empty' || true)
    if [[ "$cname" == *-working-container* ]] || [[ "$cname" == "working-container" ]]; then
      echo "  Removing build container: $cname ($cid)"
      sudo buildah rm "$cid" 2>/dev/null || true
    elif [[ -n "$cname" && "$cname" != "$cid" ]]; then
      echo "  Skipping named container: $cname ($cid)"
    fi
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

  local TARGET_IMAGE TAG BASE_IMAGE BUILD_SCRIPT VARIANT_NAME CANONICAL_TAG

  # shellcheck disable=SC1090
  source "$helpers_build"
  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name")"
  [[ -n "$base_image_override" ]] && BASE_IMAGE="$base_image_override"
  build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile"
}

# Force-rebuild a container image, evicting any cached local image first
run_rebuild() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local base_image_override="${4:-}"
  local helpers_build="$JUST_HELPERS_BUILD"

  local TARGET_IMAGE TAG BASE_IMAGE BUILD_SCRIPT VARIANT_NAME CANONICAL_TAG

  # shellcheck disable=SC1090
  source "$helpers_build"
  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name")"
  [[ -n "$base_image_override" ]] && BASE_IMAGE="$base_image_override"
  sudo podman rmi localhost/raw-img 2>/dev/null || true
  build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile"
}

# Rechunk localhost/raw-img to OCI layout with bootc chunking
run_rechunk() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local image_desc="${4:-Customized Bazzite image with Nix mount support and other sugar}"
  local repo_organization="${5:?repo_organization required}"
  local helpers_build="$JUST_HELPERS_BUILD"

  local TARGET_IMAGE TAG BASE_IMAGE BUILD_SCRIPT VARIANT_NAME CANONICAL_TAG
  local manifest_file labels_file KERNEL_VERSION SOURCE_REF BUILD_DIGEST

  # shellcheck disable=SC1090
  source "$helpers_build"
  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name")"
  manifest_file="/tmp/bazzite-nix-manifest.json"
  labels_file="/tmp/bazzite-nix-labels.txt"
  eval "$(extract_image_info "$manifest_file")"
  assemble_labels \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$image_desc" "$VARIANT_NAME" "$TAG" \
    "$repo_organization" "$image_name" "$KERNEL_VERSION" \
    "$manifest_file" "$labels_file"
  rechunk_image "$labels_file"
  eval "$(extract_final_ref)"
}

# Run the full build pipeline for a single variant:
#   build → extract image info → assemble labels → rechunk → extract final ref
run_pipeline() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local image_desc="${4:-Customized Bazzite image with Nix mount support and other sugar}"
  local repo_organization="${5:?repo_organization required}"
  local oci_output_dir="${6:-/var/lib/containers/oci}"
  local base_image_override="${7:-}"
  local force_rebuild="${8:-0}"
  local helpers_build="$JUST_HELPERS_BUILD"

  local TARGET_IMAGE TAG BASE_IMAGE BUILD_SCRIPT VARIANT_NAME CANONICAL_TAG
  local manifest_file labels_file oci_layout KERNEL_VERSION MANIFEST_PACKAGES
  local SOURCE_REF FULL_BUILD_DIGEST BUILD_DIGEST

  # shellcheck disable=SC1090
  source "$helpers_build"
  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name")"
  [[ -n "$base_image_override" ]] && BASE_IMAGE="$base_image_override"

  manifest_file="/tmp/bazzite-nix-manifest.json"
  labels_file="/tmp/bazzite-nix-labels.txt"
  oci_layout="$oci_output_dir"

  # Phase 1: Build container image (skip if exists and not forcing)
  echo "=== Phase 1: Build ==="
  if [[ "$force_rebuild" == "1" ]]; then
    echo "Force rebuild: removing existing container image..."
    sudo podman rmi localhost/raw-img 2>/dev/null || true
    build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile"
  elif sudo podman image exists localhost/raw-img 2>/dev/null; then
    echo "Container image localhost/raw-img already exists, skipping build"
  else
    build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile"
  fi

  # Phase 2: Extract image info (always safe to re-run, cheap operation)
  echo "=== Phase 2: Extract image info ==="
  eval "$(extract_image_info "$manifest_file")"

  # Phase 3: Assemble labels & Rechunk (skip if OCI layout already exists)
  echo "=== Phase 3: Assemble labels & Rechunk ==="
  if [[ "$force_rebuild" != "1" && -d "$oci_layout" && -f "$oci_layout/index.json" ]]; then
    echo "OCI layout already exists at $oci_layout, skipping rechunk"
  else
    assemble_labels \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$image_desc" "$VARIANT_NAME" "$CANONICAL_TAG" \
      "$repo_organization" "$image_name" "$KERNEL_VERSION" \
      "$manifest_file" "$labels_file"
    rechunk_image "$labels_file"
  fi

  echo "=== Phase 4: Extract final ref ==="
  eval "$(extract_final_ref)"

  echo ""
  echo "=== Pipeline complete ==="
  echo "  Variant      : $VARIANT_NAME"
  echo "  Version      : $CANONICAL_TAG"
  echo "  Kernel       : $KERNEL_VERSION"
  echo "  Manifest pkgs: $MANIFEST_PACKAGES"
  echo "  Source ref   : $SOURCE_REF"
  echo "  Full digest  : $FULL_BUILD_DIGEST"
  echo "  Short digest : $BUILD_DIGEST"
}

# ── Variant resolution ──────────────────────────────────────────────────────

# Resolve a variant name from variants.json into shell variable assignments
# Usage: eval "$(resolve_variant "testing" ".github/variants.json" "bazzite-nix")"
resolve_variant() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local spec row base_image build_script suffix image_name_resolved tag canonical

  spec="$variant_or_spec"

  # If it looks like an explicit image:tag or image ref, pass it through unchanged
  if [[ "$spec" == *"/"* ]] || [[ "$spec" == *":"* ]]; then
    tag="${spec##*:}"
    build_script=$(jq -r --arg bi "$spec" '
            .variants[] | select(.base_image == $bi and (.disabled // false) == false)
            | (.build_script // "build.sh")
        ' "$variants_config" | head -1)
    [[ -z "$build_script" ]] && build_script="build.sh"
    # Extract real version from upstream image label
    canonical=$(skopeo inspect "docker://${spec}" 2>/dev/null |
      jq -r '.Labels["org.opencontainers.image.version"] // empty' ||
      true)
    [[ -z "$canonical" || "$canonical" == "null" ]] && canonical="$tag"
    echo "TARGET_IMAGE=\"localhost/$image_name\""
    echo "TAG=\"$tag\""
    echo "BASE_IMAGE=\"$spec\""
    echo "BUILD_SCRIPT=\"$build_script\""
    echo "VARIANT_NAME=\"$tag\""
    echo "CANONICAL_TAG=\"$canonical\""
    return 0
  fi

  # Look up variant by name
  row=$(jq -r --arg n "$spec" '
        .variants[]
        | select(.name == $n and (.disabled // false) == false)
    ' "$variants_config")

  if [[ -z "$row" ]]; then
    echo "ERROR: Unknown or disabled variant: $spec" >&2
    echo "Available variants:" >&2
    jq -r '.variants[] | select((.disabled // false) == false) | "  " + .name' "$variants_config" >&2
    return 1
  fi

  base_image=$(echo "$row" | jq -r '.base_image')
  build_script=$(echo "$row" | jq -r '.build_script // "build.sh"')
  suffix=$(echo "$row" | jq -r '.suffix // ""')
  image_name_resolved="$image_name${suffix}"
  tag="${base_image##*:}"

  # Extract real version from upstream image label
  canonical=$(skopeo inspect "docker://${base_image}" 2>/dev/null |
    jq -r '.Labels["org.opencontainers.image.version"] // empty' ||
    true)
  [[ -z "$canonical" || "$canonical" == "null" ]] && canonical="$tag"

  echo "TARGET_IMAGE=\"localhost/$image_name_resolved\""
  echo "TAG=\"${tag}\""
  echo "BASE_IMAGE=\"${base_image}\""
  echo "BUILD_SCRIPT=\"${build_script}\""
  echo "VARIANT_NAME=\"${spec}\""
  echo "CANONICAL_TAG=\"$canonical\""
}

# ── VM image building ───────────────────────────────────────────────────────

# Build BIB VM image from podman storage
build_bib() {
  local target_image="${1:?target_image required}"
  local tag="${2:?tag required}"
  local type="${3:?type required}"
  local config="${4:?config required}"
  local output_dir="${5:-}"
  local bib_image="${6:?bib_image required}"

  local out_dir disk_name disk_file args source_image BUILDTMP

  out_dir="${output_dir}"
  if [[ -z "$out_dir" ]]; then
    out_dir="${CACHE_DIR:-$HOME/.cache/bazzite-nix}"
  fi
  mkdir -p "$out_dir"

  case "$type" in
  qcow2) disk_name="disk.qcow2" ;;
  raw) disk_name="disk.raw" ;;
  *) disk_name="disk.$type" ;;
  esac
  disk_file="${out_dir}/${disk_name}"

  if [[ -f "$disk_file" ]]; then
    echo "Disk image already exists: $disk_file — skipping BIB build"
    echo "Use force_rebuild=1 to force regeneration"
    return 0
  fi

  if ! sudo podman image exists "${target_image}:${tag}" 2>/dev/null; then
    echo "Image ${target_image}:${tag} not found in rootful storage."
    if podman image exists "${target_image}:${tag}" 2>/dev/null; then
      echo "Found in rootless storage, copying to rootful..."
      podman save "${target_image}:${tag}" | sudo podman load
    else
      echo "Image not found in rootless storage either. Pulling..."
      sudo podman pull "${target_image}:${tag}"
    fi
  fi

  args="--type $type --use-librepo=True --rootfs=btrfs"

  if [[ "$target_image" == localhost/* ]]; then
    source_image="${target_image}:${tag}"
  else
    source_image="localhost/${target_image}:${tag}"
  fi

  BUILDTMP="${out_dir}/.bib-tmp"
  rm -rf "$BUILDTMP"
  mkdir -p "$BUILDTMP"

  # shellcheck disable=SC2086
  sudo podman run --rm -it --privileged \
    --pull=newer \
    --net=host \
    --security-opt label=type:unconfined_t \
    -v "$(pwd)/${config}:/config.toml:ro" \
    -v "$BUILDTMP:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "$bib_image" \
    $args \
    "$source_image"

  local item
  for item in "$BUILDTMP"/*; do
    if [[ -d "$item" ]]; then
      sudo mv -f "$item"/* "$out_dir"/
      sudo rmdir "$item"
    else
      sudo mv -f "$item" "$out_dir"/
    fi
  done
  sudo rmdir "$BUILDTMP"
  sudo chown -R "$USER:$USER" "$out_dir"
}

# Build BIB VM image from an OCI layout ref (avoids full image copy)
build_bib_oci() {
  local source_image="${1:?source_image required}"
  local tag="${2:?tag required}"
  local type="${3:?type required}"
  local config="${4:?config required}"
  local output_dir="${5:-}"
  local target_image="${6:-localhost/rechunked}"
  local bib_image="${7:?bib_image required}"

  local out_dir disk_name disk_file args source_image_ref BUILDTMP

  out_dir="${output_dir}"
  if [[ -z "$out_dir" ]]; then
    out_dir="${CACHE_DIR:-$HOME/.cache/bazzite-nix}"
  fi
  mkdir -p "$out_dir"

  case "$type" in
  qcow2) disk_name="disk.qcow2" ;;
  raw) disk_name="disk.raw" ;;
  *) disk_name="disk.$type" ;;
  esac
  disk_file="${out_dir}/${disk_name}"

  if [[ -f "$disk_file" ]]; then
    echo "Disk image already exists: $disk_file — skipping BIB build"
    echo "Use force_rebuild=1 to force regeneration"
    return 0
  fi

  # Import OCI layout into containers-storage so BIB can resolve it
  sudo skopeo copy "$source_image" containers-storage:"${target_image}:${tag}"

  args="--type $type --use-librepo=True --rootfs=btrfs"
  source_image_ref="${target_image}:${tag}"

  BUILDTMP="${out_dir}/.bib-tmp"
  rm -rf "$BUILDTMP"
  mkdir -p "$BUILDTMP"

  # shellcheck disable=SC2086
  sudo podman run --rm -it --privileged \
    --pull=newer \
    --net=host \
    --security-opt label=type:unconfined_t \
    -v "$(pwd)/${config}:/config.toml:ro" \
    -v "$BUILDTMP:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "$bib_image" \
    $args \
    "$source_image_ref"

  # Clean up the imported image (OCI layout stays on disk)
  sudo podman rmi --force "$source_image_ref" 2>/dev/null || true

  local item
  for item in "$BUILDTMP"/*; do
    if [[ -d "$item" ]]; then
      sudo mv -f "$item"/* "$out_dir"/
      sudo rmdir "$item"
    else
      sudo mv -f "$item" "$out_dir"/
    fi
  done
  sudo rmdir "$BUILDTMP"
  sudo chown -R "$USER:$USER" "$out_dir"
}

# Build VM image (shared helper for build-qcow2 and build-raw)
# Sources build-reusable helpers.sh for build_image
build_vm_image() {
  local image_spec="${1:?image_spec required}"
  local type="${2:?type required}"
  local output_dir="${3:-}"
  local force_rebuild="${4:-0}"
  local oci_output_dir="${5:-/var/lib/containers/oci}"
  local cache_dir="${6:-$HOME/.cache/bazzite-nix}"
  local helpers_build="$JUST_HELPERS_BUILD"
  local bib_image="${7:-quay.io/centos-bootc/bootc-image-builder:latest}"

  local TARGET_IMAGE TAG BASE_IMAGE BUILD_SCRIPT VARIANT_NAME CANONICAL_TAG
  local _out_dir _disk_name _disk_file OCI_LAYOUT

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

  OCI_LAYOUT="oci:${oci_output_dir}:latest"

  # Check for a rechunked OCI layout first (avoids full image copy)
  if [[ "$force_rebuild" != "1" && -d "$oci_output_dir" && -f "$oci_output_dir/index.json" ]]; then
    echo "Using existing rechunked OCI layout: ${OCI_LAYOUT}"
    build_bib_oci "$OCI_LAYOUT" "$TAG" "$type" "image.toml" "$output_dir" "$TARGET_IMAGE" "$bib_image"
    return 0
  fi

  # Build container if needed (build_image stages to localhost/raw-img)
  if [[ "$force_rebuild" == "1" ]]; then
    echo "Force rebuilding container image..."
    sudo podman rmi --force localhost/raw-img 2>/dev/null || true
    build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile"
  elif sudo podman image exists localhost/raw-img 2>/dev/null; then
    echo "Container image localhost/raw-img already exists, skipping build"
  else
    build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile"
  fi

  # Tag for BIB — bootc-image-builder reads from podman storage
  sudo podman tag localhost/raw-img "${TARGET_IMAGE}:${TAG}" 2>/dev/null || true

  build_bib "$TARGET_IMAGE" "$TAG" "$type" "image.toml" "$output_dir" "$bib_image"
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
  local oci_output_dir="${8:-/var/lib/containers/oci}"
  local cache_dir="${9:-$HOME/.cache/bazzite-nix}"
  local bib_image="${10:?bib_image required}"

  local OUTPUT_DIR disk_name image_file is_local OCI_LAYOUT QEMU_PID success i

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

    OCI_LAYOUT="oci:${oci_output_dir}:latest"

    # Prefer rechunked OCI layout if available (avoids podman image copy)
    if [[ -d "$oci_output_dir" && -f "$oci_output_dir/index.json" ]]; then
      echo "Using existing rechunked OCI layout: ${OCI_LAYOUT}"
      sudo podman image exists "$bib_image" 2>/dev/null || sudo podman pull "$bib_image"
      sudo podman image exists "docker.io/qemux/qemu:latest" 2>/dev/null || sudo podman pull "docker.io/qemux/qemu:latest"
      echo "Building disk image..."
      build_bib_oci "$OCI_LAYOUT" "$tag" "$type" "$config" "$OUTPUT_DIR" "$target_image" "$bib_image"
    elif [[ "$is_local" == "true" ]]; then
      if ! sudo podman image exists "${target_image}:${tag}" 2>/dev/null; then
        echo "Image ${target_image}:${tag} not found in rootful storage."
        echo "   Build it first with: just build-${type} ${target_image}:${tag}"
        return 1
      fi
      sudo podman image exists "$bib_image" 2>/dev/null || sudo podman pull "$bib_image"
      sudo podman image exists "docker.io/qemux/qemu:latest" 2>/dev/null || sudo podman pull "docker.io/qemux/qemu:latest"
      echo "Building disk image..."
      build_bib "$target_image" "$tag" "$type" "$config" "$OUTPUT_DIR" "$bib_image"
    else
      echo "Pulling ${target_image}:${tag}..."
      sudo podman pull "${target_image}:${tag}"
      sudo podman image exists "$bib_image" 2>/dev/null || sudo podman pull "$bib_image"
      sudo podman image exists "docker.io/qemux/qemu:latest" 2>/dev/null || sudo podman pull "docker.io/qemux/qemu:latest"
      echo "Building disk image..."
      build_bib "$target_image" "$tag" "$type" "$config" "$OUTPUT_DIR" "$bib_image"
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

# ── Variant aggregation ─────────────────────────────────────────────────────

# Check which variants need rebuilding (mirrors check-variants action)
# Writes results to /tmp/variants_results.json
check_variants() {
  local force_build="${1:-0}"
  local repo_organization="${2:?repo_organization required}"
  local image_name="${3:?image_name required}"
  local variants_config="${4:-.github/variants.json}"

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
    bash .github/actions/check-variants/check-variants.sh

  echo "=== Variant check results ==="
  cat /tmp/variants_results.json | jq '.'
}

# Build all variants that need rebuilding (reads /tmp/variants_results.json)
# Sources build-reusable helpers.sh for the full build pipeline
build_all_variants() {
  local oci_output_dir="${1:-/var/lib/containers/oci}"
  local repo_organization="${2:?repo_organization required}"
  local image_name="${3:?image_name required}"
  local image_desc="${4:-Customized Bazzite image with Nix mount support and other sugar}"
  local helpers_build="$JUST_HELPERS_BUILD"

  local results_file variants count i variant base_image build_script canonical_tag
  local manifest_file labels_file KERNEL_VERSION SOURCE_REF BUILD_DIGEST

  # shellcheck disable=SC1090
  source "$helpers_build"

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

    echo ""
    echo "========================================"
    echo "Building variant: $variant"
    echo "  Base image    : $base_image"
    echo "  Build script  : $build_script"
    echo "  Canonical tag : $canonical_tag"
    echo "========================================"

    manifest_file="/tmp/bazzite-nix-manifest.json"
    labels_file="/tmp/bazzite-nix-labels.txt"

    # Build container image (skip if exists)
    if sudo podman image exists localhost/raw-img 2>/dev/null; then
      echo "Container image localhost/raw-img already exists, skipping build"
    else
      build_image "$base_image" "$build_script" "$canonical_tag" "$variant" "./Containerfile"
    fi

    eval "$(extract_image_info "$manifest_file")"

    # Rechunk only if OCI layout doesn't already exist
    if [[ -d "$oci_output_dir" && -f "$oci_output_dir/index.json" ]]; then
      echo "OCI layout already exists at $oci_output_dir, skipping rechunk for variant: $variant"
    else
      assemble_labels \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$image_desc" "$variant" "$canonical_tag" \
        "$repo_organization" "$image_name" "$KERNEL_VERSION" \
        "$manifest_file" "$labels_file"
      rechunk_image "$labels_file"
    fi
    eval "$(extract_final_ref)"

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
  /usr/bin/find ./.github/workflows/ -iname "*.yml" -type f -exec actionlint "{}" \;
  /usr/bin/find ./.github/actions/ -iname "*.yml" -type f -exec composite-action-lint "{}" \;
}

# Run shfmt on *.sh and prettier on workflow YAML files
format_scripts() {
  /usr/bin/find . \
    \( -iname "*.sh" -o -iname "*.bash" \) -type f \
    -exec shfmt -w -i 2 "{}" +
  /usr/bin/find . -iname "*.yml" -type f -exec prettier -w "{}" \;
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
  run_vm "$TARGET_IMAGE" "$TAG" "qcow2" "image.toml" "$output_dir" \
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
  run_vm "$TARGET_IMAGE" "$TAG" "raw" "image.toml" "$output_dir" \
    "$force_pull" "$clean" "$oci_output_dir" "$cache_dir" "$bib_image"
}

# ── SBOM Verification ─────────────────────────────────────────────────────────

# Verify deployed image against remote SBOM attestation
# Usage: verify_sbom [--verbose] [--json] [--image ghcr.io/owner/repo:tag]
verify_sbom() {
  local verbose=""
  local json_output=""
  local image_arg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --verbose | -v)
      verbose="--verbose"
      set -x
      shift
      ;;
    --json | -j)
      json_output="--json"
      shift
      ;;
    --image | -i)
      image_arg="--image $2"
      shift 2
      ;;
    *)
      shift
      ;;
    esac
  done

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  bash "${script_dir}/verify-ostree-sbom.sh" "$verbose" "$json_output" "$image_arg"
}
