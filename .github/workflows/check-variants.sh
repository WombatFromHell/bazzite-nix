#!/usr/bin/env bash
#
# check-variants.sh - Check which image variants need rebuilding
#
# Usage: ./check-variants.sh
#
# Environment Variables:
#   REGISTRY_OWNER     - GitHub repository owner (e.g., "ublue-os")
#   IMAGE_NAME         - Repository name (e.g., "bazzite-nix")
#   FORCE_BUILD        - "true" to force rebuild regardless of digest
#   VARIANTS_CONFIG    - Path to variants.json config file
#
# Standardized Variable Naming (matching workflow convention):
#   registry           - Full registry URL (e.g., "ghcr.io/ublue-os")
#   output_image       - Image name with suffix (e.g., "bazzite-nix-cachyos")
#   prefix             - Full image path (e.g., "ghcr.io/ublue-os/bazzite-nix-cachyos")
#   base_image_tag     - Tag from base image (e.g., "stable" from "ghcr.io/...:stable")
#
# Output:
#   Writes variant check results to /tmp/variants_results.json
#

set -euo pipefail

# Retry configuration
MAX_RETRIES=3
RETRY_DELAY=10

# Validate required environment variables
if [ -z "${REGISTRY_OWNER+x}" ]; then
  echo "::error::REGISTRY_OWNER environment variable must be set"
  exit 1
fi

if [ -z "${IMAGE_NAME+x}" ]; then
  echo "::error::IMAGE_NAME environment variable must be set"
  exit 1
fi

if [ -z "${FORCE_BUILD+x}" ]; then
  echo "::error::FORCE_BUILD environment variable must be set"
  exit 1
fi

# Set default variants config path
VARIANTS_CONFIG="${VARIANTS_CONFIG:-.github/variants.json}"

# Validate variants config file exists
if [ ! -f "$VARIANTS_CONFIG" ]; then
  echo "::error::Variants config file not found: $VARIANTS_CONFIG"
  exit 1
fi

# Load variants from config file
# Initialize results array
results=()

# Inspect upstream image with retry logic
# Arguments: $1 = base_image
# Outputs: Echoes "parent_version digest" on success, returns 0 on success, 1 on failure
inspect_upstream_image() {
  local base_image="$1"
  local attempt
  local inspect_output
  local parent_version=""
  local digest=""

  echo "Inspecting upstream base image: $base_image" >&2

  for attempt in $(seq 1 $MAX_RETRIES); do
    inspect_output=$(skopeo inspect "docker://$base_image" 2>/dev/null) || true

    if [ -n "$inspect_output" ]; then
      parent_version=$(echo "$inspect_output" | jq -r '.Labels["org.opencontainers.image.version"] // empty')
      digest=$(echo "$inspect_output" | jq -r '.Digest // empty' | sed 's/sha256://')

      if [ -n "$parent_version" ] && [ "$parent_version" != "null" ] && [ "$parent_version" != "latest" ] &&
        [ -n "$digest" ] && [ "$digest" != "null" ]; then
        echo "Successfully extracted metadata: version=$parent_version, digest=$digest" >&2
        echo "$parent_version $digest"
        return 0
      fi
      echo "Attempt $attempt: Metadata validation failed for $base_image (version='$parent_version', digest='$digest')" >&2
    else
      echo "Attempt $attempt: Failed to inspect $base_image" >&2
    fi

    [ "$attempt" -lt $MAX_RETRIES ] && sleep $RETRY_DELAY
  done

  echo "::error::Failed to extract valid metadata from $base_image after $MAX_RETRIES attempts" >&2
  return 1
}

# Compute canonical tag, handling version collisions
# Arguments: $1 = parent_version, $2 = prefix (registry/image)
# Outputs: Sets canonical variable
compute_canonical_tag() {
  local parent_version="$1"
  local prefix="$2"
  local canonical="$parent_version"

  if [ "$FORCE_BUILD" = "true" ]; then
    if skopeo inspect "docker://${prefix}:${canonical}" >/dev/null 2>&1; then
      echo "Collision detected: ${canonical} exists. Calculating next version..."
      if [[ "$canonical" =~ ^(.*)\.([0-9]+)$ ]]; then
        local stem="${BASH_REMATCH[1]}"
        local last_num="${BASH_REMATCH[2]}"
        local search_base
        local next_num

        if [ ${#last_num} -ge 4 ]; then
          search_base="$canonical"
          next_num=1
        else
          search_base="$stem"
          next_num=$((last_num + 1))
        fi

        while skopeo inspect "docker://${search_base}.${next_num}" >/dev/null 2>&1; do
          echo "${search_base}.${next_num} also exists, checking next..."
          ((next_num++))
        done
        canonical="${search_base}.${next_num}"
      else
        local search_base="$canonical"
        local next_num=1
        while skopeo inspect "docker://${search_base}.${next_num}" >/dev/null 2>&1; do
          ((next_num++))
        done
        canonical="${search_base}.${next_num}"
      fi
    fi
  fi

  echo "$canonical"
}

# Generate tags based on base image tag
# Arguments: $1 = base_image_tag, $2 = canonical
# Outputs: Comma-separated tags string
generate_tags() {
  local base_image_tag="$1"
  local canonical="$2"

  case "${base_image_tag}" in
  "stable") echo "stable,stable-${canonical},${canonical}" ;;
  "testing") echo "testing,latest,${canonical}" ;;
  *) echo "${base_image_tag},${base_image_tag}-${canonical},${canonical}" ;;
  esac
}

