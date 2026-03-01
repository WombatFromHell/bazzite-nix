export repo_organization := env("GITHUB_REPOSITORY_OWNER", "wombatfromhell")
export image_name := env("IMAGE_NAME", "bazzite-nix")
export image_tag := env("IMAGE_TAG", "latest")
export image_build_script := env("IMAGE_BUILD_SCRIPT", "build.sh")
export centos_version := env("CENTOS_VERSION", "stream10")
export fedora_version := env("CENTOS_VERSION", "43")
export default_tag := env("DEFAULT_TAG", "testing")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")
export base_image := env("BASE_IMAGE", "ghcr.io/ublue-os/bazzite:stable")

alias build-vm := build-qcow2
alias rebuild-vm := rebuild-qcow2
alias run-vm := run-vm-qcow2

[private]
default:
    @just --list

# Check Just Syntax
[group('Just')]
check:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt --check -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Fix Just Syntax
[group('Just')]
fix:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt -f Justfile || { exit 1; }

# Clean Repo
[group('Utility')]
clean:
    #!/usr/bin/bash
    set -eoux pipefail
    touch _build
    find *_build* -exec rm -rf {} \;
    rm -f previous.manifest.json
    rm -f changelog.md
    rm -f output.env
    rm -f output/

# Sudo Clean Repo
[group('Utility')]
[private]
sudo-clean:
    just sudoif just clean

# sudoif bash function
[group('Utility')]
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

# This Justfile recipe builds a container image using Podman.
#
# Arguments:
#   $target_image - The tag you want to apply to the image (default: aurora).
#   $tag - The tag for the image (default: lts).
#   $dx - Enable DX (default: "0").
#   $hwe - Enable HWE (default: "0").
#   $gdx - Enable GDX (default: "0").
#
# DX:
#   Developer Experience (DX) is a feature that allows you to install the latest developer tools for your system.
#   Packages include VScode, Docker, Distrobox, and more.
# HWE:
#   Hardware Enablement (HWE) is a feature that allows you to install the latest hardware support for your system.
#   Currently this install the Hyperscale SIG kernel which will stay ahead of the CentOS Stream kernel and enables btrfs
# GDX: https://docs.projectaurora.io/gdx/
#   GPU Developer Experience (GDX) creates a base as an AI and Graphics platform.
#   Installs Nvidia drivers, CUDA, and other tools.
#
# The script constructs the version string using the tag and the current date.
# If the git working directory is clean, it also includes the short SHA of the current HEAD.
#
# just build $target_image $tag $dx $hwe $gdx
#
# Example usage:
#   just build aurora lts 1 0 1
#
# This will build an image 'aurora:lts' with DX and GDX enabled.
#
# Build the image using the specified parameters
# Usage: just build [image:tag] (e.g., just build bazzite-nix-cachyos:latest)
#
# Builds directly in rootful podman storage to avoid copying image layers.
#
# Defaults can be overridden via environment variables: IMAGE_NAME, IMAGE_TAG, IMAGE_BUILD_SCRIPT

build $image_spec="{{ image_name }}:{{ image_tag }}" $build_script=image_build_script $base_image=base_image $dx="0" $hwe="0" $gdx="0":
    #!/usr/bin/env bash
    set -euo pipefail

    # Parse image_spec into target_image and tag
    image_spec_val="{{ image_spec }}"
    default_target_val="{{ image_name }}"
    default_tag_val="{{ image_tag }}"
    if [[ -n "$image_spec_val" ]]; then
        if [[ "$image_spec_val" == *":"* ]]; then
            target_image="${image_spec_val%:*}"
            tag="${image_spec_val#*:}"
        else
            target_image="${image_spec_val}"
            tag="${default_tag_val}"
        fi
    else
        target_image="${default_target_val}"
        tag="${default_tag_val}"
    fi

    # Get Version
    ver="${tag}-${centos_version}.$(date +%Y%m%d)"

    BUILD_ARGS=()
    BUILD_ARGS+=("--build-arg" "MAJOR_VERSION=${centos_version}")
    BUILD_ARGS+=("--build-arg" "IMAGE_NAME=${target_image}")
    BUILD_ARGS+=("--build-arg" "IMAGE_VENDOR=${repo_organization}")
    BUILD_ARGS+=("--build-arg" "ENABLE_DX=${dx}")
    BUILD_ARGS+=("--build-arg" "ENABLE_HWE=${hwe}")
    BUILD_ARGS+=("--build-arg" "ENABLE_GDX=${gdx}")
    BUILD_ARGS+=("--build-arg" "BASE_IMAGE=${base_image}")
    BUILD_ARGS+=("--build-arg" "BUILD_SCRIPT=${build_script}")
    if [[ -z "$(git status -s)" ]]; then
        BUILD_ARGS+=("--build-arg" "SHA_HEAD_SHORT=$(git rev-parse --short HEAD)")
    fi

    sudo podman build \
        "${BUILD_ARGS[@]}" \
        --pull=newer \
        --security-opt label=disable \
        --tag "${target_image}:${tag}" \
        .

build-stable:
    just --unstable build "bazzite-nix:stable" "build.sh" "ghcr.io/ublue-os/bazzite:stable"

build-testing:
    just --unstable build "bazzite-nix:testing" "build.sh" "ghcr.io/ublue-os/bazzite:testing"

build-cachyos:
    just --unstable build "bazzite-nix-cachyos:latest" "build-cachyos.sh" "ghcr.io/ublue-os/bazzite:testing"

# Rechunk a container image using centos-bootc for optimized layer distribution.
# This matches the GitHub Actions rechunk workflow for local builds.
#
# Arguments:
#   $target_image - The tag you want to apply to the image (default: aurora).
#   $tag - The tag for the image (default: lts).
#   $skip - Skip rechunk step (default: "0").
#
# Usage: just rechunk [image:tag] [skip]
#
# Example usage:
#   just rechunk bazzite-nix:testing
#   just rechunk bazzite-nix:testing 1  # skip rechunk
#
# Defaults can be overridden via environment variables: IMAGE_NAME, IMAGE_TAG

