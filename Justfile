export repo_organization := env("GITHUB_REPOSITORY_OWNER", "wombatfromhell")
export image_name := env("IMAGE_NAME", "bazzite-nix")
export image_desc := env("IMAGE_DESC", "Customized Bazzite image with Nix mount support and other sugar")
export image_tag := env("IMAGE_TAG", "latest")
export image_build_script := env("IMAGE_BUILD_SCRIPT", "build.sh")
export centos_version := env("CENTOS_VERSION", "stream10")
export fedora_version := env("FEDORA_VERSION", "43")
export default_tag := env("DEFAULT_TAG", "testing")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")
export base_image := env("BASE_IMAGE", "ghcr.io/ublue-os/bazzite:stable")
export cache_dir := env("CACHE_DIR", `echo "$HOME/.cache/bazzite-nix"`)
export variants_config := env("VARIANTS_CONFIG", ".github/variants.json")
export oci_output_dir := env("OCI_OUTPUT_DIR", "/var/lib/containers/oci")

# Path to shared build helpers — used by both CI and local builds

helpers_build := ".github/actions/build-reusable/helpers.sh"

[private]
default:
    @just --list

# Check Just syntax
[group('Just')]
check:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
        echo "Checking syntax: $file"
        just --unstable --fmt --check -f "$file"
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Fix Just syntax
[group('Just')]
fix:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
        echo "Fixing syntax: $file"
        just --unstable --fmt -f "$file"
    done
    echo "Fixing syntax: Justfile"
    just --unstable --fmt -f Justfile || { exit 1; }

# Clean repo build artifacts
[group('Utility')]
clean:
    touch _build
    find *_build* -exec rm -rf {} \;
    rm -f previous.manifest.json changelog.md output.env
    rm -rf output/
    sudo rm -rf {{ oci_output_dir }}
    sudo podman image prune -f
    sudo buildah rm --all
    just --unstable clean-vm

# Clean cached VM disk images
[group('Utility')]
clean-vm:
    #!/usr/bin/env bash
    set -euo pipefail
    VM_CACHE="{{ cache_dir }}"
    if [[ -d "$VM_CACHE" ]]; then
        echo "Removing VM cache from $VM_CACHE..."
        sudo rm -rf "$VM_CACHE"/
        echo "VM cache cleaned"
    else
        echo "VM cache does not exist: $VM_CACHE"
    fi

# Run shellcheck on all Bash scripts
[group('Utility')]
lint:
    @/usr/bin/find . -iname "*.sh" -type f -exec shellcheck "{}" \;
    @/usr/bin/find ./.github/workflows/ -iname "*.yml" -type f -exec actionlint "{}" \;

# Run shfmt on all Bash scripts
[group('Utility')]
format:
    @/usr/bin/find . -iname "*.sh" -type f -exec shfmt --write -i 2 "{}" \;
    @/usr/bin/find . -iname "*.yml" -type f -exec prettier -w "{}" \;

# ── Build commands (sources .github/actions/build-reusable/helpers.sh) ────────
# Build a container image (stages to localhost/raw-img)
# Usage: just build [variant-name | image:tag] [base_image_override]
# Examples:
#   just build testing
#   just build cachyos

# just build bazzite-nix:mytag ghcr.io/ublue-os/bazzite:testing
[group('Build Container Image')]
build $variant_or_spec="{{ default_tag }}" $base_image_override="":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ helpers_build }}"
    eval "$(just --unstable _resolve-variant "{{ variant_or_spec }}")"
    [[ -n "{{ base_image_override }}" ]] && BASE_IMAGE="{{ base_image_override }}"
    build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile"

# Force-rebuild a container image, evicting any cached local image first

# Usage: just rebuild [variant-name | image:tag] [base_image_override]
[group('Build Container Image')]
rebuild $variant_or_spec="{{ default_tag }}" $base_image_override="":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ helpers_build }}"
    eval "$(just --unstable _resolve-variant "{{ variant_or_spec }}")"
    [[ -n "{{ base_image_override }}" ]] && BASE_IMAGE="{{ base_image_override }}"
    sudo podman rmi localhost/raw-img 2>/dev/null || true
    build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile"

# Rechunk localhost/raw-img to OCI layout with bootc chunking
# (Mirrors .github/actions/build-reusable: extract_image_info → assemble_labels → rechunk_image)
# Usage: just rechunk [variant-name | image:tag]

