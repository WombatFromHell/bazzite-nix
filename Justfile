export repo_organization := env("GITHUB_REPOSITORY_OWNER", "wombatfromhell")
export image_name := env("IMAGE_NAME", "bazzite-nix")
export image_tag := env("IMAGE_TAG", "latest")
export image_build_script := env("IMAGE_BUILD_SCRIPT", "build.sh")
export centos_version := env("CENTOS_VERSION", "stream10")
export fedora_version := env("FEDORA_VERSION", "43")
export default_tag := env("DEFAULT_TAG", "testing")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")
export base_image := env("BASE_IMAGE", "ghcr.io/ublue-os/bazzite:stable")
export cache_dir := env("CACHE_DIR", "${HOME}/.cache/bazzite-nix")

alias build-vm := build-qcow2
alias rebuild-vm := rebuild-qcow2
alias run-vm := run-vm-qcow2

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
    #!/usr/bin/bash
    set -eoux pipefail
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
# Usage: just build [image:tag] [base_image] [dx] [hwe] [gdx]

# Example: just build bazzite-nix:testing ghcr.io/ublue-os/bazzite:testing build.sh
build $image_spec="{{ image_name }}:{{ image_tag }}" $base_image=base_image $build_script=image_build_script $variant="" $dx="0" $hwe="0" $gdx="0":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "$image_spec" == *":"* ]]; then
        target_image="${image_spec%:*}"
        tag="${image_spec#*:}"
    else
        target_image="{{ image_name }}"
        tag="{{ image_tag }}"
    fi
    base_image="{{ base_image }}"
    # Use explicit variant if provided, otherwise inherit from base image tag
    if [[ -n "{{ variant }}" ]]; then
        variant="{{ variant }}"
    else
        variant="${base_image##*:}"
    fi
    just --unstable _build-rootful "$target_image" "$tag" "$variant" "$base_image" "$build_script" "$dx" "$hwe" "$gdx"

build-stable:
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable build "bazzite-nix:stable" "ghcr.io/ublue-os/bazzite:stable"

build-testing:
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable build "bazzite-nix:testing" "ghcr.io/ublue-os/bazzite:testing"

build-cachyos:
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable build "bazzite-nix-cachyos:latest" "ghcr.io/ublue-os/bazzite:testing" "build-cachyos.sh" "cachyos"

# Build and rechunk a container image

# Usage: just rebuild [image:tag] [base_image] [dx] [hwe] [gdx] [skip_rechunk]
rebuild $image_spec="{{ image_name }}:{{ image_tag }}" $base_image=base_image $dx="0" $hwe="0" $gdx="0" $skip_rechunk="0":
    just --unstable build "{{ image_spec }}" "{{ base_image }}" "{{ dx }}" "{{ hwe }}" "{{ gdx }}"
    just --unstable rechunk "{{ image_spec }}" "{{ skip_rechunk }}"

# Rechunk a container image for optimized layer distribution

# Usage: just rechunk [image:tag] [skip]
rechunk $image_spec="{{ image_name }}:{{ image_tag }}" $skip="0":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "$image_spec" == *":"* ]]; then
        target_image="${image_spec%:*}"
        tag="${image_spec#*:}"
    else
        target_image="{{ image_name }}"
        tag="{{ image_tag }}"
    fi
    if [[ "$skip" == "1" ]]; then
        echo "Skipping rechunk step"
        exit 0
    fi
    just --unstable _rechunk "$target_image" "$tag"

# Rechunk a container image for optimized layer distribution (private helper)
[private]
_rechunk $target_image $tag:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Rechunking image ${target_image}:${tag}..."
    if ! sudo podman image exists "${target_image}:${tag}" 2>/dev/null; then
        echo "Image ${target_image}:${tag} not found in rootful storage"
        echo "   Build it first with: just build ${target_image}:${tag}"
        exit 1
    fi
    echo "Creating intermediate image for rechunking..."
    sudo podman tag "${target_image}:${tag}" localhost/raw-img
    container=$(sudo buildah from localhost/raw-img)
    sudo buildah config --label "-" "$container"
    sudo buildah commit --identity-label=false --rm "$container" localhost/raw-img
    echo "Running rechunker with max-layers 96..."
    sudo podman run --rm --privileged \
        --volume /var/lib/containers:/var/lib/containers \
        quay.io/centos-bootc/centos-bootc:{{ centos_version }} \
        rpm-ostree compose build-chunked-oci \
        --bootc --max-layers 96 --format-version 2 \
        --from localhost/raw-img \
        --output containers-storage:localhost/chunked-img
    echo "Cleaning up intermediate image..."
    sudo podman untag localhost/raw-img && sudo podman rmi localhost/raw-img
    echo "Tagging rechunked image as ${target_image}:${tag}..."
    sudo podman tag localhost/chunked-img "${target_image}:${tag}"
    echo "Rechunk complete: ${target_image}:${tag}"

