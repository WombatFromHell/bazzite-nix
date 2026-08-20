# just-helpers-clean.bash — clean/remove functions for just-helpers.
# Sourced by just-helpers.bash (no shebang/set — see umbrella).

# ── Clean functions ─────────────────────────────────────────────────────────

# Clean root filesystem build artifacts
clean_artifacts() {
  find "$PWD" -maxdepth 1 -name "*_build*" -exec rm -rf {} \; 2>/dev/null || true
  rm -rf .pytest_cache .ruff_cache
  find "$PWD" -name "__pycache__" -type d -exec rm -rf {} \; 2>/dev/null || true
  rm -f previous.manifest.json changelog.md output.env
  rm -rf output/
}

# Remove the given images by hash (full id) via <podman|sudo-podman>, then
# prune dangling layers and stopped containers. Images already absent are
# skipped; rmi --force on the id guarantees the exact image is gone even if a
# tag is re-applied.
# Usage: remove_images_and_prune <podman|sudo-podman> <image>...
remove_images_and_prune() {
  local tool_name="${1:?tool required}"
  shift
  local -a tool=()
  case "$tool_name" in
  podman) tool=(podman) ;;
  sudo-podman) tool=(sudo podman) ;;
  esac
  local img id
  for img in "$@"; do
    id="$("${tool[@]}" image inspect --format '{{.Id}}' "$img" 2>/dev/null)" || continue
    [[ -n "$id" ]] || continue
    echo "  Removing $img ($id)"
    "${tool[@]}" rmi --force "$id" 2>/dev/null || true
  done
  "${tool[@]}" image prune --force 2>/dev/null || true
}

# Clean the OCI layout base dir (per-variant layouts live underneath it)
clean_oci_layout() {
  local oci_output_dir="${1:?oci_output_dir required}"
  if [[ -d "$oci_output_dir" ]]; then
    echo "  Removing OCI layout dir: $oci_output_dir"
    rm -rf "$oci_output_dir"
  fi
}

# Clean cached VM disk images (leaves the rest of the cache dir intact)
clean_vm_cache() {
  local cache_dir="${1:?cache_dir required}"
  local t
  if [[ -d "$cache_dir" ]]; then
    echo "Removing VM disk images from $cache_dir..."
    for t in qcow2 raw iso; do
      rm -f "${cache_dir}/$(disk_file_name "$t")"
    done
    echo "VM cache cleaned"
  else
    echo "VM cache does not exist: $cache_dir"
  fi
}
