#!/usr/bin/env bash
# helpers.sh — shared functions for check-variants action.
# Exposes functions for inspecting images, computing tags, checking build status, and aggregating results.
#
# Environment Variables (expected to be set by caller):
#   REGISTRY           - Full registry URL (e.g., "ghcr.io/ublue-os")
#   REPO               - Repository name (e.g., "bazzite-nix")
#   IMAGE_DESC         - Image description
#   DATE               - Build date timestamp
#   FORCE_BUILD        - "true" to force rebuild regardless of digest
#   VARIANTS_CONFIG    - Path to variants.json config file
#   GITHUB_STEP_SUMMARY - Path to GitHub step summary file (optional)
#   GITHUB_OUTPUT      - Path to GitHub outputs file (optional)

set -euo pipefail

# Retry configuration
MAX_RETRIES=3
RETRY_DELAY=10

# ── inspect image with retry ────────────────────────────────────────────────
# Usage: inspect_image_with_retry <image_ref>
# Outputs: Echoes skopeo inspect JSON on success
# Returns: 0 on success, 1 on failure after all retries

inspect_image_with_retry() {
  local image_ref="$1"
  local attempt inspect_output

  for attempt in $(seq 1 $MAX_RETRIES); do
    if inspect_output=$(skopeo inspect "docker://${image_ref}" 2>/dev/null); then
      if [ -n "$inspect_output" ] && echo "$inspect_output" | jq empty 2>/dev/null; then
        echo "$inspect_output"
        return 0
      fi
    fi

    echo "::debug::Attempt ${attempt}/${MAX_RETRIES}: Failed to inspect ${image_ref}" >&2
    [ "$attempt" -lt "$MAX_RETRIES" ] && sleep "$RETRY_DELAY"
  done

  echo "::error::Failed to inspect ${image_ref} after ${MAX_RETRIES} attempts" >&2
  return 1
}

# ── extract image metadata ──────────────────────────────────────────────────
# Usage: extract_image_metadata <inspect_json>
# Outputs parent_version and digest from skopeo inspect JSON
# Prints: parent_version digest

extract_image_metadata() {
  local inspect_json="$1"
  local parent_version digest

  parent_version=$(echo "$inspect_json" | jq -r '.Labels["org.opencontainers.image.version"] // empty')
  digest=$(echo "$inspect_json" | jq -r '.Digest // empty' | sed 's/sha256://')

  if [[ -z "$parent_version" || "$parent_version" == "null" || "$parent_version" == "latest" ]]; then
    return 1
  fi
  if [[ -z "$digest" || "$digest" == "null" ]]; then
    return 1
  fi

  echo "$parent_version $digest"
}

# ── compute canonical tag ───────────────────────────────────────────────────
# Usage: compute_canonical_tag <parent_version> <prefix> <force_build>
# Computes canonical tag, handling version collisions when force_build is true.
# Prints: canonical collision_detected

