# just-helpers-vm.bash — VM image build/run functions and their Justfile wrappers.
# Sourced by just-helpers.bash (no shebang/set — see umbrella).

# ── VM image building ───────────────────────────────────────────────────────

# Map a disk type to its filename
disk_file_name() {
  case "$1" in
  qcow2) echo "disk.qcow2" ;;
  raw) echo "disk.raw" ;;
  iso) echo "install.iso" ;;
  *) echo "disk.$1" ;;
  esac
}

# Ensure the BIB and QEMU images are pulled into rootful storage
ensure_vm_images() {
  local bib_image="$1"
  podman image exists "$bib_image" 2>/dev/null || podman pull "$bib_image"
  podman image exists "docker.io/qemux/qemu:latest" 2>/dev/null || podman pull "docker.io/qemux/qemu:latest"
}

# Internal: Core BIB build logic (called by build_bib)
# Usage: _build_bib source_image type config out_dir bib_image
_build_bib() {
  local source_image="${1:?source_image required}"
  local type="${2:?type required}"
  local config="${3:?config required}"
  local out_dir="${4:?out_dir required}"
  local bib_image="${5:?bib_image required}"

  local disk_name disk_file BUILDTMP

  local CACHE_DIR="${CACHE_DIR:-$HOME/.cache/bazzite-nix}"

  disk_name="$(disk_file_name "$type")"
  disk_file="${out_dir}/${disk_name}"
  BUILDTMP="${out_dir}/.bib-tmp"

  if [[ -f "${BUILDTMP}/.bib-build-complete" && -d "$BUILDTMP" ]]; then
    local tmp_disk="${BUILDTMP}/${disk_name}"
    if [[ -f "$tmp_disk" ]]; then
      echo "Found disk in .bib-tmp from previous run, moving to final location..."
      mv -f "$tmp_disk" "$disk_file"
      rmdir "$BUILDTMP" 2>/dev/null || true
      chown "$USER:$USER" "$disk_file"
      echo "Disk image recovered: $disk_file"
      return 0
    fi
  fi

  rm -rf "$BUILDTMP"
  mkdir -p "$BUILDTMP"
  mkdir -p "${CACHE_DIR}/bib-store"

  # shellcheck disable=SC2086
  if
    podman run --rm --privileged \
      -i --init --sig-proxy \
      --pull=missing \
      --net=host \
      --security-opt label=type:unconfined_t \
      -v "$(pwd)/${config}:/config.toml:ro" \
      -v "$BUILDTMP:/output" \
      -v "${CACHE_DIR}/bib-store:/store" \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      "$bib_image" \
      --type $type --use-librepo=True --rootfs=ext4 \
      "$source_image"
  then
    touch "${BUILDTMP}/.bib-build-complete"
  else
    echo "Error: something went wrong with our BIB build!"
    return 1
  fi

  local item
  for item in "$BUILDTMP"/* "$BUILDTMP"/.*; do
    if [[ -d "$item" ]]; then
      mv -f "$item"/* "$out_dir"/
      rmdir "$item"
    else
      mv -f "$item" "$out_dir"/
    fi
  done
  rm -rf "$BUILDTMP"
  chown -R "$USER:$USER" "$out_dir"
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
  disk_name="$(disk_file_name "$type")"
  if [[ -f "${out_dir}/${disk_name}" ]]; then
    echo "Disk image already exists: ${out_dir}/${disk_name} — skipping BIB build"
    echo "Use force_rebuild=1 to force regeneration"
    return 0
  fi

  case "$source_type" in
  podman)
    local effective_tag="$tag"
    if ! buildah images --format '{{.Name}}:{{.Tag}}' "${source}:${tag}" >/dev/null 2>&1; then
      # Fallback to :latest (rechunk_image may not have tagged with $TAG)
      if buildah images --format '{{.Name}}:{{.Tag}}' "${source}:latest" >/dev/null 2>&1; then
        echo "Image ${source}:${tag} not found, using ${source}:latest"
        effective_tag="latest"
      else
        echo "Image ${source}:${tag} not found in rootful storage."
        if podman image exists "${source}:${tag}" 2>/dev/null; then
          echo "Found in rootless storage, copying to rootful..."
          podman save "${source}:${tag}" | podman load
        else
          echo "Image not found in rootless storage either. Pulling..."
          podman pull "${source}:${tag}"
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
    local target_image="localhost/chunked-img"
    if ! buildah images --format '{{.Name}}:{{.Tag}}' "${target_image}:${tag}" >/dev/null 2>&1; then
      skopeo copy "$source" containers-storage:"${target_image}:${tag}"
    else
      echo "Image ${target_image}:${tag} already in rootful storage, skipping copy"
    fi
    source_image="${target_image}:${tag}"
    ;;
  *)
    echo "Unknown source_type: $source_type" >&2
    return 1
    ;;
  esac

  _build_bib "$source_image" "$type" "$config" "$out_dir" "$bib_image"

  if [[ "$source_type" == "oci" ]]; then
    buildah rmi --force "$source_image" 2>/dev/null || true
  fi
}

# Build VM image (shared helper for build-qcow2 and build-raw)
build_vm_image() {
  local image_spec="${1:?image_spec required}"
  local type="${2:?type required}"
  local output_dir="${3:-}"
  local force_rebuild="${4:-0}"
  local cache_dir="${5:-$HOME/.cache/bazzite-nix}"
  local bib_image="${6:-quay.io/centos-bootc/bootc-image-builder:latest}"
  # shellcheck disable=SC2034
  local TARGET_IMAGE TAG BASE_IMAGE BUILD_SCRIPT VARIANT_NAME CANONICAL_TAG TAGS
  local _out_dir _disk_name _disk_file

  eval "$(resolve_variant "$image_spec" "${VARIANTS_CONFIG:-.github/variants.json}" "${IMAGE_NAME:-bazzite-nix}")"

  # Determine output dir and disk filename early
  _out_dir="${output_dir}"
  [[ -z "$_out_dir" ]] && _out_dir="$cache_dir"
  _disk_name="$(disk_file_name "$type")"
  _disk_file="${_out_dir}/${_disk_name}"

  # Force rebuild: evict existing disk so BIB rebuilds from scratch
  if [[ "$force_rebuild" == "1" && -f "$_disk_file" ]]; then
    echo "Force rebuild: removing existing disk: ${_disk_file}"
    rm -f "$_disk_file"
  fi

  # Check for a rechunked containers-storage image first (avoids full image copy)
  if [[ "$force_rebuild" != "1" ]] && buildah images --format '{{.Name}}:{{.Tag}}' "localhost/chunked-img:${TAG}" >/dev/null 2>&1; then
    echo "Using existing rechunked containers-storage image: localhost/chunked-img:${TAG}"
    build_bib "podman" "localhost/chunked-img" "${TAG}" "$type" "image.toml" "$output_dir" "$bib_image"
    return 0
  fi

  # Build container if needed (build_image stages to raw-img)
  build_image_or_skip "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "$force_rebuild"

  # Tag for BIB — bootc-image-builder reads from podman storage
  buildah tag raw-img "${TARGET_IMAGE}:${TAG}" 2>/dev/null || true
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
  local cache_dir="${8:-$HOME/.cache/bazzite-nix}"
  local bib_image="${9:?bib_image required}"

  local OUTPUT_DIR disk_name image_file is_local QEMU_PID success i

  OUTPUT_DIR="${output_dir}"
  [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$cache_dir"
  mkdir -p "$OUTPUT_DIR"

  disk_name="$(disk_file_name "$type")"
  image_file="${OUTPUT_DIR}/${disk_name}"

  if [[ "$clean" == "1" ]]; then
    echo "Removing cached disk image..."
    [[ -f "$image_file" ]] && rm -f "$image_file" && echo "Removed: $image_file" || echo "Nothing to clean"
  fi

  if [[ ! -f "$image_file" ]]; then
    is_local=false
    [[ "$target_image" == localhost/* ]] && is_local=true
    # Prefer rechunked containers-storage image if available (avoids podman image copy)
    if buildah images --format '{{.Name}}:{{.Tag}}' "localhost/chunked-img:${tag}" >/dev/null 2>&1; then
      echo "Using existing rechunked containers-storage image: localhost/chunked-img:${tag}"
      ensure_vm_images "$bib_image"
      echo "Building disk image..."
      build_bib "podman" "localhost/chunked-img" "$tag" "$type" "$config" "$OUTPUT_DIR" "$bib_image"
    elif [[ "$is_local" == "true" ]]; then
      if ! podman image exists "${target_image}:${tag}" 2>/dev/null; then
        echo "Image ${target_image}:${tag} not found in rootful storage."
        echo "   Build it first with: just build-${type} ${target_image}:${tag}"
        return 1
      fi
      ensure_vm_images "$bib_image"
      echo "Building disk image..."
      build_bib "podman" "$target_image" "$tag" "$type" "$config" "$OUTPUT_DIR" "$bib_image"
    else
      echo "Pulling ${target_image}:${tag}..."
      podman pull "${target_image}:${tag}"
      ensure_vm_images "$bib_image"
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
  # shellcheck disable=SC2034
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

# ── VM build/run wrapper functions ──────────────────────────────────────────

# Build a QCOW2 VM disk image for a variant
build_vm_image_qcow2() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local output_dir="${2:-}"
  local force_rebuild="${3:-0}"
  local cache_dir="${4:-$HOME/.cache/bazzite-nix}"
  local bib_image="${5:-quay.io/centos-bootc/bootc-image-builder:latest}"

  build_vm_image "$variant_or_spec" "qcow2" "$output_dir" "$force_rebuild" \
    "$cache_dir" "$bib_image"
}

# Build a RAW VM disk image for a variant
build_vm_image_raw() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local output_dir="${2:-}"
  local force_rebuild="${3:-0}"
  local cache_dir="${4:-$HOME/.cache/bazzite-nix}"
  local bib_image="${5:-quay.io/centos-bootc/bootc-image-builder:latest}"

  build_vm_image "$variant_or_spec" "raw" "$output_dir" "$force_rebuild" \
    "$cache_dir" "$bib_image"
}

# Run a QCOW2 VM for a variant (resolves variant, then launches QEMU)
run_vm_qcow2() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local output_dir="${4:-}"
  local force_pull="${5:-0}"
  local clean="${6:-0}"
  local cache_dir="${7:-$HOME/.cache/bazzite-nix}"
  local bib_image="${8:-quay.io/centos-bootc/bootc-image-builder:latest}"
  local TARGET_IMAGE TAG
  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name")"
  run_vm "$TARGET_IMAGE" "${TAG}" "qcow2" "image.toml" "$output_dir" \
    "$force_pull" "$clean" "$cache_dir" "$bib_image"
}

# Run a RAW VM for a variant (resolves variant, then launches QEMU)
run_vm_raw() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local output_dir="${4:-}"
  local force_pull="${5:-0}"
  local clean="${6:-0}"
  local cache_dir="${7:-$HOME/.cache/bazzite-nix}"
  local bib_image="${8:-quay.io/centos-bootc/bootc-image-builder:latest}"
  local TARGET_IMAGE TAG
  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name")"
  run_vm "$TARGET_IMAGE" "${TAG}" "raw" "image.toml" "$output_dir" \
    "$force_pull" "$clean" "$cache_dir" "$bib_image"
}
