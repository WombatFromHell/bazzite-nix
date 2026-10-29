# check-variants-tags.bash — tag computation and variant resolution for check-variants.
# Sourced by check-variants.sh and just-helpers.bash (no shebang/set — see those files).

# Budget for the collision bump walk in compute_canonical_tag: bounded so a
# registry that keeps holding bumped tags cannot be probed forever.
COLLISION_BUMP_WALK=5

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

# ── compute our version ────────────────────────────────────────────────────
# Usage: compute_canonical_tag <upstream_version> <prefix> [branch]
# Our version is the upstream version we were cut from, verbatim. It gains a minor
# version only when {branch}-{version} already exists in our registry — a force_build
# re-run of the same upstream release — and then walks to the next free counter.
# <prefix> is empty when no registry is known, so nothing is probed and nothing bumps.
# Prints: canonical collision_detected  — the bare version; collision_detected means
# the registry held our tag, which is what forced the bump.
compute_canonical_tag() {
  local upstream_version="$1"
  local prefix="$2"
  local branch="${3:-}"

  # Strip branch prefix (e.g., "testing-") to get pure version number
  local canonical
  if [[ "$upstream_version" =~ ^[a-zA-Z]+-([0-9].*)$ ]]; then
    canonical="${BASH_REMATCH[1]}"
  else
    canonical="$upstream_version"
  fi

  local candidate="$canonical" bumps=0 collision_detected="false" probe
  while [[ -n "$prefix" ]]; do
    probe="$candidate"
    [[ -n "$branch" ]] && probe="${branch}-${probe}"
    if ! skopeo inspect "docker://${prefix}:${probe}" >/dev/null 2>&1; then
      break
    fi
    collision_detected="true"
    echo "::notice::${probe} already exists, checking next..." >&2
    # Next counter: upstream's counter +1, or a fresh .1 on a bare version.
    if [[ "$candidate" =~ ^(.*)\.([0-9]+)$ ]] && ((${#BASH_REMATCH[2]} < 4)); then
      candidate="${BASH_REMATCH[1]}.$((10#${BASH_REMATCH[2]} + 1))"
    else
      candidate="${candidate}.1"
    fi
    ((bumps++))
    if ((bumps >= COLLISION_BUMP_WALK)); then
      fail "${COLLISION_BUMP_WALK} bumped tags after ${canonical} already exist; stopping the bump walk"
      return 1
    fi
  done

  echo "$candidate $collision_detected"
}

# Does this tag template want the image digest, which push resolves later?
# Usage: tag_needs_digest <tag_template>
tag_needs_digest() {
  local template="${1:?tag template required}"
  [[ "$template" == *"{sha256}"* ]]
}

# ── generate tags ───────────────────────────────────────────────────────────
# Usage: generate_tags <base_image_tag> <canonical> <latest> <tags_json>
# Generates comma-separated tags based on configuration.
# Supports {canonical}, {branch}, {major}, {sha256} placeholders in tags_json.versioned.

generate_tags() {
  local base_image_tag="$1"
  local canonical="$2"
  local latest="$3"
  local tags_json="$4"
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
        if tag_needs_digest "$versioned_tag"; then
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
# Resolve a variant name or an explicit image:tag spec into one JSON record.
# Usage: resolve_variant <variant_or_spec> [variants_config] [image_name] [registry]
# Record: {variant, tag, target_image, base_image, build_script, suffix, latest,
#          canonical_tag, version_tag, upstream_tag, upstream_version, tag_family,
#          collision_detected, tags}  — a superset of the CI matrix entry shape.
# version_tag is the {branch}-{canonical} version this build embeds and pushes.
# registry (4th arg): the namespace to probe for tags we already published; when empty
# it is derived from GITHUB_REPOSITORY_OWNER / the Justfile's repo_organization.
# Returns: 0 a record was printed; 1 the variant cannot be identified (unknown/disabled
# name, base label is not a release version, the upstream search could not complete);
# 2 it has no version to build against right now — upstream probed every name and none
# names the labelled build (published before tagging), or no free tag within
# COLLISION_BUMP_WALK bumps — so a caller may skip it and keep going.
resolve_variant() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:?image_name required}"
  local registry="${4:-}"
  local spec row base_image build_script suffix image_name_resolved tag canonical
  local latest tags_json tags_csv version_tag collision_detected bump upstream_rc
  local base_label base_version upstream_tag upstream_version tag_family identity

  spec="$variant_or_spec"

  # If it looks like an explicit image:tag or image ref, pass it through unchanged
  if [[ "$spec" == *"/"* ]] || [[ "$spec" == *":"* ]]; then
    tag="${spec##*:}"
    build_script=$(jq -r --arg bi "$spec" '
            .variants[] | select(.base_image == $bi and .disabled != true)
            | (.build_script // "build.sh")
        ' "$variants_config" | head -1)
    [[ -z "$build_script" ]] && build_script="build.sh"
    # Extract real version from upstream image label
    canonical="$(get_parent_version "$spec")" || canonical="$tag"
    # No variants.json entry to source a tags template from — single-tag fallback,
    # and the version we embed is the tag the spec pushes.
    tags_csv="$tag"
    jq -cn --arg variant "$tag" --arg tag "$tag" --arg target_image "$(image_ref "$image_name")" \
      --arg base_image "$spec" --arg build_script "$build_script" --arg canonical_tag "$canonical" \
      --arg version_tag "$tag" --arg tags "$tags_csv" --arg upstream_version "$canonical" \
      '{variant: $variant, tag: $tag, target_image: $target_image, base_image: $base_image,
       build_script: $build_script, suffix: "", latest: false, canonical_tag: $canonical_tag,
       version_tag: $version_tag, upstream_tag: "", upstream_version: $upstream_version,
       tag_family: "", collision_detected: false, tags: $tags}'
    return 0
  fi

  # Look up variant by name
  row=$(variant_record "$spec" "$variants_config" 2>/dev/null) || row=""
  if [[ -z "$row" || "$(jq -r '.disabled' <<<"$row")" == "true" ]]; then
    echo "ERROR: Unknown or disabled variant: $spec" >&2
    echo "Available variants:" >&2
    enabled_variant_names "$variants_config" | sed 's/^/  /' >&2
    return 1
  fi

  base_image=$(echo "$row" | jq -r '.base_image')
  build_script=$(echo "$row" | jq -r '.build_script // "build.sh"')
  suffix=$(echo "$row" | jq -r '.suffix // ""')
  latest=$(echo "$row" | jq -r '.latest // false')
  tags_json=$(echo "$row" | jq -c '.tags // empty')
  image_name_resolved="$image_name${suffix}"
  tag="${base_image##*:}"

  # Canonical version comes from upstream's git tag, the same rule CI uses:
  # the base image's own label version is probed against upstream's two naming
  # forms, and the tag that resolves names the release we are cutting from.
  base_label="$(get_parent_version "$base_image")" || base_label="$tag"
  base_version="$(version_of_tag "$base_label" "$spec")"
  # A version label that is not a release version (`latest`, a moving tag) names no
  # release, so it is an error rather than something to probe upstream against.
  if [[ ! "$base_version" =~ $VERSIONED_TAG_PATTERN ]]; then
    echo "ERROR: base image $base_image is labelled $base_label, which is not a release version" >&2
    return 1
  fi
  identity=$(resolve_upstream_tag "$(upstream_repo "$base_image")" "$spec" "$base_version") || {
    upstream_rc=$?
    [[ $upstream_rc -eq 1 ]] &&
      echo "ERROR: the upstream search for $base_version of branch $spec in $(upstream_repo "$base_image") could not complete" >&2
    return "$upstream_rc"
  }
  read -r upstream_tag upstream_version tag_family <<<"$identity"
  canonical="$upstream_version"
  echo "::notice::Upstream identity for $spec: git tag $upstream_tag (family $tag_family)" >&2

  # Our version is upstream's verbatim; only a tag we already published forces a bump.
  # check-variants.sh passes REGISTRY explicitly (the CI namespace); local callers omit
  # it, so the namespace is derived from the owner identity (GITHUB_REPOSITORY_OWNER /
  # repo_organization), and with no owner there is nothing to probe.
  local registry_prefix="$registry"
  if [[ -n "$registry_prefix" ]]; then
    registry_prefix="${registry_prefix}/${image_name_resolved}"
  else
    local owner
    owner="$(registry_owner)"
    if [[ -n "$owner" ]]; then
      registry_prefix="$(registry_url "$owner")/${image_name_resolved}"
    else
      warn "no registry to probe; our version stays upstream's"
    fi
  fi

  bump="$(compute_canonical_tag "$canonical" "$registry_prefix" "$spec")" || {
    echo "ERROR: no free version tag within $COLLISION_BUMP_WALK bumps of $canonical in ${registry_prefix:-$canonical}" >&2
    return 2
  }
  read -r canonical collision_detected <<<"$bump"
  version_tag="${spec}-${canonical}"

  # Use the variant's config name as the branch — not $tag, which for variants
  # like "testing" is the base image's dated suffix (e.g. "testing-44.20260814"),
  # not a plain branch name. This mirrors check-variants.sh, which passes the
  # variant .name into compute_canonical_tag/generate_tags.
  # No digest is passed: {sha256} tags are resolved at push time from the built
  # image's digest (mirrors check-variants.sh).
  tags_csv=$(generate_tags "$spec" "$canonical" "$latest" "$tags_json")

  jq -cn --arg variant "$spec" --arg tag "$spec" --arg target_image "$(image_ref "$image_name_resolved")" \
    --arg base_image "$base_image" --arg build_script "$build_script" --arg suffix "$suffix" \
    --arg canonical_tag "$canonical" --arg version_tag "$version_tag" \
    --arg upstream_tag "$upstream_tag" --arg upstream_version "$upstream_version" \
    --arg tag_family "$tag_family" --arg tags "$tags_csv" --arg latest "$latest" \
    --arg collision_detected "$collision_detected" \
    '{variant: $variant, tag: $tag, target_image: $target_image, base_image: $base_image,
     build_script: $build_script, suffix: $suffix, latest: ($latest == "true"), canonical_tag: $canonical_tag,
     version_tag: $version_tag, upstream_tag: $upstream_tag, upstream_version: $upstream_version,
     tag_family: $tag_family, collision_detected: ($collision_detected == "true"), tags: $tags}'
}
