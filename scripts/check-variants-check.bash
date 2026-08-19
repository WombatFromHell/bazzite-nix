# check-variants-check.bash — build-needed decision for check-variants.
# Sourced by check-variants-helpers.bash (no shebang/set — see umbrella).

# ── check build needed ──────────────────────────────────────────────────────
# Usage: check_build_needed <prefix> <canonical> <variant_name> <base_image_tag> <upstream_parent_version> <force_build>
# Checks if build is needed for this variant.
# Returns: 0 if build needed, 1 if skip.
# Prints: REASON=<reason> to stdout (can be eval'd)

check_build_needed() {
  local prefix="$1"
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
