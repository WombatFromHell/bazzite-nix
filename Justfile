# Every recipe runs in bash with these flags; recipes no longer repeat them.
set shell := ["bash", "-euo", "pipefail", "-c"]

# The run's environment, spelled once, in the one convention the helpers read (UPPERCASE).
# Per-call choices (variant, VM type, output dir, force flags) stay recipe arguments.
export GITHUB_REPOSITORY_OWNER := env("GITHUB_REPOSITORY_OWNER", "wombatfromhell")
export IMAGE_NAME := env("IMAGE_NAME", "bazzite-nix")
export IMAGE_DESC := env("IMAGE_DESC", "Customized Bazzite image with Nix mount support and other sugar")
export DEFAULT_TAG := env("DEFAULT_TAG", "testing")
export BIB_IMAGE := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")
export CACHE_DIR := env("CACHE_DIR", `echo "$HOME/.cache/bazzite-nix"`)
export VARIANTS_CONFIG := env("VARIANTS_CONFIG", ".github/variants.json")

# One entrypoint for every recipe: scripts/just-helpers.sh sources the helper umbrella
# (scripts/just-helpers.bash) and runs the named function with these arguments. It is
# the shell `just` would otherwise need per recipe line, so no recipe carries a preamble.
# The OCI layout root is not exported: build-helpers.bash owns that default (an exported
# template here would be taken literally, which is how it used to end up in a bogus dir).

[private]
default:
    @just --list

# Check Just syntax
[group('Just')]
check:
    @scripts/just-helpers.sh check_just_files

# Fix Just syntax
[group('Just')]
fix:
    @scripts/just-helpers.sh fix_just_files

# Clean build outputs (raw-img, chunked-img, OCI layout)
[group('Utility')]
clean:
    @scripts/just-helpers.sh clean_oci_layout
    @scripts/just-helpers.sh remove_images_and_prune podman localhost/raw-img localhost/chunked-img || true

# Aggressive clean (cache dir, build outputs and build inputs, rootless + rootful)
[group('Utility')]
cleaner:
    @scripts/just-helpers.sh clean_artifacts
    @sudo find -L "{{ CACHE_DIR }}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true
    @scripts/just-helpers.sh remove_images_and_prune podman localhost/raw-img localhost/chunked-img ghcr.io/ublue-os/bazzite quay.io/centos-bootc/bootc-image-builder quay.io/coreos/chunkah quay.io/centos-bootc/centos-bootc docker.io/qemux/qemu || true
    @scripts/just-helpers.sh remove_images_and_prune sudo-podman localhost/chunked-img "{{ BIB_IMAGE }}" || true
    @sudo rm -rf /var/tmp/buildah* /var/tmp/podman*

# Clean cached VM disk images
[group('Utility')]
clean-vm:
    @scripts/just-helpers.sh clean_vm_cache "{{ CACHE_DIR }}"

# Run shellcheck on all Bash scripts
[group('Utility')]
lint:
    @scripts/just-helpers.sh lint_scripts
    @scripts/just-helpers.sh check_just_files

# Run shfmt on all Bash scripts
[group('Utility')]
format:
    @scripts/just-helpers.sh format_scripts
    @scripts/just-helpers.sh fix_just_files

# Run the bats test suite (all test files)
[group('Utility')]
test:
    bats scripts/just-helpers.bats tests/build-helpers.bats tests/log-helpers.bats scripts/check-variants.bats scripts/release-preview.bats scripts/push-helpers.bats
    python3 -m pytest tests/test_changelog.py

# ── Build commands (sources scripts/build-helpers.bash) ─────────────────────
# Build a container image (stages to localhost/raw-img)
# Usage: just build [variant-name | image:tag] [base_image_override]
# Examples:
#   just build testing
#   just build cachyos

# just build bazzite-nix:mytag ghcr.io/ublue-os/bazzite:testing
[group('Build Container Image')]
build $variant_or_spec="" $base_image_override="" $force_rebuild="0":
    @scripts/just-helpers.sh run_build "{{ variant_or_spec }}" "{{ VARIANTS_CONFIG }}" "{{ IMAGE_NAME }}" "{{ base_image_override }}" "{{ force_rebuild }}"

# Force-rebuild a container image, evicting any cached local image first

# Usage: just rebuild [variant-name | image:tag] [base_image_override]
[group('Build Container Image')]
rebuild $variant_or_spec="" $base_image_override="":
    just --unstable build "{{ variant_or_spec }}" "{{ base_image_override }}" "1"

