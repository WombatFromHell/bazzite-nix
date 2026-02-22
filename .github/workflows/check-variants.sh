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
          : $((next_num++))
        done
        canonical="${search_base}.${next_num}"
      else
        local search_base="$canonical"
        local next_num=1
        while skopeo inspect "docker://${search_base}.${next_num}" >/dev/null 2>&1; do
          : $((next_num++))
        done
        canonical="${search_base}.${next_num}"
      fi
    fi
  fi

  echo "$canonical"
}

# Generate tags based on base image tag and variant configuration
# Arguments: $1 = base_image_tag, $2 = canonical, $3 = variant_name, $4 = suffix, $5 = latest, $6 = tags_json
# Outputs: Comma-separated tags string
generate_tags() {
  local base_image_tag="$1"
  local canonical="$2"
  local variant_name="$3"
  local suffix="$4"
  local latest="${5:-false}"
  local tags_json="${6:-}"

  local tags_array=()

  # Add "latest" tag if latest=true
  if [ "$latest" = "true" ]; then
    tags_array+=("latest")
  fi

  # If tags object is provided, use explicit template for versioned only
  if [ -n "$tags_json" ] && [ "$tags_json" != "null" ]; then
    local tags_branch tags_versioned
    tags_branch=$(echo "$tags_json" | jq -r '.branch // empty')
    tags_versioned=$(echo "$tags_json" | jq -r '.versioned // [] | .[]' 2>/dev/null)

    # Use branch from config or fall back to base_image_tag
    local branch="${tags_branch:-$base_image_tag}"

    # Add versioned tags with placeholder substitution
    # Note: versioned array is the single source of truth (includes branch tag if desired)
    while IFS= read -r versioned_tag; do
      if [ -n "$versioned_tag" ]; then
        # Substitute placeholders
        versioned_tag="${versioned_tag//\{canonical\}/$canonical}"
        versioned_tag="${versioned_tag//\{branch\}/$branch}"
        tags_array+=("$versioned_tag")
      fi
    done <<<"$tags_versioned"

    # Output as comma-separated string
    (
      IFS=,
      echo "${tags_array[*]}"
    )
    return 0
  fi

  # No explicit tags config - use default logic for all variants
  # Default: branch tag + versioned tags
  tags_array+=("${base_image_tag}" "${base_image_tag}-${canonical}" "${canonical}")

  # Output as comma-separated string
  (
    IFS=,
    echo "${tags_array[*]}"
  )
}

# Get variant count from config
variant_count=$(jq '.variants | length' "$VARIANTS_CONFIG")

# Get the primary tag for version comparison based on base image tag
# Arguments: $1 = base_image_tag
# Outputs: Echoes the primary tag to compare against (stable, testing, or latest)
get_primary_tag() {
  local base_image_tag="$1"
  case "${base_image_tag}" in
  "stable") echo "stable" ;;
  "testing") echo "testing" ;;
  *) echo "latest" ;;
  esac
}

# Get parent_version label from a target image
# Arguments: $1 = image_ref (e.g., "ghcr.io/owner/image:tag")
# Outputs: Echoes parent_version on success, returns 0 on success, 1 on failure
get_image_parent_version() {
  local image_ref="$1"
  local inspect_output
  local version

  inspect_output=$(skopeo inspect "docker://${image_ref}" 2>&1)
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    echo "::debug::skopeo inspect failed for ${image_ref}: ${inspect_output}"
    return 1
  fi

  version=$(echo "$inspect_output" | jq -r '.Labels["org.opencontainers.image.version"] // empty')

  if [ -n "$version" ] && [ "$version" != "null" ]; then
    echo "$version"
    return 0
  fi

  echo "::debug::No valid version label found in ${image_ref}"
  return 1
}