# Build a QCOW2 VM image

# Usage: just build-qcow2 [image:tag] [base_image] [build_script] [variant] [output_dir]
[group('Build Virtual Machine Image')]
build-qcow2 $image_spec="" $base_image=base_image $build_script=image_build_script $variant="" $output_dir="":
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable _build-vm-image "{{ image_spec }}" "qcow2" "{{ output_dir }}" "{{ variant }}" "{{ base_image }}" "{{ build_script }}" "0"

# Build QCOW2 VM image from bazzite-nix-cachyos:latest
[group('Build Virtual Machine Image')]
build-qcow2-cachyos:
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable build-qcow2 "bazzite-nix-cachyos:latest" "ghcr.io/ublue-os/bazzite:testing" "build-cachyos.sh" "cachyos"

# Build QCOW2 VM image from bazzite-nix:testing
[group('Build Virtual Machine Image')]
build-qcow2-testing:
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable build-qcow2 "bazzite-nix:testing" "ghcr.io/ublue-os/bazzite:testing"

# Build a RAW VM image

# Usage: just build-raw [image:tag] [base_image] [build_script] [variant] [output_dir]
[group('Build Virtual Machine Image')]
build-raw $image_spec="" $base_image=base_image $build_script=image_build_script $variant="" $output_dir="":
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable _build-vm-image "{{ image_spec }}" "raw" "{{ output_dir }}" "{{ variant }}" "{{ base_image }}" "{{ build_script }}" "0"

# Aliases for build-qcow2 / build-raw (force rebuild container image)
[group('Build Virtual Machine Image')]
rebuild-qcow2 $image_spec="" $base_image=base_image $build_script=image_build_script $variant="" $output_dir="":
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable _build-vm-image "{{ image_spec }}" "qcow2" "{{ output_dir }}" "{{ variant }}" "{{ base_image }}" "{{ build_script }}" "1"

[group('Build Virtual Machine Image')]
rebuild-raw $image_spec="" $base_image=base_image $build_script=image_build_script $variant="" $output_dir="":
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable _build-vm-image "{{ image_spec }}" "raw" "{{ output_dir }}" "{{ variant }}" "{{ base_image }}" "{{ build_script }}" "1"

# Rebuild QCOW2 VM image from bazzite-nix-cachyos:latest
[group('Build Virtual Machine Image')]
rebuild-qcow2-cachyos:
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable rebuild-qcow2 "bazzite-nix-cachyos:latest" "ghcr.io/ublue-os/bazzite:testing" "build-cachyos.sh" "cachyos"

# Rebuild QCOW2 VM image from bazzite-nix:testing
[group('Build Virtual Machine Image')]
rebuild-qcow2-testing:
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable rebuild-qcow2 "bazzite-nix:testing" "ghcr.io/ublue-os/bazzite:testing"

# Rebuild RAW VM image from bazzite-nix-cachyos:latest
[group('Build Virtual Machine Image')]
rebuild-raw-cachyos:
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable rebuild-raw "bazzite-nix-cachyos:latest" "ghcr.io/ublue-os/bazzite:testing" "build-cachyos.sh" "cachyos"

# Rebuild RAW VM image from bazzite-nix:testing
[group('Build Virtual Machine Image')]
rebuild-raw-testing:
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable rebuild-raw "bazzite-nix:testing" "ghcr.io/ublue-os/bazzite:testing"

# Build RAW VM image from bazzite-nix-cachyos:latest
[group('Build Virtual Machine Image')]
build-raw-cachyos:
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable build-raw "bazzite-nix-cachyos:latest" "ghcr.io/ublue-os/bazzite:testing" "build-cachyos.sh" "cachyos"

# Build RAW VM image from bazzite-nix:testing
[group('Build Virtual Machine Image')]
build-raw-testing:
    #!/usr/bin/env bash
    set -euo pipefail
    just --unstable build-raw "bazzite-nix:testing" "ghcr.io/ublue-os/bazzite:testing"

# Run a QCOW2 VM

# Usage: just run-vm-qcow2 [image:tag] [output_dir] [force_pull] [clean]
[group('Run Virtual Machine')]
run-vm-qcow2 $image_spec="" $output_dir="" $force_pull="0" $clean="0":
    just --unstable _run-vm-wrapper "{{ image_spec }}" "qcow2" "{{ output_dir }}" "{{ force_pull }}" "{{ clean }}"

# Run a RAW VM

# Usage: just run-vm-raw [image:tag] [output_dir] [force_pull] [clean]
[group('Run Virtual Machine')]
run-vm-raw $image_spec="" $output_dir="" $force_pull="0" $clean="0":
    just --unstable _run-vm-wrapper "{{ image_spec }}" "raw" "{{ output_dir }}" "{{ force_pull }}" "{{ clean }}"