# Rechunk localhost/raw-img to OCI layout with bootc chunking
# Usage: just rechunk [variant-name | image:tag]

# Example: just rechunk testing
[group('Build Container Image')]
rechunk $variant_or_spec="":
    @scripts/just-helpers.sh entry_variant rechunk "{{ variant_or_spec }}"
    @scripts/just-helpers.sh rootful_load "{{ variant_or_spec }}"

# Transfer the chunked image from rootless to rootful podman storage, so it can
# be used with `sudo bootc switch`. Requires an existing chunked-img for the variant.
# Usage: just rootful-load [variant-name]
[group('Build Container Image')]
rootful-load $variant_or_spec="":
    @scripts/just-helpers.sh rootful_load "{{ variant_or_spec }}"

# Relabel an existing image (chunked-img if present, else raw-img) without
# rebuilding or rechunking. For iterating on the relabel flow.
# Usage: just relabel [variant-name | image:tag]
[group('Build Container Image')]
relabel $variant_or_spec="":
    @scripts/just-helpers.sh entry_variant relabel "{{ variant_or_spec }}"

# ── Full pipeline (mirrors the GitHub Actions workflow) ─────────────────────
# Run the full build pipeline for a single variant:
#   build → extract image info → assemble labels → [relabel] → [rechunk] → extract final ref
# Rechunk is disabled by default; pass rechunk=1 to enable.

# Usage: just pipeline [variant-name | image:tag] [base_image_override] [force_rebuild] [rechunk]
[group('Build Container Image')]
pipeline $variant_or_spec="" $base_image_override="" $force_rebuild="0" $rechunk="0":
    @scripts/just-helpers.sh entry_variant pipeline "{{ variant_or_spec }}" "base_image_override={{ base_image_override }}" "force_rebuild={{ force_rebuild }}" "rechunk={{ rechunk }}"

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
    @scripts/just-helpers.sh check_variants "{{ force_build }}" "{{ GITHUB_REPOSITORY_OWNER }}" "{{ IMAGE_NAME }}" "{{ VARIANTS_CONFIG }}"
    @scripts/just-helpers.sh build_all_variants "{{ GITHUB_REPOSITORY_OWNER }}" "{{ IMAGE_NAME }}" "{{ IMAGE_DESC }}"

# Preview the changelog a locally built image would produce at release time.
# Uses the same helpers as the release pipeline (changelog.py); inspects the
# local containers-storage image, so no registry access is needed.
# Usage: just release-preview [variant_csv] [prev_ref] [variants_config]
#   variant_csv: comma-delimited variant names (blank = all enabled).
#                Each variant uses localhost/chunked-img:<variant>, falling back
#                to localhost/chunked-img:latest when that tag is missing or
#                lacks the ostree.rechunk.info label.
#   prev_ref: optional previous release ref (e.g. ghcr.io/<owner>/bazzite-nix:testing-44.20260812.1),
# inspected via skopeo docker:// (no pull) to render a prev → new diff.
[group('Build Container Image')]
release-preview $variants="" $prev="" $config="":
    @scripts/just-helpers.sh release_preview "{{ variants }}" "{{ prev }}" "{{ config }}"

# ── CI recipes (called from build.yml; use pre-resolved matrix values) ──────

# Build a single pre-resolved variant (mirrors old build-reusable action).
# The record comes from check-variants output; its version_label is parent_version.
# Usage: just ci-pipeline <record_json> [options_json]
# options_json carries {"rechunk":0|1} (build.yml passes 1; leave 0 for raw-img-only).
[group('Build Container Image')]
ci-pipeline $record_json $options_json="{}":
    @scripts/just-helpers.sh build_variant_ci '{{ record_json }}' '{{ options_json }}'

# Push, sign, and verify a built image (mirrors old push-reusable action).
# Env required: GITHUB_ACTOR, GITHUB_TOKEN, SIGNING_SECRET.
# Usage: just push <record_json> [options_json]
[group('Build Container Image')]
push $record_json $options_json="{}":
    @scripts/just-helpers.sh push_variant '{{ record_json }}' '{{ options_json }}'