# Check if build is needed for this variant
# Arguments: $1 = prefix, $2 = canonical, $3 = variant_name, $4 = base_image_tag, $5 = upstream_parent_version
# Outputs: Sets REASON global variable, returns 0 if build needed, 1 if skip
check_build_needed() {
  local prefix="$1"
  local canonical="$2"
  local variant_name="$3"
  local base_image_tag="$4"
  local upstream_parent_version="$5"

  REASON=""

  # Check if force build requested
  if [ "$FORCE_BUILD" = "true" ]; then
    REASON="Force build requested"
    return 0
  fi

  # Get the primary tag for version comparison
  local primary_tag
  primary_tag=$(get_primary_tag "$base_image_tag")

  # Check if our primary tag exists and compare parent_version labels
  local primary_ref="${prefix}:${primary_tag}"
  echo "::debug::Checking primary tag for version comparison: ${primary_ref}"

  local local_parent_version
  if local_parent_version=$(get_image_parent_version "$primary_ref"); then
    echo "::debug::Local parent_version: ${local_parent_version}"
    echo "::debug::Upstream parent_version: ${upstream_parent_version}"

    if [ "$local_parent_version" = "$upstream_parent_version" ]; then
      REASON="Upstream unchanged (parent_version: ${upstream_parent_version})"
      echo "::notice::Variant ${variant_name}: ${REASON}"
      return 1
    fi
    REASON="Upstream changed (${local_parent_version} → ${upstream_parent_version})"
    echo "Variant ${variant_name}: ${REASON}"
    return 0
  fi

  echo "::notice::Could not fetch parent_version from ${primary_ref} (may not exist), checking canonical tag"
  echo "::debug::Failed to get parent_version from primary tag ${primary_ref}, falling back to canonical tag check"

  # Primary tag doesn't exist, check canonical tag ({branch}-{canonical} format)
  local target_ref="docker://${prefix}:${base_image_tag}-${canonical}"
  echo "::debug::Primary tag not found, checking canonical: ${target_ref}"
  if skopeo inspect "${target_ref}" >/dev/null 2>&1; then
    echo "::debug::Target image exists: ${target_ref}"
    REASON="Canonical tag already exists"
    echo "::notice::Variant ${variant_name}: ${REASON}"
    return 1
  fi
  echo "::debug::Target image does not exist: ${target_ref}"

  # Target doesn't exist, need to build
  REASON="Target image does not exist"
  return 0
}