compute_canonical_tag() {
  local parent_version="$1"
  local prefix="$2"
  local force_build="$3"

  # Strip branch prefix (e.g., "testing-") to get pure version number
  local canonical
  if [[ "$parent_version" =~ ^[a-zA-Z]+-([0-9].*)$ ]]; then
    canonical="${BASH_REMATCH[1]}"
  else
    canonical="$parent_version"
  fi

  local collision_detected="false"

  if [[ "$force_build" != "true" ]]; then
    echo "$canonical $collision_detected"
    return 0
  fi

  if ! skopeo inspect "docker://${prefix}:${canonical}" >/dev/null 2>&1; then
    echo "$canonical $collision_detected"
    return 0
  fi

  echo "::notice::Collision detected: ${canonical} exists. Calculating next version..." >&2
  collision_detected="true"

  # Parse version number and increment
  local next_num=1
  local search_base="$canonical"

  if [[ "$canonical" =~ ^(.*)\.([0-9]+)$ ]] && [ ${#BASH_REMATCH[2]} -lt 4 ]; then
    search_base="${BASH_REMATCH[1]}"
    next_num=$((BASH_REMATCH[2] + 1))
  fi

  while skopeo inspect "docker://${search_base}.${next_num}" >/dev/null 2>&1; do
    echo "::notice::${search_base}.${next_num} also exists, checking next..." >&2
    ((next_num++))
  done

  canonical="${search_base}.${next_num}"
  echo "$canonical $collision_detected"
}

# ── generate tags ───────────────────────────────────────────────────────────
# Usage: generate_tags <base_image_tag> <canonical> <latest> <tags_json>
# Generates comma-separated tags based on configuration.

generate_tags() {
  local base_image_tag="$1"
  local canonical="$2"
  local latest="$3"
  local tags_json="$4"
  local tags_array=()

  # Add "latest" tag if latest=true
  [[ "$latest" == "true" ]] && tags_array+=("latest")

  # If tags config is provided, use explicit template
  if [[ -n "$tags_json" && "$tags_json" != "null" ]]; then
    local tags_branch tags_versioned
    tags_branch=$(echo "$tags_json" | jq -r '.branch // empty')
    tags_versioned=$(echo "$tags_json" | jq -r '.versioned // [] | .[]' 2>/dev/null)

    # Use branch from config or fall back to base_image_tag
    local branch="${tags_branch:-$base_image_tag}"

    # Add versioned tags with placeholder substitution
    while IFS= read -r versioned_tag; do
      if [[ -n "$versioned_tag" ]]; then
        versioned_tag="${versioned_tag//\{canonical\}/$canonical}"
        versioned_tag="${versioned_tag//\{branch\}/$branch}"
        tags_array+=("$versioned_tag")
      fi
    done <<<"$tags_versioned"

    (
      IFS=,
      echo "${tags_array[*]}"
    )
    return 0
  fi

  # Default: branch tag + versioned tags
  tags_array+=("${base_image_tag}" "${base_image_tag}-${canonical}" "${canonical}")

  (
    IFS=,
    echo "${tags_array[*]}"
  )
}

# ── find previous build reference ───────────────────────────────────────────
# Usage: find_prev_ref <prefix> <base_image_tag> <canonical_tag> <tags_json>
# Finds the previous build reference for rechunk using canonical tag format.
# Prints: Full image ref (registry/image:tag) on success
# Returns: 0 on success, 1 on failure

find_prev_ref() {
  local prefix="$1"
  local base_image_tag="$2"
  local canonical_tag="$3"
  local tags_json="$4"
  local available_tags

  available_tags=$(skopeo list-tags "docker://${prefix}" 2>/dev/null | jq -r '.Tags[]' 2>/dev/null) || {
    echo "::debug::Failed to list tags for ${prefix}" >&2
    return 1
  }

  # If tags config exists with versioned patterns, use them
  if [[ -n "$tags_json" && "$tags_json" != "null" && "$tags_json" != "{}" ]]; then
    local versioned_patterns
    versioned_patterns=$(echo "$tags_json" | jq -r '.versioned[]?' 2>/dev/null)
    local best_match="" best_version=""

    # First pass: patterns containing {canonical}
    while IFS= read -r pattern; do
      if [[ -n "$pattern" && "$pattern" == *"{canonical}"* ]]; then
        local resolved="${pattern//\{branch\}/$base_image_tag}"
        local prefix_part="${resolved%%\{*}"
        local suffix_part="${resolved##*\}}"

        while IFS= read -r tag; do
          if [[ "$tag" == "${prefix_part}"* && "$tag" == *"${suffix_part}" ]]; then
            local extracted="${tag#"${prefix_part}"}"
            extracted="${extracted%"${suffix_part}"}"
            if [[ -n "$extracted" && "$extracted" < "$canonical_tag" ]]; then
              if [[ -z "$best_version" || "$extracted" > "$best_version" ]]; then
                best_version="$extracted"
                best_match="$tag"
              fi
            fi
          fi
        done <<<"$available_tags"
      fi
    done <<<"$versioned_patterns"

    if [[ -n "$best_match" ]]; then
      echo "${prefix}:${best_match}"
      return 0
    fi

    # Second pass: other patterns
    while IFS= read -r pattern; do
      if [[ -n "$pattern" && "$pattern" != *"{canonical}"* ]]; then
        local resolved="${pattern//\{branch\}/$base_image_tag}"
        while IFS= read -r tag; do
          if [[ "$tag" == "$resolved" ]]; then
            echo "${prefix}:${tag}"
            return 0
          fi
        done <<<"$available_tags"
      fi
    done <<<"$versioned_patterns"
  fi

  # Fallback: {branch}-{version} where version < canonical
  local best_prev_tag="" best_prev_version=""

  while IFS= read -r tag; do
    if [[ "$tag" == "${base_image_tag}-"* ]]; then
      local tag_version="${tag#"${base_image_tag}"-}"
      if [[ "$tag_version" < "$canonical_tag" ]]; then
        if [[ -z "$best_prev_version" || "$tag_version" > "$best_prev_version" ]]; then
          best_prev_version="$tag_version"
          best_prev_tag="$tag"
        fi
      fi
    fi
  done <<<"$available_tags"

  if [[ -n "$best_prev_tag" ]]; then
    echo "${prefix}:${best_prev_tag}"
    return 0
  fi

  # Last fallback: branch tag
  while IFS= read -r tag; do
    if [[ "$tag" == "$base_image_tag" ]]; then
      echo "${prefix}:${tag}"
      return 0
    fi
  done <<<"$available_tags"

  return 1
}

# ── image existence check ───────────────────────────────────────────────────
# Usage: image_exists <image_ref>
# Returns: 0 if image exists, 1 otherwise (no retry — lightweight check)

image_exists() {
  local image_ref="$1"
  skopeo inspect "docker://${image_ref}" >/dev/null 2>&1
}

# ── get parent_version label ────────────────────────────────────────────────
# Usage: get_parent_version <image_ref>
# Prints: parent_version string on success
# Returns: 0 on success, 1 on failure or missing label

get_parent_version() {
  local image_ref="$1"
  local version
  version=$(skopeo inspect "docker://${image_ref}" 2>/dev/null | jq -r '.Labels["org.opencontainers.image.version"] // empty' 2>/dev/null) || true
  if [[ -n "$version" ]]; then
    echo "$version"
    return 0
  fi
  return 1
}

# ── find latest versioned tag ───────────────────────────────────────────────
# Usage: find_latest_versioned_tag <prefix> <base_image_tag>
# Finds the latest {branch}-{version} tag in the registry.
# Prints: tag name on success
# Returns: 0 on success, 1 on failure

find_latest_versioned_tag() {
  local prefix="$1"
  local base_image_tag="$2"
  local available_tags latest_versioned_tag="" latest_version=""

  available_tags=$(skopeo list-tags "docker://${prefix}" 2>/dev/null | jq -r '.Tags[]' 2>/dev/null) || return 1

  local tag tag_version
  while IFS= read -r tag; do
    if [[ "$tag" == "${base_image_tag}-"* ]]; then
      tag_version="${tag#"${base_image_tag}"-}"
      if [[ -z "$latest_version" || "$tag_version" > "$latest_version" ]]; then
        latest_version="$tag_version"
        latest_versioned_tag="$tag"
      fi
    fi
  done <<<"$available_tags"

  if [[ -n "$latest_versioned_tag" ]]; then
    echo "$latest_versioned_tag"
    return 0
  fi
  return 1
}

# ── check build needed ──────────────────────────────────────────────────────
# Usage: check_build_needed <prefix> <canonical> <variant_name> <base_image_tag> <upstream_parent_version> <force_build>
# Checks if build is needed for this variant.
# Returns: 0 if build needed, 1 if skip.
# Prints: REASON=<reason> to stdout (can be eval'd)

check_build_needed() {
  local prefix="$1"
  local canonical="$2"
  local variant_name="$3"
  local base_image_tag="$4"
  local upstream_parent_version="$5"
  local force_build="$6"

  if [[ "$force_build" == "true" ]]; then
    echo "REASON=\"Force build requested\""
    return 0
  fi

  # Determine primary tag for version comparison
  local primary_tag
  case "${base_image_tag}" in
  "stable") primary_tag="stable" ;;
  "testing") primary_tag="testing" ;;
  *) primary_tag="latest" ;;
  esac

  local primary_ref="${prefix}:${primary_tag}"

  # Strategy 1: Compare parent_version on primary tag
  if image_exists "$primary_ref"; then
    local local_parent_version
    if local_parent_version=$(inspect_image_with_retry "$primary_ref" | jq -r '.Labels["org.opencontainers.image.version"] // empty' 2>/dev/null) && [[ -n "$local_parent_version" ]]; then
      if [[ "$local_parent_version" == "$upstream_parent_version" ]]; then
        echo "REASON=\"Upstream unchanged (parent_version: ${upstream_parent_version})\""
        return 1
      fi
      echo "::notice::Variant ${variant_name}: Upstream changed (${local_parent_version} → ${upstream_parent_version})" >&2
      echo "REASON=\"Upstream changed (${local_parent_version} → ${upstream_parent_version})\""
      return 0
    fi
    echo "::debug::Primary tag exists but has no parent_version, falling back to versioned tags" >&2
  fi

  # Strategy 2: Primary tag missing or versionless — compare via latest versioned tag
  local latest_versioned_tag
  if latest_versioned_tag=$(find_latest_versioned_tag "$prefix" "$base_image_tag"); then
    echo "::debug::Using latest versioned tag: ${latest_versioned_tag}" >&2
    local local_parent_version
    if local_parent_version=$(get_parent_version "${prefix}:${latest_versioned_tag}"); then
      if [[ "$local_parent_version" == "$upstream_parent_version" ]]; then
        echo "::notice::Variant ${variant_name}: Upstream unchanged (via ${latest_versioned_tag})" >&2
        echo "REASON=\"Upstream unchanged (parent_version: ${upstream_parent_version})\""
        return 1
      fi
      echo "::notice::Variant ${variant_name}: Upstream changed via ${latest_versioned_tag} (${local_parent_version} → ${upstream_parent_version})" >&2
      echo "REASON=\"Upstream changed (${local_parent_version} → ${upstream_parent_version})\""
      return 0
    fi
    echo "::debug::Latest versioned tag ${latest_versioned_tag} has no parent_version" >&2
  fi

  # Strategy 3: No comparable image found — need to build
  echo "REASON=\"Target image does not exist\""
  return 0
}