# Generate a GitHub release for a variant (mirrors old release-reusable action).
# Skips publishing when the version tag already has a release.
# Auth: GH_TOKEN/GITHUB_TOKEN (CI) or ambient gh login. Needs a git checkout with recent history.
# Usage: just release [variant] [handwritten] [variants_config] [allow_disabled]
[group('Build Container Image')]
release $variant $handwritten="" $config="" $allow_disabled="false":
    @scripts/just-helpers.sh entry_release "{{ variant }}" "{{ handwritten }}" "{{ config }}" "{{ allow_disabled }}"

# ── Variant helpers ─────────────────────────────────────────────────────────

# List available (non-disabled) variants from variants.json
[group('Utility')]
list-variants:
    @scripts/just-helpers.sh list_available_variants "{{ VARIANTS_CONFIG }}"

# Check which variants need rebuilding (mirrors check-variants action)

# Usage: just check-variants [force_build] [variants_override]
# Example: just check-variants 1 stable,testing
[group('Build Container Image')]
check-variants $force_build="0" $variants_override="":
    @scripts/just-helpers.sh check_variants "{{ force_build }}" "{{ GITHUB_REPOSITORY_OWNER }}" "{{ IMAGE_NAME }}" "{{ VARIANTS_CONFIG }}" "{{ variants_override }}"

# Demo one release window locally: two published tags from one release branch become the
# changelog body and TITLE/TAG the real generator writes (under .artifacts, gitignored).
# Needs ghcr auth for skopeo: podman login ghcr.io.
# Usage: just demo-changelog unstable unstable-45.20261015.6 unstable-45.20261017.2
[group('Build Container Image')]
demo-changelog $variant $prev-tag $curr-tag:
    @scripts/just-helpers.sh entry_demo_changelog "{{ variant }}" "{{ prev-tag }}" "{{ curr-tag }}"

# Preview which alias tags (and the step-summary markdown) a build would generate
# Usage: just tags-preview [variant-name | image:tag]
[group('Build Container Image')]
tags-preview $variant_or_spec:
    @scripts/just-helpers.sh preview_tags "{{ variant_or_spec }}" "{{ VARIANTS_CONFIG }}" "{{ IMAGE_NAME }}" "{{ GITHUB_REPOSITORY_OWNER }}"

# ── VM commands ─────────────────────────────────────────────────────────────
# Build a QCOW2 VM disk image

# Usage: just build-qcow2 [variant-name | image:tag] [output_dir]
[group('Build Virtual Machine Image')]
build-qcow2 $variant_or_spec="" $output_dir="" $force_rebuild="0":
    @scripts/just-helpers.sh entry_vm_build qcow2 "{{ variant_or_spec }}" "{{ output_dir }}" "{{ force_rebuild }}"

# Build a RAW VM disk image

# Usage: just build-raw [variant-name | image:tag] [output_dir]
[group('Build Virtual Machine Image')]
build-raw $variant_or_spec="" $output_dir="" $force_rebuild="0":
    @scripts/just-helpers.sh entry_vm_build raw "{{ variant_or_spec }}" "{{ output_dir }}" "{{ force_rebuild }}"

# Build and force-rebuild a QCOW2 image (skips cached container image)
[group('Build Virtual Machine Image')]
rebuild-qcow2 $variant_or_spec="" $output_dir="":
    just --unstable build-qcow2 "{{ variant_or_spec }}" "{{ output_dir }}" "1"

# Build and force-rebuild a RAW image (skips cached container image)
[group('Build Virtual Machine Image')]
rebuild-raw $variant_or_spec="" $output_dir="":
    just --unstable build-raw "{{ variant_or_spec }}" "{{ output_dir }}" "1"

# Run a QCOW2 VM

# Usage: just run-vm-qcow2 [variant-name | image:tag] [output_dir] [force_pull] [clean]
[group('Run Virtual Machine')]
run-vm-qcow2 $variant_or_spec="" $output_dir="" $force_pull="0" $clean="0":
    @scripts/just-helpers.sh entry_vm_run qcow2 "{{ variant_or_spec }}" "{{ output_dir }}" "{{ force_pull }}" "{{ clean }}"

# Run a RAW VM

# Usage: just run-vm-raw [variant-name | image:tag] [output_dir] [force_pull] [clean]
[group('Run Virtual Machine')]
run-vm-raw $variant_or_spec="" $output_dir="" $force_pull="0" $clean="0":
    @scripts/just-helpers.sh entry_vm_run raw "{{ variant_or_spec }}" "{{ output_dir }}" "{{ force_pull }}" "{{ clean }}"