rechunk $image_spec="{{ image_name }}:{{ image_tag }}" $skip="0":
    #!/usr/bin/env bash
    set -euo pipefail

    # Parse image_spec into target_image and tag
    image_spec_val="{{ image_spec }}"
    default_target_val="{{ image_name }}"
    default_tag_val="{{ image_tag }}"
    if [[ -n "$image_spec_val" ]]; then
        if [[ "$image_spec_val" == *":"* ]]; then
            target_image="${image_spec_val%:*}"
            tag="${image_spec_val#*:}"
        else
            target_image="${image_spec_val}"
            tag="${default_tag_val}"
        fi
    else
        target_image="${default_target_val}"
        tag="${default_tag_val}"
    fi

    if [[ "$skip" == "1" ]]; then
        echo "⏭️  Skipping rechunk step"
        exit 0
    fi

    echo "🔄 Rechunking image ${target_image}:${tag}..."

    # Ensure image exists in rootful storage
    if ! sudo podman image exists "${target_image}:${tag}" 2>/dev/null; then
        echo "❌ Image ${target_image}:${tag} not found in rootful storage"
        echo "   Build it first with: just build ${image_spec}"
        exit 1
    fi

    # Create intermediate raw-img tag for rechunking
    echo "Creating intermediate image for rechunking..."
    sudo podman tag "${target_image}:${tag}" localhost/raw-img

    # Clear labels to avoid duplication during rechunk
    echo "Clearing existing labels..."
    container=$(sudo buildah from localhost/raw-img)
    sudo buildah config --label "-" "$container"
    sudo buildah commit --identity-label=false --rm "$container" localhost/raw-img

    # Run rechunker using centos-bootc
    echo "Running centos-bootc rechunker with max-layers 96..."
    sudo podman run --rm --privileged --volume /var/lib/containers:/var/lib/containers \
        quay.io/centos-bootc/centos-bootc:{{ centos_version }} \
        rpm-ostree compose build-chunked-oci \
        --bootc --max-layers 96 --format-version 2 \
        --from localhost/raw-img --output containers-storage:localhost/chunked-img

    # Clean up intermediate image
    echo "Cleaning up intermediate image..."
    sudo podman untag localhost/raw-img && sudo podman rmi localhost/raw-img

    # Re-tag the rechunked image
    echo "Tagging rechunked image as ${target_image}:${tag}..."
    sudo podman tag localhost/chunked-img "${target_image}:${tag}"

    echo "✅ Rechunk complete: ${target_image}:${tag}"

# Build and rechunk a container image in one step.
# Combines the build and rechunk targets for convenience.
#
# Arguments:
#   $target_image - The tag you want to apply to the image (default: aurora).
#   $tag - The tag for the image (default: lts).
#   $dx - Enable DX (default: "0").
#   $hwe - Enable HWE (default: "0").
#   $gdx - Enable GDX (default: "0").
#   $skip_rechunk - Skip rechunk step (default: "0").
#
# Usage: just rebuild [image:tag] [tag] [dx] [hwe] [gdx] [skip_rechunk]
#
# Example usage:
#   just rebuild bazzite-nix:testing
#   just rebuild bazzite-nix:testing testing 0 0 0 1  # skip rechunk
#
# Defaults can be overridden via environment variables: IMAGE_NAME, IMAGE_TAG, IMAGE_BUILD_SCRIPT

rebuild $image_spec="{{ image_name }}:{{ image_tag }}" $tag="" $dx="0" $hwe="0" $gdx="0" $skip_rechunk="0":
    #!/usr/bin/env bash
    set -euo pipefail

    # Parse image_spec into target_image and tag
    image_spec_val="{{ image_spec }}"
    default_target_val="{{ image_name }}"
    default_tag_val="{{ image_tag }}"
    if [[ -n "$image_spec_val" ]]; then
        if [[ "$image_spec_val" == *":"* ]]; then
            target_image="${image_spec_val%:*}"
            tag="${image_spec_val#*:}"
        else
            target_image="${image_spec_val}"
            tag="${default_tag_val}"
        fi
    else
        target_image="${default_target_val}"
        tag="${default_tag_val}"
    fi

    # Override tag if explicitly provided
    if [[ -n "{{ tag }}" ]]; then
        tag="{{ tag }}"
    fi

    # Build the image first
    just --unstable build "{{ image_spec }}" "{{ tag }}" "{{ dx }}" "{{ hwe }}" "{{ gdx }}"

    # Then rechunk (unless skipped)
    just --unstable rechunk "${target_image}:${tag}" "{{ skip_rechunk }}"

# Build a container image directly in rootful podman storage.
# This avoids the need to copy images from user to rootful storage.
# Used by build-qcow2, build-raw, build-iso for BIB compatibility.
#
# Parameters:
#   $target_image - The name of the target image (ex. localhost/bazzite-nix)
#   $tag - The tag of the image (ex. testing)
#   $base_image - The base image to build from (default: ghcr.io/ublue-os/bazzite:stable)

_build-rootful $target_image $tag $base_image=base_image:
    #!/usr/bin/env bash
    set -euo pipefail

    BUILD_ARGS=()
    BUILD_ARGS+=("--build-arg" "MAJOR_VERSION={{ centos_version }}")
    BUILD_ARGS+=("--build-arg" "IMAGE_NAME={{ image_name }}")
    BUILD_ARGS+=("--build-arg" "IMAGE_VENDOR={{ repo_organization }}")
    BUILD_ARGS+=("--build-arg" "ENABLE_DX=0")
    BUILD_ARGS+=("--build-arg" "ENABLE_HWE=0")
    BUILD_ARGS+=("--build-arg" "ENABLE_GDX=0")
    BUILD_ARGS+=("--build-arg" "BASE_IMAGE=${base_image}")
    BUILD_ARGS+=("--build-arg" "BUILD_SCRIPT=build.sh")
    if [[ -z "$(git status -s)" ]]; then
        BUILD_ARGS+=("--build-arg" "SHA_HEAD_SHORT=$(git rev-parse --short HEAD)")
    fi

    sudo podman build \
        "${BUILD_ARGS[@]}" \
        --pull=newer \
        --security-opt label=disable \
        --tag "${target_image}:${tag}" \
        .

