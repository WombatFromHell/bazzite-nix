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
    set -eoux pipefail

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

# Run a virtual machine with the specified image type and configuration
_run-vm $target_image $tag $type $config:
    #!/usr/bin/bash
    set -eoux pipefail

    # Determine the image file based on the type
    image_file="output/${type}/disk.${type}"
    if [[ $type == iso ]]; then
        image_file="output/bootiso/install.iso"
    fi

    # Build the image if it does not exist
    if [[ ! -f "${image_file}" ]]; then
        env just "build-${type}" "${target_image}:${tag}"
    fi

    # Determine an available port to use
    port=8006
    while grep -q :${port} <<< $(ss -tunalp); do
        port=$(( port + 1 ))
    done
    echo "Using Port: ${port}"
    echo "Connect to http://localhost:${port}"

    # Set up the arguments for running the VM
    run_args=()
    run_args+=(--rm --privileged)
    run_args+=(--pull=newer)
    run_args+=(--publish "127.0.0.1:${port}:8006")
    run_args+=(--env "CPU_CORES=4")
    run_args+=(--env "RAM_SIZE=8G")
    run_args+=(--env "DISK_SIZE=64G")
    run_args+=(--env "TPM=Y")
    run_args+=(--env "GPU=Y")
    run_args+=(--device=/dev/kvm)
    run_args+=(--device=/dev/net/tun)
    run_args+=(--cap-add NET_ADMIN)
    run_args+=(--volume "${PWD}/${image_file}:/storage/boot.qcow2")
    run_args+=(docker.io/qemux/qemu)

    # Run the VM and open the browser to connect
    (sleep 30 && xdg-open http://localhost:"$port") &
    podman run "${run_args[@]}"

# Run a virtual machine from a QCOW2 image

# Usage: just run-vm-qcow2 [image:tag] (e.g., just run-vm-qcow2 bazzite-nix-cachyos:latest)
[group('Run Virtual Machine')]
run-vm-qcow2 $image_spec="":
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

    just _run-vm "$target_image" "$tag" "qcow2" "image.toml"

# Run a virtual machine from a RAW image

# Usage: just run-vm-raw [image:tag] (e.g., just run-vm-raw bazzite-nix-cachyos:latest)
[group('Run Virtual Machine')]
run-vm-raw $image_spec="":
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

    just _run-vm "$target_image" "$tag" "raw" "image.toml"

# Run a virtual machine from an ISO

# Usage: just run-vm-iso [image:tag] (e.g., just run-vm-iso bazzite-nix-cachyos:latest)
[group('Run Virtual Machine')]
run-vm-iso $image_spec="":
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

    just _run-vm "$target_image" "$tag" "iso" "iso.toml"

# Runs shell check on all Bash scripts
lint:
    /usr/bin/find . -iname "*.sh" -type f -exec shellcheck "{}" ';'

# Runs shfmt on all Bash scripts
format:
    /usr/bin/find . -iname "*.sh" -type f -exec shfmt --write "{}" ';'