# --- Private helpers --------------------------------------------------------

# Run VM wrapper (shared helper for run-vm-qcow2 and run-vm-raw)
[private]
_run-vm-wrapper $image_spec $type $output_dir $force_pull $clean:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just --unstable _parse-image-spec-vm "{{ image_spec }}")"
    just --unstable _run-vm "$TARGET_IMAGE" "$TAG" "$type" "image.toml" "{{ output_dir }}" "{{ force_pull }}" "{{ clean }}"

# Build VM image (shared helper for build-qcow2 and build-raw)
[private]
_build-vm-image $image_spec $type $output_dir="" $variant="" $base_image=base_image $build_script=image_build_script $force_rebuild="0":
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just --unstable _parse-image-spec-vm "{{ image_spec }}")"
    if [[ -z "{{ variant }}" ]]; then
        variant="${TAG}"
    fi
    if [[ "{{ force_rebuild }}" == "1" ]]; then
        echo "Force rebuilding container image..."
        sudo podman rmi "${TARGET_IMAGE}:${TAG}" 2>/dev/null || true
        just --unstable _build-rootful "$TARGET_IMAGE" "$TAG" "$variant" "{{ base_image }}" "{{ build_script }}" "0" "0" "0"
    else
        if sudo podman image exists "${TARGET_IMAGE}:${TAG}" 2>/dev/null; then
            echo "Container image ${TARGET_IMAGE}:${TAG} already exists, skipping build"
        else
            just --unstable _build-rootful "$TARGET_IMAGE" "$TAG" "$variant" "{{ base_image }}" "{{ build_script }}" "0" "0" "0"
        fi
    fi
    just --unstable _build-bib "$TARGET_IMAGE" "$TAG" "$type" "image.toml" "{{ output_dir }}"

# Parse image_spec into TARGET_IMAGE and TAG

# $1 = image_spec, $2 = prefix (localhost or ghcr.io/{{ repo_organization }})
[private]
_parse-image-spec $image_spec="" $prefix="localhost/{{ image_name }}":
    #!/usr/bin/env bash
    set -euo pipefail
    image_spec="{{ image_spec }}"
    prefix="{{ prefix }}"
    default_target="${prefix}"
    default_tag="{{ default_tag }}"
    if [[ -n "$image_spec" ]]; then
        if [[ "$image_spec" == *":"* ]]; then
            target_image="${image_spec%:*}"
            tag="${image_spec#*:}"
        else
            target_image="$image_spec"
            tag="$default_tag"
        fi
        [[ "$target_image" != *"/"* ]] && target_image="${prefix%/*}/${target_image}"
    else
        target_image="$default_target"
        tag="$default_tag"
    fi
    echo "TARGET_IMAGE=\"$target_image\""
    echo "TAG=\"$tag\""

# Parse image_spec into TARGET_IMAGE and TAG for local (localhost/) images

# Deprecated: use _parse-image-spec with prefix instead
[private]
_parse-image-spec-vm $image_spec="":
    just --unstable _parse-image-spec "{{ image_spec }}" "localhost/{{ image_name }}"

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
    if [[ "$canonical" == "${base_image_tag}-"* ]]; then
        canonical="${canonical#"${base_image_tag}"-}"
    fi

    echo "Variant: ${variant}, Canonical tag: ${canonical}"

    BUILD_ARGS=()
    BUILD_ARGS+=("--build-arg" "MAJOR_VERSION={{ centos_version }}")
    BUILD_ARGS+=("--build-arg" "IMAGE_NAME=${target_image}")
    BUILD_ARGS+=("--build-arg" "IMAGE_VENDOR={{ repo_organization }}")
    BUILD_ARGS+=("--build-arg" "ENABLE_DX=${dx}")
    BUILD_ARGS+=("--build-arg" "ENABLE_HWE=${hwe}")
    BUILD_ARGS+=("--build-arg" "ENABLE_GDX=${gdx}")
    BUILD_ARGS+=("--build-arg" "BASE_IMAGE=${base_image}")
    BUILD_ARGS+=("--build-arg" "BUILD_SCRIPT=${build_script}")
    BUILD_ARGS+=("--build-arg" "VARIANT=${variant}")
    BUILD_ARGS+=("--build-arg" "CANONICAL_TAG=${canonical}")
    if [[ -z "$(git status -s)" ]]; then
        BUILD_ARGS+=("--build-arg" "SHA_HEAD_SHORT=$(git rev-parse --short HEAD)")
    fi

    sudo podman build \
        "${BUILD_ARGS[@]}" \
        --pull=newer \
        --security-opt label=disable \
        --tag "${target_image}:${tag}" \
        --tag "${target_image}:${canonical}" \
        .

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
    set -e

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
                echo "   Build it first with: just build-{{ type }} ${target_image}:${tag}"
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
