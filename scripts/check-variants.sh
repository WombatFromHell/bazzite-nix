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
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/check-variants-tags.bash"

# Validate required environment variables
for var in REGISTRY REPO FORCE_BUILD ARTIFACTS_DIR; do
  if [[ -z "${!var+x}" ]]; then
    echo "::error::${var} environment variable must be set"
    exit 1
  fi
done

# Set defaults
VARIANTS_CONFIG="${VARIANTS_CONFIG:-.github/variants.json}"

# Start the run in a clean artifact directory, so no file from a previous run
# can be read as this run's result.
if [[ "$ARTIFACTS_DIR" == "." || "$ARTIFACTS_DIR" == ".." || "$ARTIFACTS_DIR" == "/" ]]; then
  echo "::error::ARTIFACTS_DIR must be a dedicated directory, not . .. or /"
  exit 1
fi
rm -rf -- "$ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"

# Validate variants config file exists
if [[ ! -f "$VARIANTS_CONFIG" ]]; then
  echo "::error::Variants config file not found: $VARIANTS_CONFIG"
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

  # Validate each override variant exists in config
  for requested_variant in "${override_variants[@]}"; do
    # Trim whitespace
    requested_variant=$(echo "$requested_variant" | xargs)
    if [[ -z "$requested_variant" ]]; then
      continue
    fi
    if ! variant_record "$requested_variant" "$VARIANTS_CONFIG" >/dev/null 2>&1; then
      AVAILABLE=$(variant_names "$VARIANTS_CONFIG" | paste -sd ', ' -)
      echo "::error::Variant '$requested_variant' not found in $VARIANTS_CONFIG. Available: $AVAILABLE"
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

  # Check if this variant is in the override list (if override is active)
  in_override=false
  if [[ "$override_active" == "true" ]]; then
    for requested in "${override_variants[@]}"; do
      requested=$(echo "$requested" | xargs)
      if [[ "$variant" == "$requested" ]]; then
        in_override=true
        break
      fi
    done

    # If override is active but this variant is not in the list, skip it
    if [[ "$in_override" == "false" ]]; then
      echo "::notice::Variant $variant: not in override list, skipping"
      continue
    fi
  fi

  # Skip disabled variants unless they're explicitly in the override list
  if [[ "$disabled" == "true" && "$in_override" == "false" ]]; then
    echo "::notice::Variant $variant: disabled in config, skipping"
    continue
  fi

  echo "::group::Checking variant: $variant"

  # Upstream identity for a variant: the configured base image's own label gives
  # the version it now holds, and upstream's git tag of that version names the
  # release whose commits the notes describe. The tag is probed by exact name
  # ("{branch}-{version}", then a bare "{version}") rather than found by paging
  # the tag list, because upstream pushes 40+ tags a day and an older branch is
  # never inside a page window (DESIGN.md section 2).
  upstream="$(upstream_repo "$base_image")"

  inspect_json=$(inspect_image_with_retry "$base_image") || {
    echo "::error::Failed to inspect base image after retries: $base_image"
    echo "::endgroup::"
    exit 1
  }

  if ! metadata=$(extract_image_metadata "$inspect_json"); then
    echo "::error::Failed to extract metadata from base image $base_image"
    echo "::endgroup::"
    exit 1
  fi

  label_version=$(echo "$metadata" | awk '{print $1}')
  base_version=$(version_of_tag "$label_version" "$variant")
  if [[ ! "$base_version" =~ $VERSIONED_TAG_PATTERN ]]; then
    echo "::error::Base image $base_image is labelled $label_version, which is not a release version"
    echo "::endgroup::"
    exit 1
  fi

  upstream_identity=$(resolve_upstream_tag "$upstream" "$variant" "$base_version") || {
    echo "::error::No upstream git tag names version $base_version of variant $variant in $upstream"
    echo "::endgroup::"
    exit 1
  }
  read -r upstream_tag upstream_version tag_family <<<"$upstream_identity"
  if [[ -z "$upstream_tag" || -z "$upstream_version" || -z "$tag_family" ]]; then
    echo "::error::Upstream identity for variant $variant is incomplete: $upstream_identity"
    echo "::endgroup::"
    exit 1
  fi

  parent_version="$upstream_version"
  echo "::notice::Upstream identity for $variant: git tag $upstream_tag (version $parent_version, family $tag_family)"
  echo "Resolved parent_version from upstream git tag: $parent_version"

  # Standardized image reference components
  # shellcheck disable=SC2153
  output_image="${REPO}${suffix}"
  prefix="${REGISTRY}/${output_image}"

  # Compute canonical tag, passing the variant name as branch for accurate collision checks.
  canonical_bump=$(compute_canonical_tag "$parent_version" "$prefix" "$FORCE_BUILD" "$variant") || {
    echo "::error::Variant $variant: no free version tag to name a build; skipping"
    echo "::endgroup::"
    continue
  }
  read -r canonical collision_detected <<<"$canonical_bump"

  # Generate tags (no digest — {sha256} tags are resolved at push time from the
  # built image's digest, not the upstream base image's)
  tags=$(generate_tags "$variant" "$canonical" "$latest" "$tags_json")

  # Check if build is needed
  check_output=$(check_build_needed "$prefix" "$variant" "$parent_version" "$FORCE_BUILD") || {
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
    --arg canonical_tag "$canonical" \
    --arg upstream_tag "$upstream_tag" \
    --arg tags "$tags" \
    --arg collision_detected "$collision_detected" \
    '{
        variant: $variant,
        base_image: $base_image,
        build_script: $build_script,
        suffix: $suffix,
        parent_version: $parent_version,
        canonical_tag: $canonical_tag,
        upstream_tag: $upstream_tag,
        tags: $tags,
        collision_detected: ($collision_detected == "true"),
        needs_build: true
    }')

  # Collect result
  results+=("$result")

  echo "::endgroup::"
done

# Write all results to the run artifact directory
printf '%s\n' "${results[@]}" | jq -s '.' >"$results_file"

echo "::notice::Results written to $results_file"
