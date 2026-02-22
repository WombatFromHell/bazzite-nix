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

    podman build \
        "${BUILD_ARGS[@]}" \
        --pull=newer \
        --security-opt label=disable \
        --tag "${target_image}:${tag}" \
        .

# Build a container image directly in rootful podman storage.
# This avoids the need to copy images from user to rootful storage.
# Used by build-qcow2, build-raw, build-iso for BIB compatibility.
#
# Parameters:
#   $target_image - The name of the target image (ex. localhost/bazzite-nix)
#   $tag - The tag of the image (ex. testing)

_build-rootful $target_image $tag:
    #!/usr/bin/env bash
    set -euo pipefail

    BUILD_ARGS=()
    BUILD_ARGS+=("--build-arg" "MAJOR_VERSION={{ centos_version }}")
    BUILD_ARGS+=("--build-arg" "IMAGE_NAME={{ image_name }}")
    BUILD_ARGS+=("--build-arg" "IMAGE_VENDOR={{ repo_organization }}")
    BUILD_ARGS+=("--build-arg" "ENABLE_DX=0")
    BUILD_ARGS+=("--build-arg" "ENABLE_HWE=0")
    BUILD_ARGS+=("--build-arg" "ENABLE_GDX=0")
    BUILD_ARGS+=("--build-arg" "BASE_IMAGE={{ base_image }}")
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

# Command: _rootful_load_image
# Description: This script checks if the current user is root or running under sudo. If not, it attempts to resolve the image tag using podman inspect.
#              If the image is found, it loads it into rootful podman. If the image is not found, it pulls it from the repository.
#
# Parameters:
#   $target_image - The name of the target image to be loaded or pulled.
#   $tag - The tag of the target image to be loaded or pulled. Default is 'default_tag'.
#
# Example usage:
#   _rootful_load_image my_image latest
#
# Steps:
# 1. Check if the script is already running as root or under sudo.
# 2. Check if target image is in the non-root podman container storage)
# 3. If the image is found, load it into rootful podman using podman scp.
# 4. If the image is not found, pull it from the remote repository into reootful podman.

_rootful_load_image $target_image=image_name $tag=default_tag:
    #!/usr/bin/bash
    set -euo pipefail

    # Check if already running as root or under sudo
    if [[ -n "${SUDO_USER:-}" || "${UID}" -eq "0" ]]; then
        echo "Already root or running under sudo, no need to load image from user podman."
        exit 0
    fi

    # Get user image ID
    USER_IMG_ID=$(podman images --filter reference="${target_image}:${tag}" --format json | jq -r '.[0].Id')

    # Check if user image exists
    if [[ -z "$USER_IMG_ID" ]]; then
        echo "Image ${target_image}:${tag} not found in user podman, pulling into rootful podman"
        just sudoif podman pull "${target_image}:${tag}"
        exit 0
    fi

    # Get rootful image ID (may be empty if not present)
    ROOT_IMG_ID=$(just sudoif podman images --filter reference="${target_image}:${tag}" --format json | jq -r '.[0].Id' || echo "")

    # Only copy if rootful image is missing or different from user image
    if [[ -z "$ROOT_IMG_ID" ]]; then
        echo "Image ${target_image}:${tag} not found in rootful podman, copying from user"
        COPYTMP=$(mktemp -p "${PWD}" -d -t _build_podman_scp.XXXXXXXXXX)
        just sudoif TMPDIR=${COPYTMP} podman image scp ${UID}@localhost::"${target_image}:${tag}" root@localhost::"${target_image}:${tag}"
        rm -rf "${COPYTMP}"
    elif [[ "$ROOT_IMG_ID" != "$USER_IMG_ID" ]]; then
        echo "Image ${target_image}:${tag} differs between user and rootful podman, copying from user"
        COPYTMP=$(mktemp -p "${PWD}" -d -t _build_podman_scp.XXXXXXXXXX)
        just sudoif TMPDIR=${COPYTMP} podman image scp ${UID}@localhost::"${target_image}:${tag}" root@localhost::"${target_image}:${tag}"
        rm -rf "${COPYTMP}"
    else
        echo "Image ${target_image}:${tag} already exists in rootful podman with matching ID, skipping copy"
    fi