# Example: just rechunk testing
[group('Build Container Image')]
rechunk $variant_or_spec="{{ default_tag }}":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ helpers_build }}"
    eval "$(just --unstable _resolve-variant "{{ variant_or_spec }}")"
    manifest_file="/tmp/bazzite-nix-manifest.json"
    labels_file="/tmp/bazzite-nix-labels.txt"
    eval "$(extract_image_info "$manifest_file")"
    assemble_labels \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "{{ image_desc }}" "$VARIANT_NAME" "$TAG" \
      "{{ repo_organization }}" "{{ image_name }}" "$KERNEL_VERSION" \
      "$manifest_file" "$labels_file"
    rechunk_image "$labels_file"
    eval "$(extract_final_ref)"

# ── Full pipeline (mirrors the GitHub Actions workflow) ─────────────────────
# Run the full build pipeline for a single variant:
#   build → extract image info → assemble labels → rechunk → extract final ref

# Usage: just pipeline [variant-name | image:tag] [base_image_override]
[group('Build Container Image')]
pipeline $variant_or_spec="{{ default_tag }}" $base_image_override="":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ helpers_build }}"
    eval "$(just --unstable _resolve-variant "{{ variant_or_spec }}")"
    [[ -n "{{ base_image_override }}" ]] && BASE_IMAGE="{{ base_image_override }}"

    echo "=== Phase 1: Build ==="
    sudo podman rmi localhost/raw-img 2>/dev/null || true
    build_image "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "./Containerfile"

    echo "=== Phase 2: Extract image info ==="
    manifest_file="/tmp/bazzite-nix-manifest.json"
    labels_file="/tmp/bazzite-nix-labels.txt"
    eval "$(extract_image_info "$manifest_file")"

    echo "=== Phase 3: Assemble labels & Rechunk ==="
    assemble_labels \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "{{ image_desc }}" "$VARIANT_NAME" "$CANONICAL_TAG" \
      "{{ repo_organization }}" "{{ image_name }}" "$KERNEL_VERSION" \
      "$manifest_file" "$labels_file"
    rechunk_image "$labels_file"

    echo "=== Phase 4: Extract final ref ==="
    eval "$(extract_final_ref)"

    echo ""
    echo "=== Pipeline complete ==="
    echo "  Variant      : $VARIANT_NAME"
    echo "  Kernel       : $KERNEL_VERSION"
    echo "  Manifest pkgs: $MANIFEST_PACKAGES"
    echo "  Source ref   : $SOURCE_REF"
    echo "  Full digest  : $FULL_DIGEST"
    echo "  Short digest : $BUILD_DIGEST"

# Run the full pipeline for all variants that need rebuilding
# (Mirrors check_and_aggregate → build_push matrix in the workflow)
# Usage: just build-all [force_build]
# Examples:
#   just build-all

# just build-all 1    # force rebuild
[group('Build Container Image')]
build-all $force_build="0":
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable _check-variants "{{ force_build }}"
    just --unstable _build-all-variants

# ── Variant helpers ─────────────────────────────────────────────────────────

# List available (non-disabled) variants from variants.json
[group('Utility')]
list-variants:
    #!/usr/bin/env bash
    echo "Available variants:"
    jq -r '.variants[] | select((.disabled // false) == false) | "  \(.name)  →  \(.base_image)  [\(.build_script // "build.sh")]"' \
        ./.github/variants.json

# Check which variants need rebuilding (mirrors check-variants action)

# Usage: just check-variants [force_build]
[group('Build Container Image')]
check-variants $force_build="0":
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable _check-variants "{{ force_build }}"

# ── VM commands ─────────────────────────────────────────────────────────────
# Build a QCOW2 VM disk image

# Usage: just build-qcow2 [variant-name | image:tag] [output_dir]
[group('Build Virtual Machine Image')]
build-qcow2 $variant_or_spec="{{ default_tag }}" $output_dir="" $force_rebuild="0":
    just --unstable _build-vm-image "{{ variant_or_spec }}" "qcow2" "{{ output_dir }}" "{{ force_rebuild }}"

# Build a RAW VM disk image

