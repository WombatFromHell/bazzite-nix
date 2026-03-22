export repo_organization := env("GITHUB_REPOSITORY_OWNER", "wombatfromhell")
export image_name := env("IMAGE_NAME", "bazzite-nix")
export image_tag := env("IMAGE_TAG", "latest")
export image_build_script := env("IMAGE_BUILD_SCRIPT", "build.sh")
export centos_version := env("CENTOS_VERSION", "stream10")
export fedora_version := env("FEDORA_VERSION", "43")
export default_tag := env("DEFAULT_TAG", "testing")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")
export base_image := env("BASE_IMAGE", "ghcr.io/ublue-os/bazzite:stable")
export cache_dir := env("CACHE_DIR", `echo "$HOME/.cache/bazzite-nix"`)

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
    just --unstable clean-vm

# Clean cached VM disk images
[group('Utility')]
clean-vm:
    #!/usr/bin/env bash
    set -euo pipefail
    VM_CACHE="{{ cache_dir }}"
    if [[ -d "$VM_CACHE" ]]; then
        echo "Removing VM cache from $VM_CACHE..."
        rm -rf "$VM_CACHE"
        echo "VM cache cleaned"
    else
        echo "VM cache does not exist: $VM_CACHE"
    fi

# Run shellcheck on all Bash scripts
[group('Utility')]
lint:
    /usr/bin/find . -iname "*.sh" -type f -exec shellcheck "{}" \;

# Run shfmt on all Bash scripts
[group('Utility')]
format:
    /usr/bin/find . -iname "*.sh" -type f -exec shfmt --write "{}" \;

# Build a container image
# Usage: just build [variant-name | image:tag] [base_image]
# Examples:
#   just build testing
#   just build cachyos

# just build bazzite-nix:mytag ghcr.io/ublue-os/bazzite:testing
[group('Build Container Image')]
build $variant_or_spec="{{ default_tag }}" $base_image_override="":
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just --unstable _resolve-variant "{{ variant_or_spec }}")"
    [[ -n "{{ base_image_override }}" ]] && BASE_IMAGE="{{ base_image_override }}"
    just --unstable _build-rootful "$TARGET_IMAGE" "$TAG" "$VARIANT_NAME" "$BASE_IMAGE" "$BUILD_SCRIPT" "0" "0" "0"

# Force-rebuild a container image, evicting any cached local image first

# Usage: just rebuild [variant-name | image:tag] [base_image_override]
[group('Build Container Image')]
rebuild $variant_or_spec="{{ default_tag }}" $base_image_override="":
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just --unstable _resolve-variant "{{ variant_or_spec }}")"
    [[ -n "{{ base_image_override }}" ]] && BASE_IMAGE="{{ base_image_override }}"
    sudo podman rmi "${TARGET_IMAGE}:${TAG}" 2>/dev/null || true
    just --unstable _build-rootful "$TARGET_IMAGE" "$TAG" "$VARIANT_NAME" "$BASE_IMAGE" "$BUILD_SCRIPT" "0" "0" "0"

# List available (non-disabled) variants from variant.json
[group('Utility')]
list-variants:
    #!/usr/bin/env bash
    echo "Available variants:"
    jq -r '.variants[] | select((.disabled // false) == false) | "  \(.name)  →  \(.base_image)  [\(.build_script // "build.sh")]"' \
        ./.github/variants.json

# Build a QCOW2 VM disk image
# Usage: just build-qcow2 [variant-name | image:tag] [output_dir]
# Examples:
#   just build-qcow2 testing

# just build-qcow2 cachyos ~/.cache/my-vms
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

# --- Private helpers --------------------------------------------------------
# Resolve a variant name from variant.json into image_spec/base_image/build_script
# Emits shell variable assignments suitable for eval