# Command: _sync-user-to-rootful
# Description: Always copy an image from user podman storage to rootful podman storage.
#              Unlike _rootful_load_image, this does NOT check if the image exists or matches.
#              It always attempts to copy, ensuring the latest layers are available in rootful storage.
#              Does NOT clean or remove existing images - just overwrites via scp.
#
# Parameters:
#   $target_image - The name of the target image to sync.
#   $tag - The tag of the target image. Default is 'default_tag'.
#
# Example usage:
#   _sync-user-to-rootful my_image latest
#
# Returns:
#   0 - Success (image copied or already running as root)
#   1 - Failure (image not found in user storage)

[private]
_sync-user-to-rootful $target_image=image_name $tag=default_tag:
    #!/usr/bin/bash
    set -euo pipefail

    # Check if already running as root or under sudo
    if [[ -n "${SUDO_USER:-}" || "${UID}" -eq "0" ]]; then
        echo "Already root or running under sudo, no sync needed."
        exit 0
    fi

    # Check if image exists in user storage
    USER_IMG_ID=$(podman images --filter reference="${target_image}:${tag}" --format json | jq -r '.[0].Id')

    if [[ -z "$USER_IMG_ID" ]]; then
        echo "❌ Image ${target_image}:${tag} not found in user podman storage."
        exit 1
    fi

    # Always copy from user to rootful (no ID check - always sync)
    echo "Syncing image ${target_image}:${tag} from user to rootful podman storage..."
    COPYTMP=$(mktemp -p "${PWD}" -d -t _build_podman_scp.XXXXXXXXXX)
    just sudoif TMPDIR=${COPYTMP} podman image scp ${UID}@localhost::"${target_image}:${tag}" root@localhost::"${target_image}:${tag}"
    rm -rf "${COPYTMP}"
    echo "✅ Synced image ${target_image}:${tag} to rootful podman storage."

# Build a bootc bootable image using Bootc Image Builder (BIB)
# Converts a container image to a bootable image
# Parameters:
#   target_image: The name of the image to build (ex. localhost/fedora)
#   tag: The tag of the image to build (ex. latest)
#   type: The type of image to build (ex. qcow2, raw, iso)
#   config: The configuration file to use for the build (default: image.toml)

# Example: just _rebuild-bib localhost/fedora latest qcow2 image.toml
_build-bib $target_image $tag $type $config:
    #!/usr/bin/env bash
    set -euo pipefail

    args="--type ${type} "
    args+="--use-librepo=True "
    args+="--rootfs=btrfs"

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
      "${target_image}:${tag}"

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

# Build an ISO virtual machine image

# Usage: just build-iso [image:tag] (e.g., just build-iso bazzite-nix-cachyos:latest)
[group('Build Virtual Machine Image')]
build-iso $image_spec="":
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
#   - Local images (localhost/*): Always syncs from user storage to rootful storage
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
            # Local image: always sync from user storage to rootful storage
            # This ensures we have the absolute latest layers before building
            just --unstable _sync-user-to-rootful "$target_image" "$tag" || {
                echo "⚠️  Image ${target_image}:${tag} not found in user storage."
                # Check if it exists in rootful storage at least
                if ! just --unstable _check-image-exists "$target_image" "$tag"; then
                    echo "❌ Image ${target_image}:${tag} not found in rootful storage either."
                    echo "   Build it first with: just build-qcow2 ${target_image}:${tag}"
                    exit 1
                fi
                echo "✅ Using existing image from rootful storage."
            }
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

# Run a virtual machine from an ISO
#
# Usage: just run-vm-iso [image:tag] [output_dir] [force_pull] [clean]
# Examples:
#   just run-vm-iso localhost/bazzite-nix:testing
#   just run-vm-iso ghcr.io/user/image:latest
#   just run-vm-iso image:latest "" 1      # force pull
#   just run-vm-iso image:latest "" 0 1    # clean start
#   just run-vm-iso localhost/image:latest --clean
#
# Parameters:
#   $image_spec - Image specification (e.g., image:tag or localhost/image:tag)
#   $output_dir - Optional output directory for disk images
#   $force_pull - Force pull image even if cached (default: 0)

# $clean - Clean disk cache and refresh local images (default: 0)
[group('Run Virtual Machine')]
run-vm-iso $image_spec="" $output_dir="" $force_pull="0" $clean="0":
    #!/usr/bin/env bash
    set -euo pipefail

    eval "$(just --unstable _parse-image-spec-vm "{{ image_spec }}")"
    just _run-vm "$TARGET_IMAGE" "$TAG" "iso" "iso.toml" "{{ output_dir }}" "{{ force_pull }}" "{{ clean }}"

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