# ── generate step summary ───────────────────────────────────────────────────
# Usage: generate_step_summary <results_json> <any_builds_needed> <registry> <repo> <step_summary_file>
# Generates markdown table for GitHub step summary.

generate_step_summary() {
  local results_json="$1"
  local any_builds_needed="$2"
  local registry="$3"
  local repo="$4"
  local step_summary_file="$5"

  [[ -z "$step_summary_file" ]] && return 0

  if [[ "$any_builds_needed" == "false" ]]; then
    {
      echo "## ⚠️ Build Skipped"
      echo "**Reason:** No variants have changes"
      echo ""
      echo "### 🚫 Skipped Variants"
      echo ""
      echo "| Variant | Target Image | Tags |"
      echo "|---------|--------------|------|"
    } >"$step_summary_file"
  else
    {
      echo "## 📦 Variants to Build"
      echo ""
      echo "| Variant | Target Image | Tags |"
      echo "|---------|--------------|------|"
    } >"$step_summary_file"
  fi

  echo "$results_json" | jq -c '.[]' | while IFS= read -r variant; do
    local name suffix tags collision target_image
    name=$(echo "$variant" | jq -r '.variant')
    suffix=$(echo "$variant" | jq -r '.suffix // ""')
    tags=$(echo "$variant" | jq -r '.tags')
    collision=$(echo "$variant" | jq -r '.collision_detected // false')
    target_image="${registry}/${repo}${suffix}"

    if [[ "$collision" == "true" ]]; then
      echo "| \`${name}\` | \`${target_image}\` | \`${tags}\` ⚠️ |"
    else
      echo "| \`${name}\` | \`${target_image}\` | \`${tags}\` |"
    fi
  done >>"$step_summary_file"
}
