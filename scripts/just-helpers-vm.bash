# just-helpers-vm.bash — VM image build/run functions and their Justfile wrappers.
# Sourced by just-helpers.bash (no shebang/set — see umbrella).

# shellcheck disable=SC2153
# CACHE_DIR is exported by build-helpers.bash, which the umbrella sources first.

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

# Ensure the BIB image is in rootful storage (BIB requires it) and the QEMU
# image is in rootless storage
ensure_vm_images() {
  local bib_image="$1"
  sudo_cache
  sudo podman image exists "$bib_image" 2>/dev/null || sudo podman pull "$bib_image"
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

  disk_name="$(disk_file_name "$type")"
  disk_file="${out_dir}/${disk_name}"
  BUILDTMP="${out_dir}/.bib-tmp"

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
  mkdir -p "${CACHE_DIR}/bib-store"

  # shellcheck disable=SC2086
  if
    sudo podman run --rm --privileged \
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

# Build a BIB VM image from an OCI layout directory. The layout is imported
# into rootful storage (BIB requires it) as localhost/chunked-img:<tag>, used
# to build the disk, then the import is removed again.
# Usage: build_bib <source> <tag> <type> <config> <output_dir> <bib_image>
#   source:      OCI layout dir (per-variant chunked dir, or an ad-hoc
#                `podman save --format oci` export)
#   tag:         image tag (addresses the rootful import)
#   type:        qcow2, raw, etc.
#   config:      config.toml path
#   output_dir:  output directory (defaults to CACHE_DIR)
#   bib_image:   BIB container image
build_bib() {
  local source="${1:?source (OCI layout dir) required}"
  local tag="${2:?tag required}"
  local type="${3:?type required}"
  local config="${4:?config required}"
  local output_dir="${5:-}"
  local bib_image="${6:?bib_image required}"

  local out_dir source_image

  out_dir="${output_dir}"
  if [[ -z "$out_dir" ]]; then
    out_dir="$CACHE_DIR"
  fi
  mkdir -p "$out_dir"

  local disk_name
  disk_name="$(disk_file_name "$type")"
  if [[ -f "${out_dir}/${disk_name}" ]]; then
    echo "Disk image already exists: ${out_dir}/${disk_name} — skipping BIB build"
    echo "Use force_rebuild=1 to force regeneration"
    return 0
  fi

  sudo_cache

  # BIB requires rootful storage; import the (single-image) layout with podman
  # so the localhost/... reference resolves inside the BIB container. A
  # tagless pull is safe: chunkah/saved layouts hold exactly one image.
  if ! sudo podman image exists "$(image_ref chunked-img "$tag")" 2>/dev/null; then
    local id
    id="$(sudo podman pull "oci:${source}")"
    sudo podman tag "$id" "$(image_ref chunked-img "$tag")"
  else
    echo "Image $(image_ref chunked-img "$tag") already in storage, skipping import"
  fi
  source_image="$(image_ref chunked-img "$tag")"

  _build_bib "$source_image" "$type" "$config" "$out_dir" "$bib_image"

  # The import exists only to feed BIB; drop it from rootful storage.
  sudo podman rmi --force "$source_image" 2>/dev/null || true
}

# Print the per-variant chunked OCI layout dir left behind by the pipeline,
# or nothing if there is none. Layouts live at
# <OCI_OUTPUT_DIR or cache_dir/oci>/<variant>/chunked.
variant_chunked_layout() {
  local variant_name="${1:?variant_name required}"
  local cache_dir="${2:-$CACHE_DIR}"
  local layout="${OCI_OUTPUT_DIR:-${cache_dir}/oci}/${variant_name}/chunked"
  [[ -f "${layout}/index.json" ]] && echo "$layout"
  return 0
}

# Export <image> ad-hoc to a temp OCI layout, feed it to build_bib, and remove
# the layout afterwards. (The pipeline's per-variant layout, when present, is
# preferred by the callers — see variant_chunked_layout.)
# Usage: export_and_build_bib <image> <tag> <type> <config> <output_dir> <bib_image>
export_and_build_bib() {
  local image="${1:?image required}"
  local tag="${2:?tag required}"
  local type="${3:?type required}"
  local config="${4:?config required}"
  local output_dir="${5:-}"
  local bib_image="${6:?bib_image required}"
  # Stream rootless image straight into rootful storage (no temp disk round-trip).
  local size
  size="$(podman inspect --format '{{.Size}}' "$image" 2>/dev/null || echo 0)"
  podman save "$image" | pv -s "${size:-0}" | sudo podman load
  sudo podman tag "$image" "$(image_ref chunked-img "$tag")"
  build_bib "$(image_ref chunked-img "$tag")" "$tag" "$type" "$config" "$output_dir" "$bib_image"
}

# Resolve a variant name or image:tag spec into the record the VM entrypoints
# consume.
# Usage: vm_record_json <variant_or_spec> [variants_config] [image_name]
vm_record_json() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-${VARIANTS_CONFIG:-.github/variants.json}}"
  local image_name="${3:?image_name required}"
  # shellcheck disable=SC2034
  local TARGET_IMAGE TAG BASE_IMAGE BUILD_SCRIPT VARIANT_NAME CANONICAL_TAG TAGS
  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name")"
  jq -cn --arg variant "$VARIANT_NAME" --arg tag "$TAG" --arg target_image "$TARGET_IMAGE" \
    --arg base_image "$BASE_IMAGE" --arg build_script "$BUILD_SCRIPT" --arg canonical_tag "$CANONICAL_TAG" \
    '{variant: $variant, tag: $tag, target_image: $target_image, base_image: $base_image, build_script: $build_script, canonical_tag: $canonical_tag}'
}