# Build a bootc bootable image using Bootc Image Builder (BIB)
# Converts a container image to a bootable image
# Assumes the source image exists in rootful podman storage.
#
# Parameters:
#   target_image: The name of the image to build (ex. localhost/fedora)
#   tag: The tag of the image to build (ex. latest)
#   type: The type of image to build (ex. qcow2, raw, iso)
#   config: The configuration file to use for the build (default: image.toml)

# Example: just _rebuild-bib localhost/fedora latest qcow2 image.toml
_build-bib $target_image $tag $type $config:
    #!/usr/bin/env bash
    set -euo pipefail

    # Ensure image exists in rootful storage
    if ! sudo podman image exists "${target_image}:${tag}" 2>/dev/null; then
        echo "Image ${target_image}:${tag} not found in rootful storage."
        echo "Checking rootless storage..."
        if podman image exists "${target_image}:${tag}" 2>/dev/null; then
            echo "Found in rootless storage, copying to rootful..."
            podman save "${target_image}:${tag}" | sudo podman load
        else
            echo "Image not found in rootless storage either. Pulling..."
            sudo podman pull "${target_image}:${tag}"
        fi
    fi

    args="--type ${type} "
    args+="--use-librepo=True "
    args+="--rootfs=btrfs"

    # For container-storage:, strip localhost/ prefix as it causes parsing issues
    # BIB expects: container-storage:imagename:tag (not container-storage:localhost/imagename:tag)
    if [[ "$target_image" == localhost/* ]]; then
        source_image="container-storage:${target_image#localhost/}:${tag}"
    else
        source_image="container-storage:${target_image}:${tag}"
    fi

    BUILDTMP=$(mktemp -p "${PWD}" -d -t _build-bib.XXXXXXXXXX)

    sudo podman run \
      --rm \
      -it \
      --privileged \
      --pull=newer \
      --net=host \
      --security-opt label=type:unconfined_t \
      -v $(pwd)/${config}:/config.toml:ro \
      -v $BUILDTMP:/output \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      "${bib_image}" \
      ${args} \
      "$source_image"

    mkdir -p output
    sudo mv -f $BUILDTMP/* output/
    sudo rmdir $BUILDTMP
    sudo chown -R $USER:$USER output/

# Podman builds the image from the Containerfile and creates a bootable image
# Parameters:
#   target_image: The name of the image to build (ex. localhost/fedora)
#   tag: The tag of the image to build (ex. latest)
#   type: The type of image to build (ex. qcow2, raw, iso)
#   config: The configuration file to use for the build (deafult: image.toml)

# Example: just _rebuild-bib localhost/fedora latest qcow2 image.toml
_rebuild-bib $target_image $tag $type $config:
    #!/usr/bin/env bash
    set -euo pipefail
    just _build-rootful "{{ target_image }}" "{{ tag }}"
    just _build-bib "{{ target_image }}" "{{ tag }}" "{{ type }}" "{{ config }}"

# Build a QCOW2 virtual machine image

# Usage: just build-qcow2 [image:tag] (e.g., just build-qcow2 bazzite-nix-cachyos:latest)
[group('Build Virtual Machine Image')]
build-qcow2 $image_spec="":
    #!/usr/bin/env bash
    set -euo pipefail

    # Parse image_spec into target_image and tag
    image_spec_val="{{ image_spec }}"
    default_target_val="localhost/{{ image_name }}"
    default_tag_val="{{ default_tag }}"
    if [[ -n "$image_spec_val" ]]; then
        if [[ "$image_spec_val" == *":"* ]]; then
            target_image="${image_spec_val%:*}"
            tag="${image_spec_val#*:}"
        else
            target_image="${image_spec_val}"
            tag="${default_tag_val}"
        fi
        # Prepend localhost/ if no registry specified
        if [[ "$target_image" != *"/"* ]]; then
            target_image="localhost/${target_image}"
        fi
    else
        target_image="${default_target_val}"
        tag="${default_tag_val}"
    fi

    just _build-rootful "$target_image" "$tag"
    just _build-bib "$target_image" "$tag" "qcow2" "image.toml"

# Build a RAW virtual machine image

# Usage: just build-raw [image:tag] (e.g., just build-raw bazzite-nix-cachyos:latest)
[group('Build Virtual Machine Image')]
build-raw $image_spec="":
    #!/usr/bin/env bash
    set -euo pipefail

    # Parse image_spec into target_image and tag
    image_spec_val="{{ image_spec }}"
    default_target_val="localhost/{{ image_name }}"
    default_tag_val="{{ default_tag }}"
    if [[ -n "$image_spec_val" ]]; then
        if [[ "$image_spec_val" == *":"* ]]; then
            target_image="${image_spec_val%:*}"
            tag="${image_spec_val#*:}"
        else
            target_image="${image_spec_val}"
            tag="${default_tag_val}"
        fi
        # Prepend localhost/ if no registry specified
        if [[ "$target_image" != *"/"* ]]; then
            target_image="localhost/${target_image}"
        fi
    else
        target_image="${default_target_val}"
        tag="${default_tag_val}"
    fi

    just _build-rootful "$target_image" "$tag"
    just _build-bib "$target_image" "$tag" "raw" "image.toml"

# Build a live ISO using titanoboa (container-native ISO contract)
# This creates a live ISO that boots into an installer session.
#
# Usage: just build-iso-titanoboa [image:tag] (e.g., just build-iso-titanoboa bazzite-nix:testing)
# Examples:
#   just build-iso-titanoboa localhost/bazzite-nix:testing
#   just build-iso-titanoboa bazzite-nix-cachyos:latest
#
# The ISO will be created in ./output/ directory.
#
# Workflow:
#   1. Build the container image in rootful storage
#   2. Build the titanoboa live ISO payload image

# 3. Run titanoboa/main.sh to generate the ISO
[group('Build Virtual Machine Image')]
build-iso $image_spec="":
    just --unstable build-iso-titanoboa "{{ image_spec }}"

# Build a live ISO using titanoboa (container-native ISO contract)
# This creates a live ISO that boots into an installer session.
#
# Usage: just build-iso-titanoboa [image:tag] [base_image]
# Examples:
#   just build-iso-titanoboa bazzite-nix:testing
#   just build-iso-titanoboa bazzite-nix-cachyos:latest ghcr.io/ublue-os/bazzite:testing
#
# If the target image already exists in rootful storage, rebuild is skipped.

# Specify base_image to override the source image when building.
[group('Build Virtual Machine Image')]
build-iso-titanoboa $image_spec="" $base_image="":
    #!/usr/bin/env bash
    set -euxo pipefail

    # Parse image_spec into target_image and tag
    image_spec_val="{{ image_spec }}"
    default_target_val="localhost/{{ image_name }}"
    default_tag_val="{{ default_tag }}"
    if [[ -n "$image_spec_val" ]]; then
        if [[ "$image_spec_val" == *":"* ]]; then
            target_image="${image_spec_val%:*}"
            tag="${image_spec_val#*:}"
        else
            target_image="${image_spec_val}"
            tag="${default_tag_val}"
        fi
        # Prepend localhost/ if no registry specified
        if [[ "$target_image" != *"/"* ]]; then
            target_image="localhost/${target_image}"
        fi
    else
        target_image="${default_target_val}"
        tag="${default_tag_val}"
    fi

    # Check if image already exists in rootful storage
    if sudo podman image exists "${target_image}:${tag}" 2>/dev/null; then
        echo "✅ Image ${target_image}:${tag} already exists in rootful storage"
    else
        echo "🔨 Building base image ${target_image}:${tag}..."
        # Use provided base_image or fall back to default
        if [[ -n "{{ base_image }}" ]]; then
            just --unstable _build-rootful "$target_image" "$tag" "{{ base_image }}"
        else
            just --unstable _build-rootful "$target_image" "$tag"
        fi
    fi

    # Verify image exists in rootful storage
    if ! sudo podman image exists "${target_image}:${tag}"; then
        echo "❌ Image ${target_image}:${tag} not found in rootful storage after build"
        exit 1
    fi
    echo "✅ Found image ${target_image}:${tag} in rootful storage"

    live_image="${target_image}-live:${tag}"

    # Check if live payload image already exists
    if sudo podman image exists "${live_image}" 2>/dev/null; then
        echo "✅ Live payload image ${live_image} already exists, skipping build"
    else
        echo "🔨 Building titanoboa live ISO payload..."
        # Run installer in a container, keep container for commit
        container_name="titanoboa-payload"

        sudo podman run --replace --name "${container_name}" \
            --privileged \
            --cap-add sys_admin \
            --security-opt label=disable \
            -v "$(pwd)/installer:/src:ro" \
            --env BASE_IMAGE="${target_image}:${tag}" \
            --env INSTALL_IMAGE_PAYLOAD="${target_image}:${tag}" \
            "${target_image}:${tag}" \
            /src/build.sh

        # Commit as payload image
        sudo podman commit "${container_name}" "${live_image}"
        sudo podman rm -f "${container_name}" 2>/dev/null || true
    fi

    echo "📀 Generating live ISO with titanoboa..."
    mkdir -p "${HOME}/.cache/bazzite-nix/iso"
    export TITANOBOA_CTR_IMAGE="${live_image}"
    export TITANOBOA_OUTPUT_DIR="${HOME}/.cache/bazzite-nix/iso"
    bash ./installer/main.sh || {
      # Clean up on failure/cancellation
      echo "ISO build cancelled or failed"
      exit 1
    }

    echo "✅ Live ISO created: ${HOME}/.cache/bazzite-nix/iso/*.iso"

# Verify ISO bootability using xorriso (if available)
# Includes checks for:
#   - Bootable flag
#   - UEFI boot entry in El Torito catalog
#   - Required files on ISO 9660 filesystem
#   - EFI partition presence and contents
#   - EFI boot loader (BOOTX64.EFI/BOOTIA32.EFI)
#   - EFI grub.cfg with menu entries
#
# Usage: just verify-iso [iso_path]
# Examples:
#   just verify-iso output/bazzite-nix-Live.iso

# just verify-iso  # uses latest ISO in output/ or ~/.cache/bazzite-nix/iso/
[group('Test')]
verify-iso $iso_path="":
    #!/usr/bin/env bash
    set -euo pipefail

    if [[ -n "{{ iso_path }}" ]]; then
        iso_file="{{ iso_path }}"
    else
        iso_file=$(find output -name "*.iso" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
        if [[ -z "$iso_file" ]]; then
            cache_iso_dir="$HOME/.cache/bazzite-nix/iso"
            if [[ -d "$cache_iso_dir" ]]; then
                iso_file=$(find "$cache_iso_dir" -name "*.iso" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
            fi
        fi
        if [[ -z "$iso_file" ]]; then
            echo "❌ No ISO found in output/ or ~/.cache/bazzite-nix/iso/"
            exit 1
        fi
    fi

    if [[ ! -f "$iso_file" ]]; then
        echo "❌ ISO not found: $iso_file"
        exit 1
    fi

    # Check required tools
    missing_tools=()
    command -v xorriso &>/dev/null || missing_tools+=("xorriso")
    command -v isoinfo &>/dev/null || missing_tools+=("isoinfo")
    command -v file &>/dev/null || missing_tools+=("file")

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo "❌ Missing required tools: ${missing_tools[*]}"
        echo "   Install with: sudo dnf install libisoburn p7zip file"
        exit 1
    fi

    echo "🧪 Verifying ISO: $iso_file"
    echo ""

    # Check bootability
    echo "=== Bootable Check ==="
    if file "$iso_file" | grep -q "bootable"; then
        echo "✅ ISO is bootable"
    else
        echo "❌ ISO is NOT bootable"
        exit 1
    fi
    echo ""

    # El Torito boot info
    echo "=== El Torito Boot Record ==="
    el_torito_output=$(xorriso -indev "$iso_file" -report_el_torito 2>&1)
    echo "$el_torito_output" | grep -E "(El Torito|Boot record|Boot media)" || true
    echo ""

    # Check for UEFI boot entry
    echo "=== UEFI Boot Check ==="
    if echo "$el_torito_output" | grep -qi "UEFI"; then
        echo "✅ UEFI boot entry found"
    else
        echo "❌ UEFI boot entry NOT found"
        exit 1
    fi
    echo ""

    # Required files on ISO filesystem (Rock Ridge preserves case)
    files=(
      "/images/pxeboot/vmlinuz"
      "/images/pxeboot/initrd.img"
      "/liveos/squashfs.img"
      "/boot/grub2/grub.cfg"
    )
    echo "=== Required Files (ISO 9660/Rock Ridge) ==="
    for path in "${files[@]}"; do
      if isoinfo -f -i "$iso_file" 2>/dev/null | grep -qi "^${path}"; then
          echo "✅ ${path}"
      else
          echo "❌ ${path} (MISSING)"
          exit 1
      fi
    done
    echo ""

    # Extract and verify EFI partition
    echo "=== EFI Partition Check ==="

    # Use cache directory for temp files to avoid tmpfs/quota issues
    cache_work_dir="${HOME}/.cache/bazzite-nix/iso/.verify-work"
    mkdir -p "$cache_work_dir"
    trap "rm -rf '$cache_work_dir'" EXIT

    efi_start=$(fdisk -l "$iso_file" 2>/dev/null | grep -E "EFI System|efi" | awk '{print $2}' | head -1)
    if [[ -n "$efi_start" ]]; then
        echo "✅ EFI partition found (start sector: $efi_start)"

        efi_img="$cache_work_dir/efi-part.img"
        efi_mount="$cache_work_dir/efi-mount"
        mkdir -p "$efi_mount"

        sector_size=512
        efi_size=$(fdisk -l "$iso_file" 2>/dev/null | grep -E "EFI System|efi" | awk '{print $4}' | head -1)

        dd if="$iso_file" of="$efi_img" bs="$sector_size" skip="$efi_start" count="$efi_size" 2>/dev/null

        # Mount and check EFI partition contents
        if sudo mount -o loop "$efi_img" "$efi_mount" 2>/dev/null; then
            echo "✅ EFI partition mounted successfully"

            # Check for required EFI files
            if [[ -f "$efi_mount/EFI/BOOT/BOOTX64.EFI" ]] || [[ -f "$efi_mount/EFI/BOOT/BOOTIA32.EFI" ]]; then
                echo "✅ EFI boot loader found"
            else
                echo "❌ EFI boot loader NOT found (missing BOOTX64.EFI/BOOTIA32.EFI)"
                sudo umount "$efi_mount" 2>/dev/null || true
                exit 1
            fi

            # Check for grub.cfg on EFI partition
            if [[ -f "$efi_mount/EFI/BOOT/grub.cfg" ]]; then
                echo "✅ EFI grub.cfg found"
                # Verify grub.cfg is not empty and has menu entries
                if grep -q "menuentry" "$efi_mount/EFI/BOOT/grub.cfg" 2>/dev/null; then
                    echo "✅ EFI grub.cfg contains menu entries"
                else
                    echo "❌ EFI grub.cfg is empty or missing menu entries"
                    sudo umount "$efi_mount" 2>/dev/null || true
                    exit 1
                fi
            else
                echo "❌ EFI grub.cfg NOT found at /EFI/BOOT/grub.cfg"
                sudo umount "$efi_mount" 2>/dev/null || true
                exit 1
            fi

            sudo umount "$efi_mount" 2>/dev/null || true
        else
            echo "⚠️  Could not mount EFI partition (may need root)"
        fi
    else
        echo "❌ EFI partition NOT found"
        exit 1
    fi
    echo ""

    echo "✅ All checks passed!"

# Rebuild a live ISO using titanoboa (builds image and ISO in one step)
#
# Run a VM from a titanoboa-generated live ISO
#
# Usage: just run-vm-iso-titanoboa [iso_path]
# Examples:
#   just run-vm-iso-titanoboa output/bazzite-nix-Live.iso
# just run-vm-iso-titanoboa  # uses latest ISO in output/

alias run-vm-iso-titanoboa := run-vm-iso

[group('Run Virtual Machine')]
run-vm-iso $iso_path="":
    #!/usr/bin/env bash
    set -euo pipefail

    if [[ -n "{{ iso_path }}" ]]; then
        iso_file="{{ iso_path }}"
    else
        # Try output/ first, then ~/.cache/bazzite-nix/iso/ as fallback
        iso_file=$(find output -name "*.iso" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
        if [[ -z "$iso_file" ]]; then
            cache_iso_dir="$HOME/.cache/bazzite-nix/iso"
            if [[ -d "$cache_iso_dir" ]]; then
                iso_file=$(find "$cache_iso_dir" -name "*.iso" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
            fi
        fi
        if [[ -z "$iso_file" ]]; then
            echo "❌ No ISO found in output/ or ~/.cache/bazzite-nix/iso/. Build one first with: just build-iso-titanoboa"
            exit 1
        fi
    fi

    if [[ ! -f "$iso_file" ]]; then
        echo "❌ ISO not found: $iso_file"
        exit 1
    fi

    echo "🚀 Starting VM with ISO: $iso_file"
    echo "Connect to http://127.0.0.1:8006"

    sudo podman run --rm --privileged \
        --env "CPU_CORES=4" \
        --env "RAM_SIZE=6G" \
        --env "DISK_SIZE=30G" \
        --env "TPM=N" \
        --env "GPU=N" \
        --device=/dev/kvm \
        --device=/dev/net/tun \
        --cap-add NET_ADMIN \
        -p "8006:8006" \
        --volume "$iso_file:/boot.iso:ro" \
        "docker.io/qemux/qemu:latest" &
    QEMU_PID=$!

    echo "Waiting for VM web interface..."
    for _ in {1..15}; do
        if curl -sf http://127.0.0.1:8006 >/dev/null 2>&1; then
            echo "✅ VM running at http://127.0.0.1:8006"
            xdg-open http://127.0.0.1:8006 || echo "⚠️  Open http://127.0.0.1:8006 manually"
            break
        fi
        echo -n "."
        sleep 2
    done

    wait $QEMU_PID || echo "⚠️  VM exited"

# Rebuild a QCOW2 virtual machine image

# Usage: just rebuild-qcow2 [image:tag] (e.g., just rebuild-qcow2 bazzite-nix-cachyos:latest)
[group('Build Virtual Machine Image')]
rebuild-qcow2 $image_spec="":
    #!/usr/bin/env bash
    set -euo pipefail

    # Parse image_spec into target_image and tag
    image_spec_val="{{ image_spec }}"
    default_target_val="localhost/{{ image_name }}"
    default_tag_val="{{ default_tag }}"
    if [[ -n "$image_spec_val" ]]; then
        if [[ "$image_spec_val" == *":"* ]]; then
            target_image="${image_spec_val%:*}"
            tag="${image_spec_val#*:}"
        else
            target_image="${image_spec_val}"
            tag="${default_tag_val}"
        fi
        # Prepend localhost/ if no registry specified
        if [[ "$target_image" != *"/"* ]]; then
            target_image="localhost/${target_image}"
        fi
    else
        target_image="${default_target_val}"
        tag="${default_tag_val}"
    fi

    just _build-rootful "$target_image" "$tag"
    just _build-bib "$target_image" "$tag" "qcow2" "image.toml"

# Rebuild a RAW virtual machine image

# Usage: just rebuild-raw [image:tag] (e.g., just rebuild-raw bazzite-nix-cachyos:latest)
[group('Build Virtual Machine Image')]
rebuild-raw $image_spec="":
    #!/usr/bin/env bash
    set -euo pipefail

    # Parse image_spec into target_image and tag
    image_spec_val="{{ image_spec }}"
    default_target_val="localhost/{{ image_name }}"
    default_tag_val="{{ default_tag }}"
    if [[ -n "$image_spec_val" ]]; then
        if [[ "$image_spec_val" == *":"* ]]; then
            target_image="${image_spec_val%:*}"
            tag="${image_spec_val#*:}"
        else
            target_image="${image_spec_val}"
            tag="${default_tag_val}"
        fi
        # Prepend localhost/ if no registry specified
        if [[ "$target_image" != *"/"* ]]; then
            target_image="localhost/${target_image}"
        fi
    else
        target_image="${default_target_val}"
        tag="${default_tag_val}"
    fi

    just _build-rootful "$target_image" "$tag"
    just _build-bib "$target_image" "$tag" "raw" "image.toml"

# Rebuild an ISO virtual machine image

# Usage: just rebuild-iso [image:tag] (e.g., just rebuild-iso bazzite-nix-cachyos:latest)
[group('Build Virtual Machine Image')]
rebuild-iso $image_spec="":
    #!/usr/bin/env bash
    set -euo pipefail

    # Parse image_spec into target_image and tag
    image_spec_val="{{ image_spec }}"
    default_target_val="localhost/{{ image_name }}"
    default_tag_val="{{ default_tag }}"
    if [[ -n "$image_spec_val" ]]; then
        if [[ "$image_spec_val" == *":"* ]]; then
            target_image="${image_spec_val%:*}"
            tag="${image_spec_val#*:}"
        else
            target_image="${image_spec_val}"
            tag="${default_tag_val}"
        fi
        # Prepend localhost/ if no registry specified
        if [[ "$target_image" != *"/"* ]]; then
            target_image="localhost/${target_image}"
        fi
    else
        target_image="${default_target_val}"
        tag="${default_tag_val}"
    fi

    just _build-rootful "$target_image" "$tag"
    just _build-bib "$target_image" "$tag" "iso" "iso.toml"

# Parse image specification into TARGET_IMAGE and TAG variables
# Usage: eval $(just _parse-image-spec $image_spec)
#
# Sets: TARGET_IMAGE, TAG

# Note: Defaults to ghcr.io/{{ repo_organization }}/ for remote images
[private]
_parse-image-spec $image_spec="":
    #!/usr/bin/env bash
    set -euo pipefail

    image_spec_val="{{ image_spec }}"
    default_target_val="ghcr.io/{{ repo_organization }}/{{ image_name }}"
    default_tag_val="{{ default_tag }}"

    if [[ -n "$image_spec_val" ]]; then
        if [[ "$image_spec_val" == *":"* ]]; then
            target_image="${image_spec_val%:*}"
            tag="${image_spec_val#*:}"
        else
            target_image="${image_spec_val}"
            tag="${default_tag_val}"
        fi
        # Prepend ghcr.io/repo_organization/ if no registry specified
        if [[ "$target_image" != *"/"* ]]; then
            target_image="ghcr.io/{{ repo_organization }}/${target_image}"
        fi
    else
        target_image="${default_target_val}"
        tag="${default_tag_val}"
    fi

    echo "TARGET_IMAGE=\"$target_image\""
    echo "TAG=\"$tag\""

# Parse image specification for local VM usage
# Usage: eval $(just _parse-image-spec-vm $image_spec)
#
# Sets: TARGET_IMAGE, TAG

# Note: Defaults to localhost/ for local images, checks rootful storage
[private]
_parse-image-spec-vm $image_spec="":
    #!/usr/bin/env bash
    set -euo pipefail

    image_spec_val="{{ image_spec }}"
    default_target_val="localhost/{{ image_name }}"
    default_tag_val="{{ default_tag }}"

    if [[ -n "$image_spec_val" ]]; then
        if [[ "$image_spec_val" == *":"* ]]; then
            target_image="${image_spec_val%:*}"
            tag="${image_spec_val#*:}"
        else
            target_image="${image_spec_val}"
            tag="${default_tag_val}"
        fi
        # Prepend localhost/ if no registry specified (no slash means no registry)
        if [[ "$target_image" != *"/"* ]]; then
            target_image="localhost/${target_image}"
        fi
    else
        target_image="${default_target_val}"
        tag="${default_tag_val}"
    fi

    echo "TARGET_IMAGE=\"$target_image\""
    echo "TAG=\"$tag\""

# Check if an image exists in rootful podman storage
# Usage: just _check-image-exists $target_image $tag

# Returns: 0 if exists, 1 if not
[private]
_check-image-exists $target_image $tag:
    #!/usr/bin/env bash
    set -euo pipefail

    if sudo podman image exists "${target_image}:${tag}" 2>/dev/null; then
        exit 0
    else
        exit 1
    fi

# Check if an image is a local image (localhost registry)
# Usage: just _is-local-image $target_image

# Returns: 0 if local, 1 if remote
[private]
_is-local-image $target_image:
    #!/usr/bin/env bash
    set -euo pipefail

    if [[ "$target_image" == localhost/* ]]; then
        exit 0
    else
        exit 1
    fi

# Remove an image from rootful podman storage

# Usage: just _remove-image-rootful $target_image $tag
[private]
_remove-image-rootful $target_image $tag:
    #!/usr/bin/env bash
    set -euo pipefail

    if sudo podman image exists "${target_image}:${tag}" 2>/dev/null; then
        echo "Removing image ${target_image}:${tag} from rootful storage..."
        sudo podman rmi -f "${target_image}:${tag}"
        echo "✅ Removed image ${target_image}:${tag}"
    else
        echo "Image ${target_image}:${tag} not found in rootful storage"
    fi

# Run a virtual machine with the specified image type and configuration
#
# Parameters:
#   $target_image - The image to run (e.g., localhost/bazzite-nix or ghcr.io/user/image)
#   $tag - The image tag
#   $type - Image type (qcow2, raw, iso)
#   $config - Configuration file (image.toml or iso.toml)
#   $output_dir - Optional output directory (default: ~/.cache/bazzite-nix)
#   $force_pull - Force pull image even if local (default: 0)
#   $clean - Clean disk cache only (default: 0)
#
# Behavior:
#   - Local images (localhost/*): Checks rootful storage, errors if not found
#   - Remote images: Pulls to rootful storage if not cached or if force_pull=1
#   - Set force_pull=1 to always pull remote images
#   - Set clean=1 to remove cached disk image before rebuilding

# Incorporates verify-oci-image.sh logic with better VM readiness checking
_run-vm $target_image $tag $type $config $output_dir="" $force_pull="0" $clean="0":
    #!/usr/bin/bash
    set -e

    # Configurable output directory (default to ~/.cache/bazzite-nix to avoid tmpfs restrictions)
    if [[ -n "{{ output_dir }}" ]]; then
        OUTPUT_DIR="{{ output_dir }}"
    elif [[ -n "${OUTPUT_DIR:-}" ]]; then
        : # Use env var if set
    else
        OUTPUT_DIR="${HOME}/.cache/bazzite-nix"
    fi
    mkdir -p "$OUTPUT_DIR"

    BUILDER="${bib_image:-quay.io/centos-bootc/bootc-image-builder:latest}"
    RUNNER="docker.io/qemux/qemu:latest"

    # Determine the image file based on the type
    # BIB uses different subdirectory names: qcow2→qcow2/, raw→image/, iso→bootiso/
    case "$type" in
        qcow2) subdir="qcow2"; disk_name="disk.qcow2" ;;
        raw)   subdir="image"; disk_name="disk.raw" ;;
        iso)   subdir="bootiso"; disk_name="install.iso" ;;
        *)     subdir="$type"; disk_name="disk.${type}" ;;
    esac
    image_file="${OUTPUT_DIR}/${subdir}/${disk_name}"

    # Step 0: Clean disk image if requested
    if [[ "$clean" == "1" ]]; then
        echo "🧹 Clean mode: removing cached disk image..."
        if [[ -f "$image_file" ]]; then
            sudo rm -f "$image_file"
            echo "✅ Removed disk image: $image_file"
        else
            echo "Disk image does not exist: $image_file"
        fi
    fi

    # Step 1: Build disk image if it doesn't exist
    if [[ ! -f "$image_file" ]]; then
        # Check if target image is local or remote
        is_local=false
        if just --unstable _is-local-image "$target_image"; then
            is_local=true
        fi

        echo "Checking for container image ${target_image}:${tag}..."

        if [[ "$is_local" == "true" ]]; then
            # Local image: check if it exists in rootful storage
            if ! just --unstable _check-image-exists "$target_image" "$tag"; then
                echo "❌ Image ${target_image}:${tag} not found in rootful storage."
                echo "   Build it first with: just build-qcow2 ${target_image}:${tag}"
                exit 1
            fi
            echo "✅ Found local image ${target_image}:${tag} in rootful storage."
        else
            # Remote image: check if cached in rootful, pull if needed or if force_pull
            if [[ "$force_pull" == "1" ]]; then
                echo "Force pulling remote image ${target_image}:${tag}..."
                sudo podman pull "$target_image:$tag"
            elif just --unstable _check-image-exists "$target_image" "$tag"; then
                echo "✅ Found cached image ${target_image}:${tag}"
            else
                echo "Pulling remote image ${target_image}:${tag}..."
                sudo podman pull "$target_image:$tag"
            fi
        fi

        # Always ensure builder and runner images are available
        echo "Checking builder image: $BUILDER"
        if ! sudo podman image exists "$BUILDER" 2>/dev/null; then
            echo "Pulling builder image..."
            sudo podman pull "$BUILDER"
        fi

        echo "Checking runner image: $RUNNER"
        if ! sudo podman image exists "$RUNNER" 2>/dev/null; then
            echo "Pulling runner image..."
            sudo podman pull "$RUNNER"
        fi

        echo "Building disk image..."
        mkdir -p "$OUTPUT_DIR"
        sudo podman run --rm -it --privileged \
            --security-opt label=type:unconfined_t \
            -v "$OUTPUT_DIR:/output" \
            -v "$(pwd)/${config}:/config.toml:ro" \
            -v "/var/lib/containers/storage:/var/lib/containers/storage" \
            "$BUILDER" \
            --type "$type" \
            --use-librepo=True \
            --rootfs=btrfs \
            "$target_image:$tag"
    fi

    # Step 2: Boot and verify using qemux/qemu container
    if [[ ! -f "$image_file" ]]; then
        echo "❌ Disk image not found: $image_file"
        exit 1
    fi

    echo "Starting VM with qemux/qemu..."
    echo "Connect to http://127.0.0.1:8006"
    sudo podman run --rm --privileged \
        --env "CPU_CORES=4" \
        --env "RAM_SIZE=6G" \
        --env "DISK_SIZE=30G" \
        --env "TPM=N" \
        --env "GPU=N" \
        --device=/dev/kvm \
        --device=/dev/net/tun \
        --cap-add NET_ADMIN \
        -p "8006:8006" \
        --volume "$image_file:/storage/boot.img" \
        "${RUNNER}" &
    QEMU_PID=$!

    # Wait for boot and check for noVNC web interface
    echo "Waiting for VM web interface to become available..."
    for _ in {1..15}; do
        if curl -sf http://127.0.0.1:8006 >/dev/null 2>&1; then
            echo "✅ VM is running and accessible at http://127.0.0.1:8006"
            xdg-open http://127.0.0.1:8006 || echo "⚠️  xdg-open failed. Open http://127.0.0.1:8006 manually."
            break
        fi
        echo -n "."
        sleep 2
    done

    # Check if we timed out
    if ! curl -sf http://127.0.0.1:8006 >/dev/null 2>&1; then
        echo ""
        echo "⚠️  Timeout waiting for VM. Open http://127.0.0.1:8006 manually when ready."
    fi

    wait $QEMU_PID || echo "⚠️  VM exited (may have timed out or rebooted)"

# Run a virtual machine from a QCOW2 image
#
# Usage: just run-vm-qcow2 [image:tag] [output_dir] [force_pull] [clean]
# Examples:
#   just run-vm-qcow2 localhost/bazzite-nix:testing
#   just run-vm-qcow2 ghcr.io/user/image:latest
#   just run-vm-qcow2 image:latest "" 1      # force pull
#   just run-vm-qcow2 image:latest "" 0 1    # clean start
#   just run-vm-qcow2 localhost/image:latest --clean
#
# Parameters:
#   $image_spec - Image specification (e.g., image:tag or localhost/image:tag)
#   $output_dir - Optional output directory for disk images
#   $force_pull - Force pull image even if cached (default: 0)

# $clean - Clean disk cache and refresh local images (default: 0)
[group('Run Virtual Machine')]
run-vm-qcow2 $image_spec="" $output_dir="" $force_pull="0" $clean="0":
    #!/usr/bin/env bash
    set -euo pipefail

    eval "$(just --unstable _parse-image-spec-vm "{{ image_spec }}")"
    just _run-vm "$TARGET_IMAGE" "$TAG" "qcow2" "image.toml" "{{ output_dir }}" "{{ force_pull }}" "{{ clean }}"

# Run a virtual machine from a RAW image
#
# Usage: just run-vm-raw [image:tag] [output_dir] [force_pull] [clean]
#
# Parameters:
#   $image_spec - Image specification (e.g., image:tag or localhost/image:tag)
#   $output_dir - Optional output directory for disk images
#   $force_pull - Force pull image even if cached (default: 0)

# $clean - Clean disk cache and refresh local images (default: 0)
[group('Run Virtual Machine')]
run-vm-raw $image_spec="" $output_dir="" $force_pull="0" $clean="0":
    #!/usr/bin/env bash
    set -euo pipefail

    eval "$(just --unstable _parse-image-spec-vm "{{ image_spec }}")"
    just _run-vm "$TARGET_IMAGE" "$TAG" "raw" "image.toml" "{{ output_dir }}" "{{ force_pull }}" "{{ clean }}"

# Clean cached VM disk images
[group('Utility')]
clean-vm:
    #!/usr/bin/env bash
    set -euo pipefail
    VM_CACHE="${HOME}/.cache/bazzite-nix"
    if [[ -d "$VM_CACHE" ]]; then
        echo "Removing VM cache from $VM_CACHE..."
        sudo rm -rf "$VM_CACHE"
        echo "✅ VM cache cleaned"
    else
        echo "VM cache does not exist: $VM_CACHE"
    fi

# Runs shell check on all Bash scripts
lint:
    /usr/bin/find . -iname "*.sh" -type f -exec shellcheck "{}" ';'

# Runs shfmt on all Bash scripts
format:
    /usr/bin/find . -iname "*.sh" -type f -exec shfmt --write "{}" ';'
