# check-variants-registry.bash — skopeo/registry primitives and the build-needed
# decision for check-variants.
# Sourced by check-variants.sh and just-helpers.bash (no shebang/set — see those files).

# Retry configuration
MAX_RETRIES=3
RETRY_DELAY=10

# The image package namespace: owner-derived, lowercase (ADR 0006).
# Usage: registry_url <owner>
registry_url() {
  echo "ghcr.io/${1,,}"
}

# The owner half of the ghcr namespace: CI's GITHUB_REPOSITORY_OWNER, else the
# Justfile's repo_organization.
# Usage: registry_owner
registry_owner() {
  echo "${GITHUB_REPOSITORY_OWNER:-${repo_organization:-}}"
}

# The package name inside that namespace: the repository name, lowercase, with
# the owner half stripped when a full owner/name repository was given. Falls
# back to GITHUB_REPOSITORY when no repository is passed.
# Usage: package_repo [repo]
package_repo() {
  local repo="${1:-${GITHUB_REPOSITORY:-}}"
  repo="${repo#*/}"
  echo "${repo,,}"
}

# ── variant lookup ────────────────────────────────────────────────────────
# The one place that answers "does this variant exist": its record, with the
# disabled flag filled in so callers decide the policy. Unknown names fail,
# listing the enabled ones.
# Usage: variant_record <name> [variants_config]
variant_record() {
  local variant="${1:?variant required}"
  local variants_config="${2:-.github/variants.json}"
  local record
  record=$(jq -c --arg n "$variant" '.variants[] | select(.name == $n) | . + {disabled: (.disabled // false), variant: .name}' "$variants_config")
  if [[ -z "$record" ]]; then
    echo "Variant '${variant}' not found in ${variants_config}. Available: $(enabled_variant_names "$variants_config" | paste -sd ', ' -)" >&2
    return 1
  fi
  printf '%s\n' "$record"
}

# Variant names, one per line; the enabled form skips disabled variants.
# Usage: variant_names [variants_config]
variant_names() {
  jq -r '.variants[].name' "${1:-.github/variants.json}"
}

enabled_variant_names() {
  jq -r '.variants[] | select(.disabled != true) | .name' "${1:-.github/variants.json}"
}

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

# Decide build-needed from a fetched parent_version. Prints the REASON= line;
# returns 0 (build needed) if it differs from upstream, 1 (skip) if identical.
# Callers pass a non-empty local_version (the "no usable label" case is the
# caller's to fall through on).
version_check() {
  local local_version="${1:?local_version required}"
  local variant_name="${2:?variant_name required}"
  local upstream="${3:?upstream required}"
  local via="${4:-}"

  local via_note=""
  [[ -n "$via" ]] && via_note=" via ${via}"
  if [[ "$local_version" == "$upstream" ]]; then
    [[ -n "$via" ]] && echo "::notice::Variant ${variant_name}: Upstream unchanged (via ${via})" >&2
    echo "REASON=\"Upstream unchanged (parent_version: ${upstream})\""
    return 1
  fi
  echo "::notice::Variant ${variant_name}: Upstream changed${via_note} (${local_version} → ${upstream})" >&2
  echo "REASON=\"Upstream changed (${local_version} → ${upstream})\""
  return 0
}

# ── check build needed ──────────────────────────────────────────────────────
# Usage: check_build_needed <prefix> <variant_name> <base_image_tag> <upstream_parent_version> <force_build>
# Checks if build is needed for this variant.
# Returns: 0 if build needed, 1 if skip.
# Prints: REASON=<reason> to stdout (can be eval'd)

check_build_needed() {
  local prefix="$1"
  local variant_name="$2"
  local base_image_tag="$3"
  local upstream_parent_version="$4"
  local force_build="$5"

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
    local local_parent_version=""
    local_parent_version=$(inspect_image_with_retry "$primary_ref" | jq -r '.Labels["org.opencontainers.image.version"] // empty' 2>/dev/null) || true
    if [[ -n "$local_parent_version" ]]; then
      version_check "$local_parent_version" "$variant_name" "$upstream_parent_version" && return 0 || return 1
    fi
    echo "::debug::Primary tag exists but has no parent_version, falling back to versioned tags" >&2
  fi

  # Strategy 2: Primary tag missing or versionless — compare via latest versioned tag
  local latest_versioned_tag
  if latest_versioned_tag=$(find_latest_versioned_tag "$prefix" "$base_image_tag"); then
    echo "::debug::Using latest versioned tag: ${latest_versioned_tag}" >&2
    local local_parent_version
    if local_parent_version=$(get_parent_version "${prefix}:${latest_versioned_tag}"); then
      version_check "$local_parent_version" "$variant_name" "$upstream_parent_version" "$latest_versioned_tag" && return 0 || return 1
    fi
    echo "::debug::Latest versioned tag ${latest_versioned_tag} has no parent_version" >&2
  fi

  # Strategy 3: No comparable image found — need to build
  echo "REASON=\"Target image does not exist\""
  return 0
}