# Find the previous build reference for rechunk using canonical tag format
# Arguments: $1 = prefix (registry/image), $2 = base_image_tag, $3 = canonical_tag, $4 = tags_json
# Outputs: Echoes the full image ref (registry/image:tag) of the previous build, returns 0 on success, 1 on failure
find_prev_ref() {
  local prefix="$1"
  local base_image_tag="$2"
  local canonical_tag="$3"
  local tags_json="$4"
  local available_tags

  # Fetch available tags from registry
  available_tags=$(skopeo list-tags "docker://${prefix}" 2>/dev/null | jq -r '.Tags[]' 2>/dev/null) || {
    echo "::debug::Failed to list tags for ${prefix}"
    return 1
  }

  # Build expected canonical tag format: {branch}-{canonical}
  local canonical_format_tag="${base_image_tag}-${canonical_tag}"

  # Extract the version number from canonical_tag for finding previous builds
  local current_version="$canonical_tag"

  # If tags config exists and has versioned patterns, check what format we expect
  if [ -n "$tags_json" ] && [ "$tags_json" != "null" ] && [ "$tags_json" != "{}" ]; then
    local versioned_patterns
    versioned_patterns=$(echo "$tags_json" | jq -r '.versioned[]?' 2>/dev/null)
    local best_match=""
    local best_version=""

    # First pass: look for previous versions in patterns containing {canonical} (most specific)
    while IFS= read -r pattern; do
      if [ -n "$pattern" ] && [[ "$pattern" == *"{canonical}"* ]]; then
        local resolved_pattern="${pattern//\{branch\}/$base_image_tag}"
        # Extract prefix and suffix around {canonical}
        local prefix_part="${resolved_pattern%%\{*}"
        local suffix_part="${resolved_pattern##*\}}"

        while IFS= read -r tag; do
          # Check if tag matches the pattern structure
          if [[ "$tag" == "${prefix_part}"* ]] && [[ "$tag" == *"${suffix_part}" ]]; then
            # Extract version from tag
            local extracted_version="${tag#${prefix_part}}"
            extracted_version="${extracted_version%${suffix_part}}"
            # Only consider tags with version less than current
            if [ -n "$extracted_version" ] && [[ "$extracted_version" < "$current_version" ]]; then
              if [ -z "$best_version" ] || [[ "$extracted_version" > "$best_version" ]]; then
                best_version="$extracted_version"
                best_match="$tag"
              fi
            fi
          fi
        done <<<"$available_tags"
      fi
    done <<<"$versioned_patterns"

    if [ -n "$best_match" ]; then
      echo "${prefix}:${best_match}"
      return 0
    fi

    # Second pass: other patterns (without canonical) - exact match only
    while IFS= read -r pattern; do
      if [ -n "$pattern" ] && [[ "$pattern" != *"{canonical}"* ]]; then
        local resolved_pattern="${pattern//\{branch\}/$base_image_tag}"
        while IFS= read -r tag; do
          if [ "$tag" = "$resolved_pattern" ]; then
            echo "${prefix}:${tag}"
            return 0
          fi
        done <<<"$available_tags"
      fi
    done <<<"$versioned_patterns"
  fi

  # Fallback for variants without explicit tags config
  # Search order: most specific ({branch}-{version} where version < current) -> branch only

  # First: look for {branch}-{version} tags where version < current_version
  local best_prev_tag=""
  local best_prev_version=""

  while IFS= read -r tag; do
    # Match tags in format: {base_image_tag}-{version}
    if [[ "$tag" == "${base_image_tag}-"* ]]; then
      local tag_version="${tag#${base_image_tag}-}"
      # Only consider tags with version less than current
      if [[ "$tag_version" < "$current_version" ]]; then
        if [ -z "$best_prev_version" ] || [[ "$tag_version" > "$best_prev_version" ]]; then
          best_prev_version="$tag_version"
          best_prev_tag="$tag"
        fi
      fi
    fi
  done <<<"$available_tags"

  if [ -n "$best_prev_tag" ]; then
    echo "${prefix}:${best_prev_tag}"
    return 0
  fi

  # Last fallback: check branch tag (least specific)
  while IFS= read -r tag; do
    if [ "$tag" = "$base_image_tag" ]; then
      echo "${prefix}:${tag}"
      return 0
    fi
  done <<<"$available_tags"

  # No matching canonical tag found
  return 1
}

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
  # Note: GHCR normalizes owner names to lowercase
  output_image="${IMAGE_NAME}${suffix}"
  registry="ghcr.io/$(echo "${REGISTRY_OWNER}" | tr '[:upper:]' '[:lower:]')"
  prefix="${registry}/${output_image}"

  # Compute canonical tag
  canonical=$(compute_canonical_tag "$parent_version" "$prefix")

  # Strip branch prefix from canonical if already present (e.g., "testing-43.20260221.2" → "43.20260221.2")
  # This prevents double-prefixing when using templates like "{branch}-{canonical}"
  if [[ "$canonical" == "${base_image_tag}-"* ]]; then
    canonical="${canonical#"${base_image_tag}"-}"
  fi

  # Generate tags
  tags=$(generate_tags "$base_image_tag" "$canonical" "$variant" "$suffix" "$latest" "$tags_json")

  # Find previous build reference for rechunk (using canonical format)
  prev_ref=""
  if prev_ref=$(find_prev_ref "$prefix" "$base_image_tag" "$canonical" "$tags_json"); then
    echo "::debug::Found previous build: ${prev_ref}"
  else
    echo "::debug::No previous build found for ${prefix} in canonical format ${base_image_tag}-${canonical}"
  fi

  # Check if build is needed
  if ! check_build_needed "$prefix" "$canonical" "$variant" "$base_image_tag" "$parent_version"; then
    # Note: check_build_needed already emits the notice annotation
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
    --arg suffix "$suffix" \
    --arg parent_version "$parent_version" \
    --arg digest "$digest" \
    --arg canonical_tag "$canonical" \
    --arg tags "$tags" \
    --arg prev_ref "$prev_ref" \
    --argjson needs_build "$needs_build" \
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
