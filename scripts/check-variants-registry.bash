# check-variants-registry.bash — skopeo/registry primitives and the build-needed
# decision for check-variants.
# Sourced by check-variants.sh and just-helpers.bash (no shebang/set — see those files).

# Retry configuration
MAX_RETRIES=3
RETRY_DELAY=10

# How many build counters to try when upstream has published a container build
# but not its git tag yet (upstream names releases {major}.{date}.{build}).
UPSTREAM_BUILD_WALK=5

# A version is {major}.{YYYYMMDD}[.{build}]; moving tags such as {branch}-{major}
# do not match and are never treated as a version.
VERSIONED_TAG_PATTERN='^[0-9]+\.[0-9]{8}(\.[0-9]+)?$'

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

# ── registry read with retry ────────────────────────────────────────────────
# The one attempt loop every skopeo read of the registry uses. A read counts
# as failed when it exits non-zero or prints something jq cannot parse, so a
# truncated response is retried instead of reading as "this tag is not there".
# Usage: read_registry_json <label> <skopeo arguments...>
# Prints: the command's stdout on success
# Returns: 0 on success, 1 after MAX_RETRIES attempts

read_registry_json() {
  local label="$1"
  shift

  local attempt output
  for attempt in $(seq 1 "$MAX_RETRIES"); do
    if output=$("$@" 2>/dev/null) && [[ -n "$output" ]] && echo "$output" | jq empty 2>/dev/null; then
      printf '%s\n' "$output"
      return 0
    fi

    echo "::debug::Attempt ${attempt}/${MAX_RETRIES}: Failed to ${label}" >&2
    [[ "$attempt" -lt "$MAX_RETRIES" ]] && sleep "$RETRY_DELAY"
  done

  fail "Failed to ${label} after ${MAX_RETRIES} attempts"
  return 1
}

# ── inspect image with retry ────────────────────────────────────────────────
# Usage: inspect_image_with_retry <image_ref>
# Outputs: Echoes skopeo inspect JSON on success
# Returns: 0 on success, 1 on failure after all retries