# Check if build is needed for this variant
# Arguments: $1 = prefix, $2 = canonical, $3 = digest, $4 = variant_name
# Outputs: Sets REASON global variable, returns 0 if build needed, 1 if skip
check_build_needed() {
  local prefix="$1"
  local canonical="$2"
  local digest="$3"
  local variant_name="$4"

  REASON=""

  # Check if force build requested
  if [ "$FORCE_BUILD" = "true" ]; then
    REASON="Force build requested"
    return 0
  fi

  # Check canonical tag existence
  local target_ref="docker://${prefix}:${canonical}"
  echo "::debug::Checking if target image exists: ${target_ref}"
  if skopeo inspect "${target_ref}" >/dev/null 2>&1; then
    echo "::debug::Target image exists: ${target_ref}"
    echo "::notice::Variant ${variant_name}: canonical tag already exists, skipping"
    return 1
  fi
  echo "::debug::Target image does not exist: ${target_ref}"

  # Target doesn't exist, need to build
  REASON="Target image does not exist"
  return 0
}

# Get variant count from config
variant_count=$(jq '.variants | length' "$VARIANTS_CONFIG")

# Main processing loop
for ((i = 0; i < variant_count; i++)); do
  # Read variant from JSON config
  variant=$(jq -r ".variants[$i].name" "$VARIANTS_CONFIG")
  base_image=$(jq -r ".variants[$i].base_image" "$VARIANTS_CONFIG")
  build_script=$(jq -r ".variants[$i].build_script // empty" "$VARIANTS_CONFIG")
  image_suffix=$(jq -r ".variants[$i].image_suffix // empty" "$VARIANTS_CONFIG")
  disabled=$(jq -r ".variants[$i].disabled // false" "$VARIANTS_CONFIG")

  # Default to build.sh if build_script is empty
  build_script="${build_script:-build.sh}"

  # Skip disabled variants
  if [ "$disabled" = "true" ]; then
    echo "::notice::Variant $variant: disabled in config, skipping"
    continue
  fi

  echo "::group::Checking variant: $variant"

  # Extract metadata from upstream image
  metadata_output=$(inspect_upstream_image "$base_image") || {
    echo "::error::Failed to inspect upstream image for variant $variant"
    echo "::endgroup::"
    exit 1
  }
  parent_version=$(echo "$metadata_output" | awk '{print $1}')
  digest=$(echo "$metadata_output" | awk '{print $2}')

  # Parse base image for output naming
  base_image_tag="${base_image##*:}"

  # Standardized image reference components (matching workflow convention)
  output_image="${IMAGE_NAME}${image_suffix}"
  registry="ghcr.io/${REGISTRY_OWNER}"
  prefix="${registry}/${output_image}"

  # Compute canonical tag
  canonical=$(compute_canonical_tag "$parent_version" "$prefix")

  # Generate tags
  tags=$(generate_tags "$base_image_tag" "$canonical")

  # Check if build is needed
  if ! check_build_needed "$prefix" "$canonical" "$digest" "$variant"; then
    echo "::notice::Variant $variant: $REASON"
    echo "::endgroup::"
    continue
  fi

  echo "Variant $variant needs building: $REASON"
  needs_build=true

  # Build result JSON
  result=$(jq -n \
    --arg variant "$variant" \
    --arg base_image "$base_image" \
    --arg build_script "$build_script" \
    --arg image_suffix "$image_suffix" \
    --arg parent_version "$parent_version" \
    --arg digest "$digest" \
    --arg canonical_tag "$canonical" \
    --arg tags "$tags" \
    --argjson needs_build "$build_needed" \
    '{
                variant: $variant,
                base_image: $base_image,
                build_script: $build_script,
                image_suffix: $image_suffix,
                parent_version: $parent_version,
                digest: $digest,
                canonical_tag: $canonical_tag,
                tags: $tags,
                needs_build: $needs_build
            }')

  # Collect result
  if [ -n "$result" ] && [ "$result" != "null" ] && [ "$result" != "{}" ]; then
    results+=("$result")
  fi

  echo "::endgroup::"
done

# Write all results to single temp file
if [ ${#results[@]} -eq 0 ]; then
  echo "[]" >/tmp/variants_results.json
else
  printf '%s\n' "${results[@]}" | jq -s '.' >/tmp/variants_results.json
fi

echo "Results written to /tmp/variants_results.json"
cat /tmp/variants_results.json