# Usage: eval "$(just --unstable _resolve-variant testing)"
[private]
_resolve-variant $variant_or_spec="":
    #!/usr/bin/env bash
    set -euo pipefail
    VARIANT_JSON="./.github/variants.json"
    spec="{{ variant_or_spec }}"

    # If it looks like an explicit image:tag or image ref, pass it through unchanged
    if [[ "$spec" == *"/"* ]] || [[ "$spec" == *":"* ]]; then
        tag="${spec##*:}"
        # Use image_name as the local target for consistency with named-variant resolution
        build_script=$(jq -r --arg bi "$spec" '
            .variants[] | select(.base_image == $bi and (.disabled // false) == false)
            | (.build_script // "build.sh")
        ' "$VARIANT_JSON" | head -1)
        [[ -z "$build_script" ]] && build_script="build.sh"
        echo "TARGET_IMAGE=\"localhost/{{ image_name }}\""
        echo "TAG=\"$tag\""
        echo "BASE_IMAGE=\"$spec\""
        echo "BUILD_SCRIPT=\"$build_script\""
        echo "VARIANT_NAME=\"$tag\""
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
    tag="${base_image##*:}"   # e.g. "testing", "stable"

    echo "TARGET_IMAGE=\"localhost/${image_name_resolved}\""
    echo "TAG=\"${tag}\""
    echo "BASE_IMAGE=\"${base_image}\""
    echo "BUILD_SCRIPT=\"${build_script}\""
    echo "VARIANT_NAME=\"${spec}\""

# Build VM image (shared helper for build-qcow2 and build-raw)
[private]
_build-vm-image $image_spec $type $output_dir="" $force_rebuild="0":
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just --unstable _resolve-variant "{{ image_spec }}")"
    if [[ "{{ force_rebuild }}" == "1" ]]; then
        echo "Force rebuilding container image..."
        sudo podman rmi "${TARGET_IMAGE}:${TAG}" 2>/dev/null || true
        just --unstable _build-rootful "$TARGET_IMAGE" "$TAG" "$VARIANT_NAME" "$BASE_IMAGE" "$BUILD_SCRIPT" "0" "0" "0"
    else
        if sudo podman image exists "${TARGET_IMAGE}:${TAG}" 2>/dev/null; then
            echo "Container image ${TARGET_IMAGE}:${TAG} already exists, skipping build"
        else
            just --unstable _build-rootful "$TARGET_IMAGE" "$TAG" "$VARIANT_NAME" "$BASE_IMAGE" "$BUILD_SCRIPT" "0" "0" "0"
        fi
    fi
    just --unstable _build-bib "$TARGET_IMAGE" "$TAG" "$type" "image.toml" "{{ output_dir }}"

[private]
_build-rootful $target_image $tag $variant $base_image=base_image $build_script=image_build_script $dx="0" $hwe="0" $gdx="0":
    #!/usr/bin/env bash
    set -euo pipefail

    inspect_output=$(skopeo inspect "docker://${base_image}" 2>/dev/null)
    canonical=$(echo "$inspect_output" | jq -r '.Labels["org.opencontainers.image.version"] // empty')
    base_image_tag="${base_image##*:}"

    if [ -z "$canonical" ] || [ "$canonical" = "null" ] || [ "$canonical" = "latest" ]; then
        echo "Warning: Could not extract valid version from ${base_image}, falling back to branch tag"
        canonical="${base_image_tag}"
    fi
    [[ "$canonical" == "${base_image_tag}-"* ]] && canonical="${canonical#"${base_image_tag}"-}"

    echo "Variant: ${variant}, Canonical tag: ${canonical}"

    sudo podman build \
        --build-arg MAJOR_VERSION="{{ centos_version }}" \
        --build-arg IMAGE_NAME="${target_image}" \
        --build-arg IMAGE_VENDOR="{{ repo_organization }}" \
        --build-arg ENABLE_DX="${dx}" \
        --build-arg ENABLE_HWE="${hwe}" \
        --build-arg ENABLE_GDX="${gdx}" \
        --build-arg BASE_IMAGE="${base_image}" \
        --build-arg BUILD_SCRIPT="${build_script}" \
        --build-arg VARIANT="${variant}" \
        --build-arg CANONICAL_TAG="${canonical}" \
        $( [[ -z "$(git status -s)" ]] && echo "--build-arg SHA_HEAD_SHORT=$(git rev-parse --short HEAD)" ) \
        --pull=newer \
        --security-opt label=disable \
        --tag "${target_image}:${tag}" \
        --tag "${target_image}:${canonical}" \
        .

# Rechunk a built image to OCI layout with bootc chunking
# Usage: just rechunk [variant-name | image:tag]

# Example: just rechunk testing
[group('Build Container Image')]
rechunk $variant_or_spec="{{ default_tag }}":
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just --unstable _resolve-variant "{{ variant_or_spec }}")"
    just --unstable _rechunk "$TARGET_IMAGE" "$TAG" "$VARIANT_NAME"

[private]
_rechunk $target_image $tag $variant:
    #!/usr/bin/env bash
    set -euo pipefail

    # Assemble image labels (mirrors .github/actions/build-reusable/action.yml)
    KERNEL_VERSION=$(sudo podman run --rm --privileged \
        --security-opt label=disable \
        "${target_image}:${tag}" \
        cat /usr/share/ublue-os/kernel-version
    )

    LABELS=(
        "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        "org.opencontainers.image.description=${variant}"
        "org.opencontainers.image.documentation=https://raw.githubusercontent.com/{{ repo_organization }}/{{ image_name }}/refs/heads/main/README.md"
        "org.opencontainers.image.source=https://github.com/{{ repo_organization }}/{{ image_name }}/blob/main/Containerfile"
        "org.opencontainers.image.title=${variant}"
        "org.opencontainers.image.url=https://github.com/{{ repo_organization }}/{{ image_name }}"
        "org.opencontainers.image.vendor={{ repo_organization }}"
        "org.opencontainers.image.version=${tag}"
        "org.opencontainers.image.kernel-version=${KERNEL_VERSION}"
        "containers.bootc=1"
    )

    # Initialize OCI layout on host
    sudo rm -rf /var/lib/containers/oci
    sudo mkdir -p /var/lib/containers/oci
    echo '{"imageLayoutVersion":"1.0.0"}' | sudo tee /var/lib/containers/oci/oci-layout > /dev/null
    echo '{"schemaVersion":2,"manifests":[]}' | sudo tee /var/lib/containers/oci/index.json > /dev/null

    # Build LABEL_ARGS array
    LABEL_ARGS=()
    for line in "${LABELS[@]}"; do
        [ -n "$line" ] && LABEL_ARGS+=(--label "$line")
    done

    # Run rechunk using centos-bootc image (same as GitHub action)
    sudo podman run --rm --privileged \
        --volume /var/lib/containers:/var/lib/containers \
        quay.io/centos-bootc/centos-bootc:{{ centos_version }} \
        rpm-ostree compose build-chunked-oci \
        --bootc --max-layers 128 --format-version 2 \
        --from "${target_image}:${tag}" \
        --output "oci:/var/lib/containers/oci:${tag}" \
        "${LABEL_ARGS[@]}"

    # Clean up raw image
    sudo podman image exists "${target_image}:${tag}" && \
        sudo podman rmi "${target_image}:${tag}"

    echo "Rechunked image available at: oci:/var/lib/containers/oci:${tag}"

[private]
_build-bib $target_image $tag $type $config $output_dir="":
    #!/usr/bin/env bash
    set -euo pipefail

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

    # bib reads from the mounted /var/lib/containers/storage, need localhost/ prefix
    if [[ "$target_image" == localhost/* ]]; then
        source_image="${target_image}:${tag}"
    else
        source_image="localhost/${target_image}:${tag}"
    fi

    # Use provided output_dir or default to cache_dir
    out_dir="${output_dir}"
    if [[ -z "$out_dir" ]]; then
        out_dir="{{ cache_dir }}"
    fi
    mkdir -p "$out_dir"

    # Use cache_dir for bib temp output (avoids cluttering project dir)
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

    # Flatten bib output (bib creates type subdirs like image/, qcow2/, bootiso/)
    for item in "$BUILDTMP"/*; do
        if [[ -d "$item" ]]; then
            # Move contents of subdirectory up one level
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

    # Disk images are flattened to output dir root (bib subdirs are flattened)
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

        if [[ "$is_local" == "true" ]]; then
            if ! sudo podman image exists "${target_image}:${tag}" 2>/dev/null; then
                echo "Image ${target_image}:${tag} not found in rootful storage."
                echo "   Build it first with: just build-${type} ${target_image}:${tag}"
                exit 1
            fi
        else
            if [[ "{{ force_pull }}" == "1" ]] || ! sudo podman image exists "${target_image}:${tag}" 2>/dev/null; then
                echo "Pulling ${target_image}:${tag}..."
                sudo podman pull "${target_image}:${tag}"
            fi
        fi

        # Pull required images
        sudo podman image exists "${bib_image}" 2>/dev/null || sudo podman pull "${bib_image}"
        sudo podman image exists "docker.io/qemux/qemu:latest" 2>/dev/null || sudo podman pull "docker.io/qemux/qemu:latest"

        echo "Building disk image..."
        just --unstable _build-bib "$target_image" "$tag" "$type" "$config" "$OUTPUT_DIR"
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
    for i in {1..30}; do  # Increased to 30 attempts (60 seconds)
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
