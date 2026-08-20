# check-variants-tags.bash — tag computation and variant resolution for check-variants.
# Sourced by check-variants.sh and just-helpers.bash (no shebang/set — see those files).

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

# ── Variant resolution ──────────────────────────────────────────────────────
# Resolve a variant name from variants.json into shell variable assignments
# Usage: eval "$(resolve_variant "testing" ".github/variants.json" "bazzite-nix" "1" "ghcr.io/owner")"
# force_build (4th arg, default "0"): enable version-collision handling like CI.
# registry (5th arg, default derived from GITHUB_REPOSITORY_OWNER / repo_organization).
resolve_variant() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local force_build="${4:-0}"
  local registry="${5:-}"
  local spec row base_image build_script suffix image_name_resolved tag canonical
  local latest tags_json tags_csv collision_detected

  spec="$variant_or_spec"

  # Normalize force_build to CI's "true"/"false" dialect
  if [[ "$force_build" == "1" || "$force_build" == "true" ]]; then
    force_build="true"
  else
    force_build="false"
  fi

  # If it looks like an explicit image:tag or image ref, pass it through unchanged
  if [[ "$spec" == *"/"* ]] || [[ "$spec" == *":"* ]]; then
    tag="${spec##*:}"
    build_script=$(jq -r --arg bi "$spec" '
            .variants[] | select(.base_image == $bi and (.disabled // false) == false)
            | (.build_script // "build.sh")
        ' "$variants_config" | head -1)
    [[ -z "$build_script" ]] && build_script="build.sh"
    # Extract real version from upstream image label
    canonical="$(get_parent_version "$spec")" || canonical="$tag"
    # No variants.json entry to source a tags template from — single-tag fallback
    tags_csv="$tag"
    echo "TARGET_IMAGE=\"localhost/$image_name\""
    echo "TAG=\"$tag\""
    echo "BASE_IMAGE=\"$spec\""
    echo "BUILD_SCRIPT=\"$build_script\""
    echo "VARIANT_NAME=\"$tag\""
    echo "CANONICAL_TAG=\"$canonical\""
    echo "TAGS=\"$tags_csv\""
    return 0
  fi

  # Look up variant by name
  row=$(jq -r --arg n "$spec" '
        .variants[]
        | select(.name == $n and (.disabled // false) == false)
    ' "$variants_config")
  if [[ -z "$row" ]]; then
    echo "ERROR: Unknown or disabled variant: $spec" >&2
    echo "Available variants:" >&2
    jq -r '.variants[] | select((.disabled // false) == false) | "  " + .name' "$variants_config" >&2
    return 1
  fi

  base_image=$(echo "$row" | jq -r '.base_image')
  build_script=$(echo "$row" | jq -r '.build_script // "build.sh"')
  suffix=$(echo "$row" | jq -r '.suffix // ""')
  latest=$(echo "$row" | jq -r '.latest // false')
  tags_json=$(echo "$row" | jq -c '.tags // empty')
  image_name_resolved="$image_name${suffix}"
  tag="${base_image##*:}"

  # Extract real version from upstream image label
  canonical="$(get_parent_version "$base_image")" || canonical="$tag"

  # Strip branch prefix from canonical and handle version collisions the same way
  # CI does (compute_canonical_tag): on force_build, if <branch>-<canonical> already
  # exists in the registry, bump the patch number. Registry defaults to
  # ghcr.io/<owner>; owner comes from GITHUB_REPOSITORY_OWNER or the Justfile's
  # exported repo_organization.
  collision_detected="false"
  local registry_prefix="$registry"
  if [[ -n "$registry_prefix" ]]; then
    registry_prefix="${registry_prefix}/${image_name_resolved}"
  elif [[ "$force_build" == "true" ]]; then
    local owner="${GITHUB_REPOSITORY_OWNER:-${repo_organization:-}}"
    if [[ -n "$owner" ]]; then
      registry_prefix="ghcr.io/${owner,,}/${image_name_resolved}"
    else
      echo "::warning::force_build collision handling needs GITHUB_REPOSITORY_OWNER (or a registry arg); skipping collision check" >&2
    fi
  fi

  if [[ -n "$registry_prefix" ]]; then
    read -r canonical collision_detected <<<"$(compute_canonical_tag "$canonical" "$registry_prefix" "$force_build" "$spec")"
  elif [[ "$canonical" =~ ^[a-zA-Z]+-([0-9].*)$ ]]; then
    canonical="${BASH_REMATCH[1]}"
  fi

  # Use the variant's config name as the branch — not $tag, which for variants
  # like "testing" is the base image's dated suffix (e.g. "testing-44.20260814"),
  # not a plain branch name. This mirrors check-variants.sh, which passes the
  # variant .name into compute_canonical_tag/generate_tags.
  # No digest is passed: {sha256} tags are resolved at push time from the built
  # image's digest (mirrors check-variants.sh).
  tags_csv=$(generate_tags "$spec" "$canonical" "$latest" "$tags_json" "")

  echo "TARGET_IMAGE=\"localhost/$image_name_resolved\""
  echo "TAG=\"${spec}\""
  echo "BASE_IMAGE=\"${base_image}\""
  echo "BUILD_SCRIPT=\"${build_script}\""
  echo "VARIANT_NAME=\"${spec}\""
  echo "CANONICAL_TAG=\"$canonical\""
  echo "COLLISION_DETECTED=\"$collision_detected\""
  echo "TAGS=\"$tags_csv\""
}
