# check-variants-tags.bash — tag computation for check-variants.
# Sourced by check-variants-helpers.bash (no shebang/set — see umbrella).

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
# Usage: compute_canonical_tag <parent_version> <prefix> <force_build> <branch>
# Computes canonical tag, handling version collisions when force_build is true.
# Checks for <branch>-<canonical> tags in the registry to match what is actually pushed.
# Prints: canonical collision_detected

compute_canonical_tag() {
  local parent_version="$1"
  local prefix="$2"
  local force_build="$3"
  local branch="${4:-}"

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

  # Construct the full tag to check, matching what is actually pushed.
  # If a branch is provided, check <branch>-<canonical> (e.g., testing-44.20260520.2).
  local check_tag="$canonical"
  if [[ -n "$branch" ]]; then
    check_tag="${branch}-${canonical}"
  fi

  if ! skopeo inspect "docker://${prefix}:${check_tag}" >/dev/null 2>&1; then
    echo "$canonical $collision_detected"
    return 0
  fi

  echo "::notice::Collision detected: ${check_tag} exists. Calculating next version..." >&2
  collision_detected="true"

  # Parse version number and increment
  local next_num=1
  local search_base="$canonical"

  if [[ "$canonical" =~ ^(.*)\.([0-9]+)$ ]] && [ ${#BASH_REMATCH[2]} -lt 4 ]; then
    search_base="${BASH_REMATCH[1]}"
    next_num=$((BASH_REMATCH[2] + 1))
  fi

  while true; do
    local next_canonical="${search_base}.${next_num}"
    local next_check_tag="$next_canonical"
    if [[ -n "$branch" ]]; then
      next_check_tag="${branch}-${next_canonical}"
    fi
    if ! skopeo inspect "docker://${prefix}:${next_check_tag}" >/dev/null 2>&1; then
      break
    fi
    echo "::notice::${next_check_tag} also exists, checking next..." >&2
    ((next_num++))
  done

  canonical="${search_base}.${next_num}"
  echo "$canonical $collision_detected"
}

# ── generate tags ───────────────────────────────────────────────────────────
# Usage: generate_tags <base_image_tag> <canonical> <latest> <tags_json> <digest>
# Generates comma-separated tags based on configuration.
# Supports {canonical}, {branch}, {major}, {sha256} placeholders in tags_json.versioned.

generate_tags() {
  local base_image_tag="$1"
  local canonical="$2"
  local latest="$3"
  local tags_json="$4"
  local digest="${5:-}"
  local major="${canonical%%.*}"
  local tags_array=()

  if [[ -n "$tags_json" && "$tags_json" != "null" ]]; then
    local tags_branch tags_versioned
    tags_branch=$(echo "$tags_json" | jq -r '.branch // empty')
    tags_versioned=$(echo "$tags_json" | jq -r '.versioned // [] | .[]' 2>/dev/null)
    local branch="${tags_branch:-$base_image_tag}"

    while IFS= read -r versioned_tag; do
      if [[ -n "$versioned_tag" ]]; then
        versioned_tag="${versioned_tag//\{canonical\}/$canonical}"
        versioned_tag="${versioned_tag//\{branch\}/$branch}"
        versioned_tag="${versioned_tag//\{major\}/$major}"
        if [[ -n "$digest" ]]; then
          versioned_tag="${versioned_tag//\{sha256\}/$digest}"
        elif [[ "$versioned_tag" == *"{sha256}"* ]]; then
          continue
        fi
        tags_array+=("$versioned_tag")
      fi
    done <<<"$tags_versioned"
  else
    # ponytail: default mirrors the unstable variant's versioned list; update both if unstable changes
    tags_array+=("${base_image_tag}-${canonical}" "${base_image_tag}-${major}" "${base_image_tag}")
  fi

  # latest goes last — it's an alias, never the anchor tag rechunk/relabel compose against
  [[ "$latest" == "true" ]] && tags_array+=("latest")

  (
    IFS=,
    echo "${tags_array[*]}"
  )
}