# Build VM image (shared helper for build-qcow2 and build-raw)
# Usage: build_vm_image <record_json> [options_json]
# Record fields: variant, tag, target_image, base_image, build_script, canonical_tag
# Options: {"type":..,"output_dir":..,"force_rebuild":0|1,"cache_dir":..,"bib_image":..}
build_vm_image() {
  local record_json="${1:?record_json required}"
  local options_json="${2:-}"

  local variant tag target_image base_image build_script canonical_tag
  local type output_dir force_rebuild cache_dir bib_image
  IFS=$'\037' read -r variant tag target_image base_image build_script canonical_tag < <(jq -r '[.variant, .tag, .target_image, .base_image, .build_script, (.canonical_tag // "")] | join("\u001f")' <<<"$record_json")
  IFS=$'\037' read -r type output_dir force_rebuild cache_dir bib_image < <(jq -r '[(.type // ""), (.output_dir // ""), (.force_rebuild // "0"), (.cache_dir // ""), (.bib_image // "quay.io/centos-bootc/bootc-image-builder:latest")] | join("\u001f")' <<<"$options_json")
  [[ -n "$cache_dir" ]] || cache_dir="$CACHE_DIR"
  if [[ -z "$type" || -z "$variant" ]]; then
    echo "ERROR: type and record variant are required" >&2
    return 1
  fi
  local _out_dir _disk_name _disk_file

  _out_dir="${output_dir}"
  [[ -z "$_out_dir" ]] && _out_dir="$cache_dir"
  _disk_name="$(disk_file_name "$type")"
  _disk_file="${_out_dir}/${_disk_name}"

  # Force rebuild: evict existing disk so BIB rebuilds from scratch
  if [[ "$force_rebuild" == "1" && -f "$_disk_file" ]]; then
    echo "Force rebuild: removing existing disk: ${_disk_file}"
    rm -f "$_disk_file"
  fi

  # Prefer the per-variant chunked OCI layout left behind by the pipeline
  # (avoids building/exporting the image at all)
  local _layout
  _layout="$(variant_chunked_layout "$variant" "$cache_dir")"
  if [[ -n "$_layout" ]]; then
    echo "Using existing rechunked OCI layout: ${_layout}"
    build_bib "${_layout}" "${tag}" "$type" "image.toml" "$output_dir" "$bib_image"
    return 0
  fi

  # Fallback: build raw-img and export it ad-hoc to an OCI layout
  build_image_or_skip "$base_image" "$build_script" "$canonical_tag" "$variant" "$force_rebuild"
  # Keep the local <image>:<tag> ref resolvable for run_vm's local-image path
  # (cheap: same-storage ref, no copy)
  podman tag "$(image_ref raw-img)" "${target_image}:${tag}" 2>/dev/null || true
  export_and_build_bib "$(image_ref raw-img)" "${tag}" "$type" "image.toml" "$output_dir" "$bib_image"
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
  local cache_dir="${8:-$CACHE_DIR}"
  local bib_image="${9:?bib_image required}"
  local variant_name="${10:-}"

  local OUTPUT_DIR disk_name image_file is_local QEMU_PID success i
  local layout_dir=""

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
    ensure_vm_images "$bib_image"

    # Prefer the per-variant chunked OCI layout left behind by the pipeline;
    # otherwise export the (rootless) source image ad-hoc to an OCI layout.
    if [[ -n "$variant_name" ]]; then
      layout_dir="$(variant_chunked_layout "$variant_name" "$cache_dir")"
      [[ -n "$layout_dir" ]] && echo "Using existing rechunked OCI layout: ${layout_dir}"
    fi
    if [[ -n "$layout_dir" ]]; then
      echo "Building disk image..."
      build_bib "$layout_dir" "$tag" "$type" "$config" "$OUTPUT_DIR" "$bib_image"
    else
      is_local=false
      [[ "$target_image" == localhost/* ]] && is_local=true
      if [[ "$is_local" == "true" ]]; then
        if ! podman image exists "${target_image}:${tag}" 2>/dev/null; then
          echo "Image ${target_image}:${tag} not found in storage."
          echo "   Build it first with: just build-${type} ${target_image}:${tag}"
          return 1
        fi
      else
        echo "Pulling ${target_image}:${tag}..."
        podman pull "${target_image}:${tag}"
      fi
      echo "Building disk image..."
      export_and_build_bib "${target_image}:${tag}" "$tag" "$type" "$config" "$OUTPUT_DIR" "$bib_image"
    fi
  fi

  if [[ ! -f "$image_file" ]]; then
    echo "Disk image not found: $image_file"
    return 1
  fi

  echo "Starting VM... Connect to http://127.0.0.1:8006"
  podman run --rm --privileged \
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

# Run a VM for a variant (resolves variant, then launches QEMU)
# Usage: run_variant_vm <type> <variant_or_spec> [variants_config] <image_name>
#                          [output_dir] [force_pull] [clean] [cache_dir] [bib_image]
# Usage: run_variant_vm <record_json> [options_json]
# Record fields: variant, tag, target_image
# Options: {"type":..,"output_dir":..,"force_pull":0|1,"clean":0|1,
#           "cache_dir":..,"bib_image":..}
run_variant_vm() {
  local record_json="${1:?record_json required}"
  local options_json="${2:-}"

  local variant tag target_image
  local type output_dir force_pull clean cache_dir bib_image
  IFS=$'\037' read -r variant tag target_image < <(jq -r '[.variant, .tag, .target_image] | join("\u001f")' <<<"$record_json")
  IFS=$'\037' read -r type output_dir force_pull clean cache_dir bib_image < <(jq -r '[(.type // ""), (.output_dir // ""), (.force_pull // "0"), (.clean // "0"), (.cache_dir // ""), (.bib_image // "")] | join("\u001f")' <<<"$options_json")
  [[ -n "$cache_dir" ]] || cache_dir="$CACHE_DIR"
  if [[ -z "$type" || -z "$variant" ]]; then
    echo "ERROR: type and record variant are required" >&2
    return 1
  fi

  run_vm "$target_image" "$tag" "$type" "image.toml" "$output_dir" \
    "$force_pull" "$clean" "$cache_dir" "$bib_image" "$variant"
}