# Usage: just build-raw [variant-name | image:tag] [output_dir]
[group('Build Virtual Machine Image')]
build-raw $variant_or_spec="{{ default_tag }}" $output_dir="" $force_rebuild="0":
    just --unstable _build-vm-image "{{ variant_or_spec }}" "raw" "{{ output_dir }}" "{{ force_rebuild }}"

# Build and force-rebuild a QCOW2 image (skips cached container image)
[group('Build Virtual Machine Image')]
rebuild-qcow2 $variant_or_spec="{{ default_tag }}" $output_dir="":
    just --unstable build-qcow2 "{{ variant_or_spec }}" "{{ output_dir }}" "1"

# Build and force-rebuild a RAW image (skips cached container image)
[group('Build Virtual Machine Image')]
rebuild-raw $variant_or_spec="{{ default_tag }}" $output_dir="":
    just --unstable build-raw "{{ variant_or_spec }}" "{{ output_dir }}" "1"

# Run a QCOW2 VM

# Usage: just run-vm-qcow2 [variant-name | image:tag] [output_dir] [force_pull] [clean]
[group('Run Virtual Machine')]
run-vm-qcow2 $variant_or_spec="{{ default_tag }}" $output_dir="" $force_pull="0" $clean="0":
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just --unstable _resolve-variant "{{ variant_or_spec }}")"
    just --unstable _run-vm "$TARGET_IMAGE" "$TAG" "qcow2" "image.toml" "{{ output_dir }}" "{{ force_pull }}" "{{ clean }}"

# Run a RAW VM

# Usage: just run-vm-raw [variant-name | image:tag] [output_dir] [force_pull] [clean]
[group('Run Virtual Machine')]
run-vm-raw $variant_or_spec="{{ default_tag }}" $output_dir="" $force_pull="0" $clean="0":
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just --unstable _resolve-variant "{{ variant_or_spec }}")"
    just --unstable _run-vm "$TARGET_IMAGE" "$TAG" "raw" "image.toml" "{{ output_dir }}" "{{ force_pull }}" "{{ clean }}"

# ── Private helpers ─────────────────────────────────────────────────────────
# Resolve a variant name from variants.json into shell variable assignments

