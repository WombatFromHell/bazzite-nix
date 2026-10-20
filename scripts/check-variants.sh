#!/usr/bin/env bash
#
# check-variants.sh - Check which image variants need rebuilding
#
# Usage: ./check-variants.sh
#
# Environment Variables:
#   REGISTRY           - Full registry URL (e.g., "ghcr.io/ublue-os")
#   REPO               - Repository name (e.g., "bazzite-nix")
#   IMAGE_DESC         - Image description
#   DATE               - Build date timestamp
#   FORCE_BUILD        - "true" to force rebuild regardless of digest
#   VARIANTS_CONFIG    - Path to variants.json config file
#   VARIANTS_OVERRIDE  - Comma-delimited list of variant names to build (overrides default selection)
#   ARTIFACTS_DIR      - Directory for this run's artifacts (set by just-helpers.bash)
#
# Output:
#   Writes variant check results to $ARTIFACTS_DIR/variants_results.json
#

# shellcheck disable=SC2153
# NOTE:
# REGISTRY, REPO, FORCE_BUILD, IMAGE_DESC, DATE, VARIANTS_CONFIG
# are set by the calling composite action's env: block.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/check-variants-registry.bash"
# shellcheck disable=SC1090
# source the GHA log directives (fail/warn) used by every part
source "${SCRIPT_DIR}/log-helpers.bash"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/check-variants-tags.bash"
# resolve_variant spells a local image reference with build-helpers' image_ref,
# the one spelling of that ref; nothing here builds, it only keeps the spelling
# honest in the record.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/build-helpers.bash"

# Validate required environment variables
for var in REGISTRY REPO FORCE_BUILD ARTIFACTS_DIR; do
  if [[ -z "${!var+x}" ]]; then
    fail "${var} environment variable must be set"
    exit 1
  fi
done

# Set defaults
VARIANTS_CONFIG="${VARIANTS_CONFIG:-.github/variants.json}"

# Start the run in a clean artifact directory, so no file from a previous run
# can be read as this run's result.
if [[ "$ARTIFACTS_DIR" == "." || "$ARTIFACTS_DIR" == ".." || "$ARTIFACTS_DIR" == "/" ]]; then
  fail "ARTIFACTS_DIR must be a dedicated directory, not . .. or /"
  exit 1
fi
rm -rf -- "$ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"

# Validate variants config file exists
if [[ ! -f "$VARIANTS_CONFIG" ]]; then
  fail "Variants config file not found: $VARIANTS_CONFIG"
  exit 1
fi

# Ensure registry is lowercase (GHCR requirement)
REGISTRY="${REGISTRY,,}"

# The package name inside the namespace (GHCR requires lowercase)
REPO="$(package_repo "$REPO")"

# Parse variants override list if provided
override_variants=()
override_active=false
if [[ -n "${VARIANTS_OVERRIDE:-}" ]]; then
  IFS=',' read -ra override_variants <<<"$VARIANTS_OVERRIDE"
  override_active=true
  echo "::notice::Variants override active: ${VARIANTS_OVERRIDE}"

  # Trim the list once, so "stable, testing" means the same as "stable,testing".
  for idx in "${!override_variants[@]}"; do
    override_variants[idx]="${override_variants[idx]//[[:space:]]/}"
  done

  # Validate each override variant exists in config
  for requested_variant in "${override_variants[@]}"; do
    if [[ -z "$requested_variant" ]]; then
      continue
    fi
    if ! variant_record "$requested_variant" "$VARIANTS_CONFIG" >/dev/null 2>&1; then
      AVAILABLE=$(variant_names "$VARIANTS_CONFIG" | paste -sd ', ' -)
      fail "Variant '$requested_variant' not found in $VARIANTS_CONFIG. Available: $AVAILABLE"
      exit 1
    fi
  done
fi

# Initialize results array; the file starts as [] so a run killed mid-loop still
# leaves valid JSON for aggregate_variants.
results=()
results_file="$ARTIFACTS_DIR/variants_results.json"
echo "[]" >"$results_file"

# Get variant count
variant_count=$(jq '.variants | length' "$VARIANTS_CONFIG")

for ((i = 0; i < variant_count; i++)); do
  variant=$(jq -r ".variants[$i].name" "$VARIANTS_CONFIG")
  disabled=$(jq -r ".variants[$i].disabled // false" "$VARIANTS_CONFIG")

  # Override selection: only listed variants are considered, and a listed variant
  # is checked even when config disables it.
  in_override=false
  if [[ "$override_active" == "true" ]]; then
    if [[ " ${override_variants[*]} " == *" $variant "* ]]; then
      in_override=true
    fi
    if [[ "$in_override" == "false" ]]; then
      echo "::notice::Variant $variant: not in override list, skipping"
      continue
    fi
  fi
  if [[ "$disabled" == "true" && "$in_override" == "false" ]]; then
    echo "::notice::Variant $variant: disabled in config, skipping"
    continue
  fi

  echo "::group::Checking variant: $variant"

  # Identity, canonical tag and the tag list all come from resolve_variant, the
  # one driver the Justfile uses: the record it prints IS this variant's identity,
  # so the upstream-identity rule lives in exactly one place (DESIGN.md decision 10).
  # rc 2 is "no free version tag within the bump walk" - that variant is skipped,
  # because one busy variant must not fail the whole check.
  record="" rc=0
  record=$(resolve_variant "$variant" "$VARIANTS_CONFIG" "$REPO" "$FORCE_BUILD" "$REGISTRY") || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    fail "Variant $variant: no free version tag to name a build; skipping"
    echo "::endgroup::"
    continue
  elif [[ "$rc" -ne 0 ]]; then
    fail "Variant $variant could not be resolved; check job failed"
    echo "::endgroup::"
    exit 1
  fi

  IFS=$'\037' read -r suffix parent_version < <(jq -r '[.suffix, .parent_version] | join("\u001f")' <<<"$record")
  prefix="${REGISTRY}/${REPO}${suffix}"

  check_output=$(check_build_needed "$prefix" "$variant" "$parent_version" "$FORCE_BUILD") || {
    echo "::endgroup::"
    continue
  }
  eval "$check_output"

  echo "::notice::Variant $variant needs building: ${REASON}"
  results+=("$(jq -c '. + {needs_build: true}' <<<"$record")")

  echo "::endgroup::"
done

# Write all results to the run artifact directory
printf '%s\n' "${results[@]}" | jq -s '.' >"$results_file"

echo "::notice::Results written to $results_file"
