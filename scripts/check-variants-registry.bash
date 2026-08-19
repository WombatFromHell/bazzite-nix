# check-variants-registry.bash — skopeo/registry primitives for check-variants.
# Sourced by check-variants-helpers.bash (no shebang/set — see umbrella).

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