# Usage: eval "$(just --unstable _resolve-variant testing)"
[private]
_resolve-variant $variant_or_spec="":
    #!/usr/bin/env bash
    set -euo pipefail
    VARIANT_JSON="{{ variants_config }}"
    spec="{{ variant_or_spec }}"

    # If it looks like an explicit image:tag or image ref, pass it through unchanged
    if [[ "$spec" == *"/"* ]] || [[ "$spec" == *":"* ]]; then
        tag="${spec##*:}"
        build_script=$(jq -r --arg bi "$spec" '
            .variants[] | select(.base_image == $bi and (.disabled // false) == false)
            | (.build_script // "build.sh")
        ' "$VARIANT_JSON" | head -1)
        [[ -z "$build_script" ]] && build_script="build.sh"
        # Extract real version from upstream image label
        canonical=$(skopeo inspect "docker://${spec}" 2>/dev/null \
            | jq -r '.Labels["org.opencontainers.image.version"] // empty' \
            || true)
        [[ -z "$canonical" || "$canonical" == "null" ]] && canonical="$tag"
        echo "TARGET_IMAGE=\"localhost/{{ image_name }}\""
        echo "TAG=\"$tag\""
        echo "BASE_IMAGE=\"$spec\""
        echo "BUILD_SCRIPT=\"$build_script\""
        echo "VARIANT_NAME=\"$tag\""
        echo "CANONICAL_TAG=\"$canonical\""
        exit 0
    fi

    # Look up variant by name
    row=$(jq -r --arg n "$spec" '
        .variants[]
        | select(.name == $n and (.disabled // false) == false)
    ' "$VARIANT_JSON")

    if [[ -z "$row" ]]; then
        echo "ERROR: Unknown or disabled variant: $spec" >&2
        echo "Available variants:" >&2
        jq -r '.variants[] | select((.disabled // false) == false) | "  " + .name' "$VARIANT_JSON" >&2
        exit 1
    fi

    base_image=$(echo "$row" | jq -r '.base_image')
    build_script=$(echo "$row" | jq -r '.build_script // "build.sh"')
    suffix=$(echo "$row" | jq -r '.suffix // ""')
    image_name_resolved="{{ image_name }}${suffix}"
    tag="${base_image##*:}"

    # Extract real version from upstream image label
    canonical=$(skopeo inspect "docker://${base_image}" 2>/dev/null \
        | jq -r '.Labels["org.opencontainers.image.version"] // empty' \
        || true)
    [[ -z "$canonical" || "$canonical" == "null" ]] && canonical="$tag"

    echo "TARGET_IMAGE=\"localhost/${image_name_resolved}\""
    echo "TAG=\"${tag}\""
    echo "BASE_IMAGE=\"${base_image}\""
    echo "BUILD_SCRIPT=\"${build_script}\""
    echo "VARIANT_NAME=\"${spec}\""
    echo "CANONICAL_TAG=\"$canonical\""

# Build VM image (shared helper for build-qcow2 and build-raw)

# Sources build-reusable helpers.sh for build_image
[private]
_build-vm-image $image_spec $type $output_dir="" $force_rebuild="0":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ helpers_build }}"
    eval "$(just --unstable _resolve-variant "{{ image_spec }}")"

    # Determine output dir and disk filename early
    _out_dir="{{ output_dir }}"
    [[ -z "$_out_dir" ]] && _out_dir="{{ cache_dir }}"
    case "{{ type }}" in
        qcow2) _disk_name="disk.qcow2" ;;
        raw)   _disk_name="disk.raw" ;;
        *)     _disk_name="disk.{{ type }}" ;;
    esac
    _disk_file="${_out_dir}/${_disk_name}"

    # Force rebuild: evict existing disk so BIB rebuilds from scratch
    if [[ "{{ force_rebuild }}" == "1" && -f "$_disk_file" ]]; then
        echo "Force rebuild: removing existing disk: ${_disk_file}"
        sudo rm -f "$_disk_file"
    fi

    OCI_LAYOUT="oci:{{ oci_output_dir }}:latest"

    # Check for a rechunked OCI layout first (avoids full image copy)
    if [[ "{{ force_rebuild }}" != "1" && -d {{ oci_output_dir }} && -f {{ oci_output_dir }}/index.json ]]; then
        echo "Using existing rechunked OCI layout: ${OCI_LAYOUT}"
        just --unstable _build-bib-oci "$OCI_LAYOUT" "$TAG" "{{ type }}" "image.toml" "{{ output_dir }}"
        exit 0
    fi

    # Build container if needed (build_image stages to localhost/raw-img)
    if [[ "{{ force_rebuild }}" == "1" ]]; then
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

    just --unstable _build-bib "$TARGET_IMAGE" "$TAG" "{{ type }}" "image.toml" "{{ output_dir }}"

[private]
_build-bib $target_image $tag $type $config $output_dir="":
    #!/usr/bin/env bash
    set -euo pipefail

    out_dir="${output_dir}"
    if [[ -z "$out_dir" ]]; then
        out_dir="{{ cache_dir }}"
    fi
    mkdir -p "$out_dir"

    case "$type" in
        qcow2) disk_name="disk.qcow2" ;;
        raw)   disk_name="disk.raw" ;;
        *)     disk_name="disk.${type}" ;;
    esac
    disk_file="${out_dir}/${disk_name}"

    if [[ -f "$disk_file" ]]; then
        echo "Disk image already exists: ${disk_file} — skipping BIB build"
        echo "Use force_rebuild=1 to force regeneration"
        exit 0
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

    args="--type ${type} --use-librepo=True --rootfs=btrfs"

    if [[ "$target_image" == localhost/* ]]; then
        source_image="${target_image}:${tag}"
    else
        source_image="localhost/${target_image}:${tag}"
    fi

    BUILDTMP="${out_dir}/.bib-tmp"
    rm -rf "$BUILDTMP"
    mkdir -p "$BUILDTMP"

    sudo podman run --rm -it --privileged \
        --pull=newer \
        --net=host \
        --security-opt label=type:unconfined_t \
        -v "$(pwd)/${config}:/config.toml:ro" \
        -v "$BUILDTMP:/output" \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        "${bib_image}" \
        ${args} \
        "$source_image"

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

# Build VM image from an OCI layout ref (avoids full image copy)

[private]
_build-bib-oci $source_image $tag $type $config $output_dir="":
    #!/usr/bin/env bash
    set -euo pipefail

    out_dir="${output_dir}"
    if [[ -z "$out_dir" ]]; then
        out_dir="{{ cache_dir }}"
    fi
    mkdir -p "$out_dir"

    case "$type" in
        qcow2) disk_name="disk.qcow2" ;;
        raw)   disk_name="disk.raw" ;;
        *)     disk_name="disk.${type}" ;;
    esac
    disk_file="${out_dir}/${disk_name}"

    if [[ -f "$disk_file" ]]; then
        echo "Disk image already exists: ${disk_file} — skipping BIB build"
        echo "Use force_rebuild=1 to force regeneration"
        exit 0
    fi

    # Import OCI layout into containers-storage so BIB can resolve it
    sudo skopeo copy "$source_image" containers-storage:"${TARGET_IMAGE:-localhost/rechunked}:${tag}"

    args="--type ${type} --use-librepo=True --rootfs=btrfs"
    source_image_ref="${TARGET_IMAGE:-localhost/rechunked}:${tag}"

    BUILDTMP="${out_dir}/.bib-tmp"
    rm -rf "$BUILDTMP"
    mkdir -p "$BUILDTMP"

    sudo podman run --rm -it --privileged \
        --pull=newer \
        --net=host \
        --security-opt label=type:unconfined_t \
        -v "$(pwd)/${config}:/config.toml:ro" \
        -v "$BUILDTMP:/output" \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        "${bib_image}" \
        ${args} \
        "$source_image_ref"

    # Clean up the imported image (OCI layout stays on disk)
    sudo podman rmi --force "$source_image_ref" 2>/dev/null || true

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

[private]
_run-vm $target_image $tag $type $config $output_dir="" $force_pull="0" $clean="0":
    #!/usr/bin/bash
    set -euo pipefail

    OUTPUT_DIR="${output_dir}"
    [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="{{ cache_dir }}"
    mkdir -p "$OUTPUT_DIR"

    case "$type" in
        qcow2) disk_name="disk.qcow2" ;;
        raw)   disk_name="disk.raw" ;;
        iso)   disk_name="install.iso" ;;
        *)     disk_name="disk.${type}" ;;
    esac
    image_file="${OUTPUT_DIR}/${disk_name}"

    if [[ "{{ clean }}" == "1" ]]; then
        echo "Removing cached disk image..."
        [[ -f "$image_file" ]] && sudo rm -f "$image_file" && echo "Removed: $image_file" || echo "Nothing to clean"
    fi

    if [[ ! -f "$image_file" ]]; then
        is_local=false
        [[ "$target_image" == localhost/* ]] && is_local=true

        OCI_LAYOUT="oci:{{ oci_output_dir }}:latest"

        # Prefer rechunked OCI layout if available (avoids podman image copy)
        if [[ -d {{ oci_output_dir }} && -f {{ oci_output_dir }}/index.json ]]; then
            echo "Using existing rechunked OCI layout: ${OCI_LAYOUT}"
            sudo podman image exists "${bib_image}" 2>/dev/null || sudo podman pull "${bib_image}"
            sudo podman image exists "docker.io/qemux/qemu:latest" 2>/dev/null || sudo podman pull "docker.io/qemux/qemu:latest"
            echo "Building disk image..."
            just --unstable _build-bib-oci "$OCI_LAYOUT" "$tag" "$type" "$config" "$OUTPUT_DIR"
        elif [[ "$is_local" == "true" ]]; then
            if ! sudo podman image exists "${target_image}:${tag}" 2>/dev/null; then
                echo "Image ${target_image}:${tag} not found in rootful storage."
                echo "   Build it first with: just build-${type} ${target_image}:${tag}"
                exit 1
            fi
            sudo podman image exists "${bib_image}" 2>/dev/null || sudo podman pull "${bib_image}"
            sudo podman image exists "docker.io/qemux/qemu:latest" 2>/dev/null || sudo podman pull "docker.io/qemux/qemu:latest"
            echo "Building disk image..."
            just --unstable _build-bib "$target_image" "$tag" "$type" "$config" "$OUTPUT_DIR"
        else
            if [[ "{{ force_pull }}" == "1" ]] || ! sudo podman image exists "${target_image}:${tag}" 2>/dev/null; then
                echo "Pulling ${target_image}:${tag}..."
                sudo podman pull "${target_image}:${tag}"
            fi
            sudo podman image exists "${bib_image}" 2>/dev/null || sudo podman pull "${bib_image}"
            sudo podman image exists "docker.io/qemux/qemu:latest" 2>/dev/null || sudo podman pull "docker.io/qemux/qemu:latest"
            echo "Building disk image..."
            just --unstable _build-bib "$target_image" "$tag" "$type" "$config" "$OUTPUT_DIR"
        fi
    fi

    if [[ ! -f "$image_file" ]]; then
        echo "Disk image not found: $image_file"
        exit 1
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

    if [ "$success" = false ]; then
        echo -e "\n  Timeout: Service didn't start in time. Check logs or open http://127.0.0.1:8006 manually."
    fi

    wait $QEMU_PID || echo "  VM exited"

# Check which variants need rebuilding (mirrors check-variants action)

# Writes results to /tmp/variants_results.json
[private]
_check-variants $force_build="0":
    #!/usr/bin/env bash
    set -euo pipefail

    registry="ghcr.io/$(echo "{{ repo_organization }}" | tr '[:upper:]' '[:lower:]')"
    repo="{{ image_name }}"
    image_desc="Customized Bazzite image with Nix mount support and other sugar"
    date_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    REGISTRY="$registry" \
    REPO="$repo" \
    IMAGE_DESC="$image_desc" \
    DATE="$date_iso" \
    FORCE_BUILD="{{ force_build }}" \
    VARIANTS_CONFIG="{{ variants_config }}" \
        bash .github/actions/check-variants/check-variants.sh

    echo "=== Variant check results ==="
    cat /tmp/variants_results.json | jq '.'

# Build all variants that need rebuilding (reads /tmp/variants_results.json)

# Sources build-reusable helpers.sh for the full build pipeline
[private]
_build-all-variants:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ helpers_build }}"

    results_file="/tmp/variants_results.json"
    if [[ ! -f "$results_file" ]]; then
        echo "::error::No variant check results found. Run check-variants first." >&2
        exit 1
    fi

    variants=$(jq -c '[.[] | select(.needs_build == true)]' "$results_file")
    count=$(echo "$variants" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo "No variants need building"
        exit 0
    fi

    echo "Building ${count} variant(s)..."

    for ((i = 0; i < count; i++)); do
        variant=$(echo "$variants" | jq -r ".[$i].variant")
        base_image=$(echo "$variants" | jq -r ".[$i].base_image")
        build_script=$(echo "$variants" | jq -r ".[$i].build_script // \"build.sh\"")
        canonical_tag=$(echo "$variants" | jq -r ".[$i].canonical_tag")

        echo ""
        echo "========================================"
        echo "Building variant: ${variant}"
        echo "  Base image    : ${base_image}"
        echo "  Build script  : ${build_script}"
        echo "  Canonical tag : ${canonical_tag}"
        echo "========================================"

        # Full pipeline: build → extract info → assemble labels → rechunk → extract ref
        sudo podman rmi localhost/raw-img 2>/dev/null || true
        build_image "$base_image" "$build_script" "$canonical_tag" "$variant" "./Containerfile"

        manifest_file="/tmp/bazzite-nix-manifest.json"
        labels_file="/tmp/bazzite-nix-labels.txt"
        eval "$(extract_image_info "$manifest_file")"
        assemble_labels \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "{{ image_desc }}" "$variant" "$canonical_tag" \
          "{{ repo_organization }}" "{{ image_name }}" "$KERNEL_VERSION" \
          "$manifest_file" "$labels_file"
        rechunk_image "$labels_file"
        eval "$(extract_final_ref)"

        echo "Variant ${variant} complete: ${SOURCE_REF} (${BUILD_DIGEST})"
    done

[private]
sudoif command *args:
    #!/usr/bin/bash
    function sudoif(){
        if [[ "${UID}" -eq 0 ]]; then
            "$@"
        elif [[ "$(command -v sudo)" && -n "${SSH_ASKPASS:-}" ]] && [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
            /usr/bin/sudo --askpass "$@" || exit 1
        elif [[ "$(command -v sudo)" ]]; then
            /usr/bin/sudo "$@" || exit 1
        else
            exit 1
        fi
    }
    sudoif {{ command }} {{ args }}
