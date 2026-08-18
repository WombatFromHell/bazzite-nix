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

# Path to extracted Just helper functions

just_helpers := "scripts/just-helpers.bash"

[private]
default:
    @just --list

# Check Just syntax
[group('Just')]
check:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    check_just_files

# Fix Just syntax
[group('Just')]
fix:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    fix_just_files

# Clean repo build artifacts (keeps pulled base images)
[group('Utility')]
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    clean_artifacts
    echo "=== Cleaning rootful build artifacts ==="
    clean_oci_layout "{{ oci_output_dir }}"
    clean_rechunk_images
    clean_podman_images_light
    clean_buildah_images
    clean_buildah_containers

# Aggressive clean (removes everything including pulled base images)
[group('Utility')]
cleaner:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    clean_artifacts
    echo "=== Cleaning rootful build artifacts ==="
    clean_oci_layout "{{ oci_output_dir }}"
    clean_rechunk_images
    clean_podman_images "{{ bib_image }}"
    clean_buildah_images
    clean_buildah_containers
    just --unstable clean-vm

# Clean cached VM disk images
[group('Utility')]
clean-vm:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    clean_vm_cache "{{ cache_dir }}"

# Run shellcheck on all Bash scripts
[group('Utility')]
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    lint_scripts
    check_just_files

# Run shfmt on all Bash scripts
[group('Utility')]
format:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    format_scripts
    fix_just_files

# Run the bats test suite (all test files)
[group('Utility')]
test:
    bats scripts/just-helpers.bats tests/build-helpers.bats scripts/release-preview.bats

# ── Build commands (sources scripts/build-helpers.bash) ─────────────────────
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
    source "{{ just_helpers }}"
    run_build "{{ variant_or_spec }}" "{{ variants_config }}" "{{ image_name }}" "{{ base_image_override }}"

# Force-rebuild a container image, evicting any cached local image first

# Usage: just rebuild [variant-name | image:tag] [base_image_override]
[group('Build Container Image')]
rebuild $variant_or_spec="{{ default_tag }}" $base_image_override="":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    run_rebuild "{{ variant_or_spec }}" "{{ variants_config }}" "{{ image_name }}" "{{ base_image_override }}"

# Rechunk localhost/raw-img to OCI layout with bootc chunking
# Usage: just rechunk [variant-name | image:tag]

# Example: just rechunk testing
[group('Build Container Image')]
rechunk $variant_or_spec="{{ default_tag }}":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    run_rechunk "{{ variant_or_spec }}" "{{ variants_config }}" "{{ image_name }}" "{{ image_desc }}" "{{ repo_organization }}"

# Relabel an existing image (chunked-img if present, else raw-img) without
# rebuilding or rechunking. For iterating on the relabel flow.
# Usage: just relabel [variant-name | image:tag]
[group('Build Container Image')]
relabel $variant_or_spec="{{ default_tag }}":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    run_relabel "{{ variant_or_spec }}" "{{ variants_config }}" "{{ image_name }}" "{{ image_desc }}" "{{ repo_organization }}"

# ── Full pipeline (mirrors the GitHub Actions workflow) ─────────────────────
# Run the full build pipeline for a single variant:
#   build → extract image info → assemble labels → [rechunk] → relabel → extract final ref
# Rechunk is disabled by default; pass rechunk=1 to enable.

# Usage: just pipeline [variant-name | image:tag] [base_image_override] [force_rebuild] [rechunk]
[group('Build Container Image')]
pipeline $variant_or_spec="{{ default_tag }}" $base_image_override="" $force_rebuild="0" $rechunk="0":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    run_pipeline "{{ variant_or_spec }}" "{{ variants_config }}" "{{ image_name }}" "{{ image_desc }}" "{{ repo_organization }}" "{{ oci_output_dir }}" "{{ base_image_override }}" "{{ force_rebuild }}" "{{ rechunk }}"

# Pipeline with rechunking enabled (just pipeline <variant> "" "" 1)
# Usage: just pipeline-rechunk [variant-name | image:tag] [base_image_override] [force_rebuild]
[group('Build Container Image')]
pipeline-rechunk $variant_or_spec="stable" $base_image_override="" $force_rebuild="0":
    just pipeline "{{ variant_or_spec }}" "{{ base_image_override }}" "{{ force_rebuild }}" "1"

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
    source "{{ just_helpers }}"
    check_variants "{{ force_build }}" "{{ repo_organization }}" "{{ image_name }}" "{{ variants_config }}"
    build_all_variants "{{ oci_output_dir }}" "{{ repo_organization }}" "{{ image_name }}" "{{ image_desc }}"

# Preview changelog data a local image would produce at release time.
# Uses the same helpers as the release pipeline (changelog.py).
# Usage: just release-preview [image_ref] [prev_ref]
# image_ref defaults to localhost/chunked-img; pass localhost/raw-img for non-rechunked.
# prev_ref, if given (e.g. ghcr.io/<owner>/bazzite-nix:latest), is inspected via
# skopeo docker:// (no pull) and renders a prev → new diff like the release does.
[group('Build Container Image')]
release-preview $image_ref="localhost/chunked-img" $prev_ref="":
    python3 scripts/release-preview.py "{{ image_ref }}" {{ if prev_ref != "" { "--prev " + prev_ref } else { "" } }}

