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
#
# Output:
#   Writes variant check results to /tmp/variants_results.json
#

# shellcheck disable=SC2153
# NOTE:
# REGISTRY, REPO, FORCE_BUILD, IMAGE_DESC, DATE, VARIANTS_CONFIG
# are set by the calling composite action's env: block.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# Validate required environment variables
for var in REGISTRY REPO FORCE_BUILD; do
  if [[ -z "${!var+x}" ]]; then
    echo "::error::${var} environment variable must be set"
    exit 1
  fi
done

# Set defaults
VARIANTS_CONFIG="${VARIANTS_CONFIG:-.github/variants.json}"

# Validate variants config file exists
if [[ ! -f "$VARIANTS_CONFIG" ]]; then
  echo "::error::Variants config file not found: $VARIANTS_CONFIG"
  exit 1
fi

# Ensure registry is lowercase (GHCR requirement)
REGISTRY=$(echo "$REGISTRY" | tr '[:upper:]' '[:lower:]')

# Initialize results array
results=()

# Get variant count
variant_count=$(jq '.variants | length' "$VARIANTS_CONFIG")

for ((i = 0; i < variant_count; i++)); do
  # Read variant from JSON config
  variant=$(jq -r ".variants[$i].name" "$VARIANTS_CONFIG")
  base_image=$(jq -r ".variants[$i].base_image" "$VARIANTS_CONFIG")
  build_script=$(jq -r ".variants[$i].build_script // empty" "$VARIANTS_CONFIG")
  suffix=$(jq -r ".variants[$i].suffix // empty" "$VARIANTS_CONFIG")
  latest=$(jq -r ".variants[$i].latest // false" "$VARIANTS_CONFIG")
  tags_json=$(jq -c ".variants[$i].tags // empty" "$VARIANTS_CONFIG")
  disabled=$(jq -r ".variants[$i].disabled // false" "$VARIANTS_CONFIG")

  # Default to build.sh if build_script is empty
  build_script="${build_script:-build.sh}"

  # Skip disabled variants
  if [[ "$disabled" == "true" ]]; then
    echo "::notice::Variant $variant: disabled in config, skipping"
    continue
  fi

  echo "::group::Checking variant: $variant"

  # Extract metadata from upstream image
  inspect_json=$(inspect_image_with_retry "$base_image") || {
    echo "::error::Failed to inspect upstream image for variant $variant"
    echo "::endgroup::"
    exit 1
  }

  if ! metadata=$(extract_image_metadata "$inspect_json"); then
    echo "::error::Failed to extract metadata from upstream image for variant $variant"
    echo "::endgroup::"
    exit 1
  fi
  parent_version=$(echo "$metadata" | awk '{print $1}')
  digest=$(echo "$metadata" | awk '{print $2}')

  # Parse base image for output naming
  base_image_tag="${base_image##*:}"

  # Standardized image reference components
  # shellcheck disable=SC2153
  output_image="${REPO}${suffix}"
  prefix="${REGISTRY}/${output_image}"

  # Compute canonical tag
  read -r canonical collision_detected <<<"$(compute_canonical_tag "$parent_version" "$prefix" "$FORCE_BUILD")"

  # Generate tags
  tags=$(generate_tags "$base_image_tag" "$canonical" "$latest" "$tags_json")

  # Find previous build reference for rechunk
  prev_ref=""
  if prev_ref=$(find_prev_ref "$prefix" "$base_image_tag" "$canonical" "$tags_json"); then
    echo "::debug::Found previous build: ${prev_ref}" >&2
  else
    echo "::debug::No previous build found for ${prefix}" >&2
  fi

  # Check if build is needed
  check_output=$(check_build_needed "$prefix" "$canonical" "$variant" "$base_image_tag" "$parent_version" "$FORCE_BUILD") || {
    echo "::endgroup::"
    continue
  }
  eval "$check_output"

  echo "::notice::Variant $variant needs building: ${REASON}"

  # Build result JSON
  result=$(jq -n \
    --arg variant "$variant" \
    --arg base_image "$base_image" \
    --arg build_script "$build_script" \
    --arg suffix "$suffix" \
    --arg parent_version "$parent_version" \
    --arg digest "$digest" \
    --arg canonical_tag "$canonical" \
    --arg tags "$tags" \
    --arg prev_ref "$prev_ref" \
    --arg collision_detected "$collision_detected" \
    '{
        variant: $variant,
        base_image: $base_image,
        build_script: $build_script,
        suffix: $suffix,
        parent_version: $parent_version,
        digest: $digest,
        canonical_tag: $canonical_tag,
        tags: $tags,
        prev_ref: $prev_ref,
        collision_detected: ($collision_detected == "true"),
        needs_build: true
    }')

  # Collect result
  if [[ -n "$result" && "$result" != "null" && "$result" != "{}" ]]; then
    results+=("$result")
  fi

  echo "::endgroup::"
done

# Write all results to single temp file
if [[ ${#results[@]} -eq 0 ]]; then
  echo "[]" >/tmp/variants_results.json
else
  printf '%s\n' "${results[@]}" | jq -s '.' >/tmp/variants_results.json
fi

echo "::notice::Results written to /tmp/variants_results.json"
