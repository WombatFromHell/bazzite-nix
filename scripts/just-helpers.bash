#!/usr/bin/env bash
# just-helpers.bash — Extracted shell functions for Justfile targets.
# All functions are designed to be testable in isolation.
#
# Usage:
#   source scripts/just-helpers.bash
#   clean_artifacts
#   resolve_variant "testing"
#
# Umbrella file: sourced by Justfile targets, CI workflows (build.yml,
# generate_release.yml), and the bats suite. Function bodies live in
# single-concern parts, split out for readability:
#
#   just-helpers-clean.bash    — clean/remove build artifacts, images, VM cache
#   just-helpers-build.bash    — build pipeline, CI parity, build-all
#   just-helpers-vm.bash       — VM image build/run and their Justfile wrappers
#   just-helpers-variants.bash — variant check/aggregate/preview, release resolution
#   just-helpers-tooling.bash  — dev tooling: lint/format/just-files
#
# Also sources the check-variants parts (check-variants-registry.bash,
# check-variants-tags.bash) for resolve_variant / check / summary helpers used
# by build and preview paths.

set -euo pipefail

_parts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path to shared build helpers (used by build functions)
readonly JUST_HELPERS_BUILD="scripts/build-helpers.bash"

# Path to push/sign helpers (skopeo retry, cosign)
readonly JUST_HELPERS_PUSH="scripts/push-helpers.bash"

# shellcheck disable=SC1090
source "${_parts_dir}/check-variants-registry.bash"
# shellcheck disable=SC1090
source "${_parts_dir}/check-variants-tags.bash"
# shellcheck disable=SC1090
source "$JUST_HELPERS_BUILD"
# shellcheck disable=SC1090
source "$JUST_HELPERS_PUSH"

# shellcheck disable=SC1090
for _part in clean build vm variants tooling; do
  source "${_parts_dir}/just-helpers-${_part}.bash"
done