# ── CI recipes (called from build.yml; use pre-resolved matrix values) ──────

# Build a single pre-resolved variant (mirrors old build-reusable action).
# Values come from check-variants output — no re-resolution.
# Usage: just ci-pipeline <variant> <base_image> <build_script> <canonical_tag> <tags> <date> <image_desc> <parent_version> [rechunk]
# rechunk=1 enables rpm-ostree chunking (build.yml passes 1; leave 0 for raw-img-only).
[group('Build Container Image')]
ci-pipeline $variant $base_image $build_script $canonical_tag $tags $date $image_desc $parent_version $rechunk="0":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    build_variant_ci "{{ variant }}" "{{ base_image }}" "{{ build_script }}" "{{ canonical_tag }}" "{{ tags }}" "{{ date }}" "{{ image_desc }}" "{{ parent_version }}" "{{ repo_organization }}" "{{ image_name }}" "{{ rechunk }}"

# Push, sign, and verify a built image (mirrors old push-reusable action).
# Env required: GITHUB_ACTOR, GITHUB_TOKEN, SIGNING_SECRET.
# Usage: just push <source_ref> <tags> <registry> <repo> <suffix> <variant> <date> <parent_version>
[group('Build Container Image')]
push $source_ref $tags $registry $repo $suffix $variant $date $parent_version:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    push_variant "{{ source_ref }}" "{{ tags }}" "{{ registry }}" "{{ repo }}" "{{ suffix }}" "{{ variant }}" "{{ date }}" "{{ parent_version }}"

# Generate a GitHub release for a variant (mirrors old release-reusable action).
# Env required: GH_TOKEN. Needs a git checkout with recent history.
# Usage: just release <variant> [handwritten] [variants_config] [allow_disabled]
[group('Build Container Image')]
release $variant $handwritten="" $variants_config="{{ variants_config }}" $allow_disabled="false":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    release_variant "{{ variant }}" "{{ handwritten }}" "{{ variants_config }}" "{{ allow_disabled }}"

# ── Variant helpers ─────────────────────────────────────────────────────────

# List available (non-disabled) variants from variants.json
[group('Utility')]
list-variants:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    list_available_variants "{{ variants_config }}"

# Check which variants need rebuilding (mirrors check-variants action)

# Usage: just check-variants [force_build] [variants_override]
# Example: just check-variants 1 stable,testing
[group('Build Container Image')]
check-variants $force_build="0" $variants_override="":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    check_variants "{{ force_build }}" "{{ repo_organization }}" "{{ image_name }}" "{{ variants_config }}" "{{ variants_override }}"

# Preview which alias tags (and the step-summary markdown) a build would generate
# Usage: just tags-preview [variant-name | image:tag]
[group('Build Container Image')]
tags-preview $variant_or_spec="{{ default_tag }}":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    preview_tags "{{ variant_or_spec }}" "{{ variants_config }}" "{{ image_name }}" "{{ repo_organization }}"

# ── VM commands ─────────────────────────────────────────────────────────────
# Build a QCOW2 VM disk image

# Usage: just build-qcow2 [variant-name | image:tag] [output_dir]
[group('Build Virtual Machine Image')]
build-qcow2 $variant_or_spec="{{ default_tag }}" $output_dir="" $force_rebuild="0":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    build_vm_image_qcow2 "{{ variant_or_spec }}" "{{ output_dir }}" "{{ force_rebuild }}" "{{ oci_output_dir }}" "{{ cache_dir }}" "{{ bib_image }}"

# Build a RAW VM disk image

# Usage: just build-raw [variant-name | image:tag] [output_dir]
[group('Build Virtual Machine Image')]
build-raw $variant_or_spec="{{ default_tag }}" $output_dir="" $force_rebuild="0":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    build_vm_image_raw "{{ variant_or_spec }}" "{{ output_dir }}" "{{ force_rebuild }}" "{{ oci_output_dir }}" "{{ cache_dir }}" "{{ bib_image }}"

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
    source "{{ just_helpers }}"
    run_vm_qcow2 "{{ variant_or_spec }}" "{{ variants_config }}" "{{ image_name }}" "{{ output_dir }}" "{{ force_pull }}" "{{ clean }}" "{{ oci_output_dir }}" "{{ cache_dir }}" "{{ bib_image }}"

# Run a RAW VM

# Usage: just run-vm-raw [variant-name | image:tag] [output_dir] [force_pull] [clean]
[group('Run Virtual Machine')]
run-vm-raw $variant_or_spec="{{ default_tag }}" $output_dir="" $force_pull="0" $clean="0":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ just_helpers }}"
    run_vm_raw "{{ variant_or_spec }}" "{{ variants_config }}" "{{ image_name }}" "{{ output_dir }}" "{{ force_pull }}" "{{ clean }}" "{{ oci_output_dir }}" "{{ cache_dir }}" "{{ bib_image }}"
