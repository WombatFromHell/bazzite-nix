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

# Clean OCI layout directory if it exists
clean_oci_layout() {
  local oci_output_dir="${1:?oci_output_dir required}"
  if [[ -d "$oci_output_dir" && -f "$oci_output_dir/index.json" ]]; then
    echo "  Removing OCI layout: $oci_output_dir"
    rm -rf "$oci_output_dir"
  fi
}

# Clean containers-storage images from rechunking
clean_rechunk_images() {
  local img tag
  for img in localhost/chunked-img localhost/rechunk-img; do
    while read -r tag; do
      [[ -z "$tag" ]] && continue
      echo "  Removing rechunked image: $img:$tag"
      podman rmi --force "$img:$tag" 2>/dev/null || true
    done < <(podman images --no-trunc "$img" 2>/dev/null | tail -n +2 | awk '{print $2}')
  done
}

# Remove locally generated build output images and dangling layers
clean_build_output_images() {
  # Remove build output images (localhost/bazzite-nix:*)
  local tag
  while read -r tag; do
    [[ -z "$tag" ]] && continue
    echo "  Removing build output: localhost/bazzite-nix:$tag"
    buildah rmi --force "localhost/bazzite-nix:$tag" 2>/dev/null || true
  done < <(buildah images --no-trunc "localhost/bazzite-nix" 2>/dev/null | tail -n +2 | awk '{print $2}')

  # Remove localhost/raw-img (all tags)
  local raw_tag
  while read -r raw_tag; do
    [[ -z "$raw_tag" ]] && continue
    echo "  Removing build output: localhost/raw-img:$raw_tag"
    podman rmi --force "localhost/raw-img:$raw_tag" 2>/dev/null || true
  done < <(podman images --no-trunc localhost/raw-img 2>/dev/null | tail -n +2 | awk '{print $2}')

  # Remove dangling (<none>:<none>) intermediate build layers
  local id
  while read -r id; do
    [[ -z "$id" ]] && continue
    echo "  Removing dangling buildah layer: $id"
    buildah rmi --force "$id" 2>/dev/null || true
  done < <(buildah images --filter "dangling=true" --no-trunc 2>/dev/null | tail -n +2 | awk '{print $3}')
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
      podman rmi --force "$img:$tag" 2>/dev/null || true
    done < <(podman images --no-trunc "$img" 2>/dev/null | tail -n +2 | awk '{print $2}')
  done

  # Remove BIB image if present
  podman rmi --force "$bib_image" 2>/dev/null || true

  clean_build_output_images
}

# Clean dangling buildah images (<none>:<none>) — intermediate build artifacts
# Safety: skip any dangling image that is still referenced as a container's base image
clean_buildah_images() {
  local container_images=()
  local dangling=()
  local id cimg in_use

  mapfile -t container_images < <(buildah ps -a --format '{{.ImageID}}' | awk '{print $1}')
  mapfile -t dangling < <(buildah images -a --no-trunc | awk '$1 == "<none>" && $2 == "<none>" {print $3}')

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
      buildah rmi --force "$id" 2>/dev/null || true
    fi
  done
}

# Remove intermediate build containers (working-container, *-working-container, scratch)
# Skip named containers like distroboxes (e.g. 'libvirtbox')
clean_buildah_containers() {
  local cid cname
  buildah ps --all | tail -n +2 | awk '{print $1}' | while read -r cid; do
    [[ -z "$cid" ]] && continue
    cname=$(buildah inspect "$cid" --format '{{.Container}}' 2>/dev/null || true)
    case "$cname" in
    working-container | *-working-container | scratch)
      echo "  Removing build container: $cname ($cid)"
      buildah rm "$cid" 2>/dev/null || true
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
    rm -rf "${cache_dir:?}"/
    echo "VM cache cleaned"
  else
    echo "VM cache does not exist: $cache_dir"
  fi
}