inspect_image_with_retry() {
  local image_ref="$1"
  read_registry_json "inspect ${image_ref}" skopeo inspect "docker://${image_ref}"
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

# Strip a branch prefix from a tag name to get its version: {branch}-{version} -> {version},
# and a bare {version} passes through unchanged (upstream stable tags are bare).
# Usage: version_of_tag <tag> <branch>
# Prints: the version
version_of_tag() {
  local tag="${1:?tag required}"
  local branch="${2:?branch required}"
  local prefix="${branch}-"
  if [[ "$tag" == "$prefix"* ]]; then
    printf '%s\n' "${tag:${#prefix}}"
    return 0
  fi
  printf '%s\n' "$tag"
}

# Upstream version an image we published was cut from, read back from its own
# labels: the exact upstream tag name in org.opencontainers.image.upstream-version
# (every image built since that label exists), or the plain version label for
# releases published before it, whose value already held the upstream version.
# Usage: upstream_version_of_our_image <image_ref> <branch>
# Prints: the version on success; returns 1 when the image carries neither label
upstream_version_of_our_image() {
  local image_ref="${1:?image ref required}"
  local branch="${2:?branch required}"
  local labels tag version

  labels=$(skopeo inspect "docker://${image_ref}" 2>/dev/null | jq '.Labels // {}') || return 1

  tag=$(jq -r '.["org.opencontainers.image.upstream-version"] // empty' <<<"$labels")
  if [[ -n "$tag" ]]; then
    version_of_tag "$tag" "$branch"
    return 0
  fi

  version=$(jq -r '.["org.opencontainers.image.version"] // empty' <<<"$labels")
  [[ -n "$version" ]] || return 1
  version_of_tag "$version" "$branch"
}

# ── find latest versioned tag ───────────────────────────────────────────────
# Usage: find_latest_versioned_tag <prefix> <branch>
# Finds the latest {branch}-{version} tag of one variant branch in the registry.
# Prints: tag name on success
# Returns: 0 on success, 1 when the branch has no versioned tag

find_latest_versioned_tag() {
  local prefix="$1"
  local branch="${2:?branch required}"
  local available_tags
  local versions=()

  available_tags=$(read_registry_json "list tags of ${prefix}" skopeo list-tags "docker://${prefix}") || return 1

  local tag tag_version
  while IFS= read -r tag; do
    [[ "$tag" == "${branch}-"* ]] || continue
    tag_version=$(version_of_tag "$tag" "$branch")
    if [[ "$tag_version" =~ $VERSIONED_TAG_PATTERN ]]; then
      versions+=("$tag_version")
    fi
  done < <(jq -r '.Tags[]' <<<"$available_tags")

  if [[ "${#versions[@]}" -eq 0 ]]; then
    return 1
  fi

  tag_version=$(printf '%s\n' "${versions[@]}" | sort -V | tail -1)
  echo "${branch}-${tag_version}"
}

# ── upstream git identity ───────────────────────────────────────────────────
# The upstream GitHub repository behind a base image reference: the ghcr
# namespace and the repository are the same name for every upstream image here.
# Usage: upstream_repo <base_image>
# Prints: <owner>/<package>

upstream_repo() {
  local base_image="${1:?base image required}"
  local package="${base_image#ghcr.io/}"
  printf '%s\n' "${package%%:*}"
}

# Upstream git tag that names a variant's release, found by exact-name probe
# instead of paging the tag list: upstream pushes 40+ tags a day, so a page
# window never reaches an older branch. The version comes from the base image's
# own label; upstream names that release either "{branch}-{version}" (its
# testing and unstable builds) or a bare "{version}" (its stable build), tried
# in that order, and each family is walked down its build counter, because
# upstream publishes container builds a few counters before tagging them.
# Every name probed and missed means that build is not tagged yet, so the
# answer is 2 and a caller may skip the variant; a search cut short by the
# walk budget, or a probe upstream refused, means we do not know, which is 1.
# Usage: resolve_upstream_tag <upstream_repo> <branch> <version>
# Prints: "<git tag name> <version> <family>" on success, where <version> is
# the one upstream actually named
# Returns: 1 a probe was refused or the walk budget cut the search short; 2
# every name in both families was probed and none names that build
resolve_upstream_tag() {
  local upstream="${1:?upstream repo required}"
  local branch="${2:?branch required}"
  local version="${3:?version required}"
  local headers=(-s -H "Accept: application/vnd.github+json")
  if [[ -n "${GH_TOKEN:-}" ]]; then
    headers+=(-H "Authorization: Bearer ${GH_TOKEN}")
  fi

  local family tag json head_sha candidate msg
  local -a candidates=()
  mapfile -t candidates < <(upstream_version_candidates "$version")

  for family in prefixed bare-version; do
    for candidate in "${candidates[@]}"; do
      if [[ "$family" == "prefixed" ]]; then
        tag="${branch}-${candidate}"
      else
        tag="$candidate"
      fi

      json=$(read_registry_json "probe upstream tag ${tag} of ${upstream}" curl "${headers[@]}" "https://api.github.com/repos/${upstream}/commits/${tag}") || return 1

      head_sha=$(jq -r '.sha // empty' <<<"$json")
      if [[ -n "$head_sha" ]]; then
        printf '%s\n' "$tag $candidate $family"
        return 0
      fi

      msg=$(jq -r '.message // "no such ref"' <<<"$json")
      if [[ "$msg" == *"rate limit"* ]]; then
        echo "  upstream refused the probe for ${tag}: ${msg}" >&2
        return 1
      fi
      echo "  upstream has no tag ${tag}: ${msg}" >&2
    done
  done

  if ((${#candidates[@]} >= UPSTREAM_BUILD_WALK)); then
    fail "No upstream git tag for version ${version} of branch ${branch} in ${upstream}: stopped after ${UPSTREAM_BUILD_WALK} build counters"
    return 1
  fi
  warn "No upstream git tag names build ${version} of branch ${branch} in ${upstream}; upstream published that build before tagging it"
  return 2
}

# Versions upstream might have named, newest first: the labelled version and the
# same date's lower build counters, up to UPSTREAM_BUILD_WALK names.
# Usage: upstream_version_candidates <version>
upstream_version_candidates() {
  local version="${1:?version required}"
  local -a candidates=("$version")

  if [[ "$version" =~ ^([0-9]+\.[0-9]{8})\.([0-9]+)$ ]]; then
    local base="${BASH_REMATCH[1]}"
    local counter="10#${BASH_REMATCH[2]}"
    local walked=1
    while ((counter > 1 && walked < UPSTREAM_BUILD_WALK)); do
      counter=$((counter - 1))
      candidates+=("$base.$counter")
      walked=$((walked + 1))
    done
  fi

  printf '%s\n' "${candidates[@]}"
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
# Usage: check_build_needed <prefix> <branch> <upstream_parent_version> <force_build>
# Checks if build is needed for this variant branch. The branch is its own primary
# tag, so the decision never compares another variant's newest tag.
# Returns: 0 if build needed, 1 if skip.
# Prints: REASON=<reason> to stdout (can be eval'd)

check_build_needed() {
  local prefix="$1"
  local branch="${2:?branch required}"
  local upstream_parent_version="$3"
  local force_build="${4:-false}"

  if [[ "$force_build" == "true" ]]; then
    echo "REASON=\"Force build requested\""
    return 0
  fi

  # Determine primary tag for version comparison
  local primary_tag="$branch"
  local primary_ref="${prefix}:${primary_tag}"

  # Strategy 1: Compare the upstream identity our own primary tag carries
  if image_exists "$primary_ref"; then
    local local_parent_version=""
    local_parent_version=$(upstream_version_of_our_image "$primary_ref" "$branch") || true
    if [[ -n "$local_parent_version" ]]; then
      version_check "$local_parent_version" "$branch" "$upstream_parent_version" && return 0 || return 1
    fi
    echo "::debug::Primary tag exists but carries no upstream identity, falling back to versioned tags" >&2
  fi

  # Strategy 2: Primary tag missing or versionless — compare via latest versioned tag
  local latest_versioned_tag
  if latest_versioned_tag=$(find_latest_versioned_tag "$prefix" "$branch"); then
    echo "::debug::Using latest versioned tag: ${latest_versioned_tag}" >&2
    local local_parent_version
    if local_parent_version=$(upstream_version_of_our_image "${prefix}:${latest_versioned_tag}" "$branch"); then
      version_check "$local_parent_version" "$branch" "$upstream_parent_version" "$latest_versioned_tag" && return 0 || return 1
    fi
    echo "::debug::Latest versioned tag ${latest_versioned_tag} carries no upstream identity" >&2
  fi

  # Strategy 3: No comparable image found — need to build
  echo "REASON=\"Target image does not exist\""
  return 0
}
