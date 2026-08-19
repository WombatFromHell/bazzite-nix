# check-variants-resolve.bash — variant resolution for check-variants.
# Sourced by check-variants-helpers.bash (no shebang/set — see umbrella).

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
    canonical=$(skopeo inspect "docker://${spec}" 2>/dev/null |
      jq -r '.Labels["org.opencontainers.image.version"] // empty' ||
      true)
    [[ -z "$canonical" || "$canonical" == "null" ]] && canonical="$tag"
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
  local inspect_json
  inspect_json=$(skopeo inspect "docker://${base_image}" 2>/dev/null) || true
  canonical=$(echo "$inspect_json" | jq -r '.Labels["org.opencontainers.image.version"] // empty' 2>/dev/null || true)
  [[ -z "$canonical" || "$canonical" == "null" ]] && canonical="$tag"

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
