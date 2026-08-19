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
#   just-helpers-tooling.bash  — dev tooling: lint/format/just-files/sudoif
#
# Also sources the check-variants umbrella (CHECK_VARIANTS_HELPERS) for
# resolve_variant / check / summary helpers used by build and preview paths.

set -euo pipefail

# Path to shared build helpers (used by build functions)
# Can be overridden via environment: JUST_HELPERS_BUILD=/path/to/helpers.sh
readonly JUST_HELPERS_BUILD="${JUST_HELPERS_BUILD:-scripts/build-helpers.bash}"

# Path to push/sign helpers (skopeo retry, cosign)
readonly JUST_HELPERS_PUSH="${JUST_HELPERS_PUSH:-scripts/push-helpers.bash}"

# Path to variant-resolution helpers (resolve_variant lives here, not duplicated)
# Can be overridden via environment: CHECK_VARIANTS_HELPERS=/path/to/helpers.sh
readonly CHECK_VARIANTS_HELPERS="${CHECK_VARIANTS_HELPERS:-scripts/check-variants-helpers.bash}"
# shellcheck disable=SC1090
source "$CHECK_VARIANTS_HELPERS"

_parts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1090
for _part in clean build vm variants tooling; do
  source "${_parts_dir}/just-helpers-${_part}.bash"
done
