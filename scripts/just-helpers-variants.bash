# just-helpers-variants.bash — variant check/aggregate/preview and release
# resolution functions for just-helpers.
# Sourced by just-helpers.bash (no shebang/set — see umbrella).

# Preview which alias tags (and the step-summary markdown) a build would generate
# Usage: preview_tags <variants_csv> [variants_config] <image_name> <repo_organization>
# In CI (GITHUB_STEP_SUMMARY set), appends the pending-builds markdown table to the step summary.
preview_tags() {
  local variants_csv="${1:?variants_csv required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:?image_name required}"
  local repo_organization="${4:?repo_organization required}"
  local specs=()
  IFS=',' read -ra specs <<<"$variants_csv"

  local registry
  registry="$(registry_url "$repo_organization")"

  local spec variant version_tag tags target_image suffix record
  local rows=()
  for spec in "${specs[@]}"; do
    record=$(resolve_variant "$spec" "$variants_config" "$image_name")
    IFS=$'\037' read -r variant version_tag tags target_image < <(jq -r '[.variant, .version_tag, .tags, .target_image] | join("\u001f")' <<<"$record")
    suffix="${target_image#localhost/"${image_name}"}"
    rows+=("| \`${variant}\` | \`${registry}/${image_name}${suffix}\` | \`${tags}\` |")
    if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "== Tags that would be generated for '${variant}' =="
      echo "Version tag   : ${version_tag}"
      echo "Alias tags    : ${tags}"
      echo ""
    fi
  done

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## 📦 Variants to Build"
      echo ""
      echo "| Variant | Target Image | Tags |"
      echo "|---------|--------------|------|"
      printf '%s\n' "${rows[@]}"
    } >>"$GITHUB_STEP_SUMMARY"
  else
    echo "| Variant | Target Image | Tags |"
    echo "|---------|--------------|------|"
    printf '%s\n' "${rows[@]}"
  fi
}

# ── Variant aggregation ─────────────────────────────────────────────────────

# Check which variants need rebuilding (mirrors check-variants action)
# Writes results to $ARTIFACTS_DIR/variants_results.json
check_variants() {
  local force_build="${1:-0}"
  local repo_organization="${2:?repo_organization required}"
  local image_name="${3:?image_name required}"
  local variants_config="${4:-.github/variants.json}"
  local variants_override="${5:-}"

  local registry date_iso image_desc

  registry="$(registry_url "$repo_organization")"
  image_desc="$DEFAULT_IMAGE_DESC"
  date_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  REGISTRY="$registry" \
    REPO="$image_name" \
    IMAGE_DESC="$image_desc" \
    DATE="$date_iso" \
    FORCE_BUILD="$force_build" \
    VARIANTS_CONFIG="$variants_config" \
    VARIANTS_OVERRIDE="$variants_override" \
    bash scripts/check-variants.sh

  echo "=== Variant check results ==="
  jq '.' "$ARTIFACTS_DIR/variants_results.json"
}

# Aggregate check-variants results into CI-style outputs (mirrors the old
# check-variants action's "Aggregate results" step).
# Usage: aggregate_variants <registry> <repo> [step_summary_file]
# Reads $ARTIFACTS_DIR/variants_results.json (written by check_variants).
# Writes variants_to_build / any_builds_needed to $GITHUB_OUTPUT when set.
aggregate_variants() {
  local registry="${1:?registry required}"
  local repo="${2:?repo required}"
  local step_summary_file="${3:-${GITHUB_STEP_SUMMARY:-}}"
  local results_file="$ARTIFACTS_DIR/variants_results.json"

  if [[ ! -f "$results_file" ]]; then
    fail "Variant results file not found - run check-variants first"
    return 1
  fi

  local results
  results=$(cat "$results_file")
  if ! echo "$results" | jq empty 2>/dev/null; then
    fail "Invalid JSON in results file - check job may have produced corrupt output"
    return 1
  fi

  local variants_to_build count any_builds_needed
  variants_to_build=$(echo "$results" | jq -c '[.[] | select(.needs_build == true) | del(.needs_build)]')
  count=$(echo "$variants_to_build" | jq 'length')
  any_builds_needed="false"
  if [[ "$count" -gt 0 ]]; then
    any_builds_needed="true"
  else
    generate_step_summary "$results" "false" "$registry" "$repo" "$step_summary_file"
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "variants_to_build=${variants_to_build}" >>"$GITHUB_OUTPUT"
    echo "any_builds_needed=${any_builds_needed}" >>"$GITHUB_OUTPUT"
  fi
  echo "any_builds_needed=${any_builds_needed} (${count} variant(s))"
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

# ── Release resolution ──────────────────────────────────────────────────────

# List enabled variants that have at least one {variant}-{version} tag in the
# registry. Such a tag only exists once a push succeeded, so the registry — not
# the CI job records — is what says a variant has something to release. Package
# identity comes from the same environment the release step reads.
# Usage: pushed_variants [variants_config]
# Prints one variant per line.
pushed_variants() {
  local variants_config="${1:-.github/variants.json}"
  local owner registry repo name suffix
  owner="$(registry_owner)"
  registry="$(registry_url "$owner")"
  repo="$(package_repo)"
  while IFS=$'\t' read -r name suffix; do
    if find_latest_versioned_tag "${registry}/${repo}${suffix}" "$name" >/dev/null; then
      printf '%s\n' "$name"
    fi
  done < <(jq -r '.variants[] | select(.disabled != true) | [.name, .suffix // ""] | @tsv' "$variants_config")
}

# Resolve the variants to make releases for.
# Usage: resolve_release_variants <variants_csv> <variants_config>
# Blank csv → every enabled variant that has a versioned tag in the registry.
# Explicit csv → intersected with that same list (variants never pushed are
# warned about and dropped). Prints one variant per line.
resolve_release_variants() {
  local variants_csv="${1:-}"
  local variants_config="${2:-.github/variants.json}"
  local requested built missing
  built=$(pushed_variants "$variants_config" | sort -u)
  if [[ -z "$variants_csv" ]]; then
    [[ -n "$built" ]] && printf '%s\n' "$built"
    return 0
  fi
  requested=$(echo "$variants_csv" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | sort -u)
  missing=$(comm -23 <(printf '%s\n' "$requested") <(printf '%s\n' "$built"))
  if [[ -n "$missing" ]]; then
    warn "Skipping variant(s) never pushed to the registry: $(echo "$missing" | paste -sd ',' -)"
  fi
  comm -12 <(printf '%s\n' "$requested") <(printf '%s\n' "$built")
}

# Print the variants to release as a JSON array, ready for a workflow matrix.
# Empty selection prints []. Usage: MATRIX_JSON=$(release_matrix_json <variants_csv> [variants_config])
release_matrix_json() {
  local variants_csv="${1:-}"
  local variants_config="${2:-.github/variants.json}"
  local variants
  variants=$(resolve_release_variants "$variants_csv" "$variants_config")
  if [[ -z "$variants" ]]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "$variants" | jq -R . | jq -sc .
}

# Render the changelog preview for locally built chunked images.
# Usage: release_preview [variants_csv] [prev_ref] [variants_config]
# Blank csv → all enabled variants in the config. Each variant uses
# localhost/chunked-img:<variant>, falling back to localhost/chunked-img:latest
# when that tag is missing or lacks the ostree.rechunk.info label.
release_preview() {
  local variants_csv="${1:-}"
  local prev_ref="${2:-}"
  local variants_config="${3:-.github/variants.json}"
  local v label prev_args=()
  [[ -n "$prev_ref" ]] && prev_args=(--prev "$prev_ref")

  if [[ -n "$variants_csv" ]]; then
    echo "$variants_csv" | tr ',' '\n'
  else
    jq -r '.variants[] | select(.disabled != true) | .name' "$variants_config"
  fi | while read -r v; do
    local candidate
    for candidate in "$(image_ref chunked-img "$v")" "$(image_tag chunked-img)"; do
      label=$(podman inspect "$candidate" 2>/dev/null | jq -r '.[0].Labels["ostree.rechunk.info"] // empty' 2>/dev/null || true)
      if [[ -n "$label" ]]; then
        break
      fi
      echo "Warning: ${candidate} missing or lacks ostree.rechunk.info" >&2
    done
    if [[ -z "$label" ]]; then
      echo "Skipping ${v}: no local chunked image with ostree.rechunk.info label" >&2
      continue
    fi
    python3 scripts/release-preview.py "$candidate" "${prev_args[@]}"
  done
}

# ── just entrypoints (release, changelog demo) ────────────────────────────

# The release job addresses a variant by name; the record is what release_variant wants,
# so the entrypoint is where the name becomes a record. Only the choices the caller made
# travel in the options record — release_variant already defaults every other field
# (DESIGN.md §6 decision 9: every entrypoint names the record).
# Usage: entry_release <variant> [handwritten] [variants_config] [allow_disabled]
entry_release() {
  local variant="${1:?variant required}"
  local handwritten="${2:-}"
  local variants_config="${3:-${VARIANTS_CONFIG:-.github/variants.json}}"
  local allow_disabled="${4:-false}"
  local record options
  record=$(variant_record "$variant" "$variants_config")
  options=$(jq -cn --arg handwritten "$handwritten" --arg variants_config "$variants_config" --arg allow_disabled "$allow_disabled" '{handwritten: $handwritten, variants_config: $variants_config, allow_disabled: $allow_disabled}')
  release_variant "$record" "$options"
}

# Demo one release window locally: two published tags from one release branch become the
# changelog body and the TITLE/TAG the real generator writes (under the demo artifact
# directory). Needs ghcr auth for skopeo: podman login ghcr.io.
# Usage: entry_demo_changelog <variant> <prev-tag> <curr-tag> [variants_config]
entry_demo_changelog() {
  local variant="${1:?variant required}"
  local prev_tag="${2:?prev-tag required}"
  local curr_tag="${3:?curr-tag required}"
  local variants_config="${4:-${VARIANTS_CONFIG:-.github/variants.json}}"
  local artifact_dir="${ARTIFACTS_DIR:?ARTIFACTS_DIR required}/demo"
  mkdir -p "$artifact_dir"
  local image_prefix
  image_prefix="$(registry_url "${GITHUB_REPOSITORY_OWNER:?repo owner required}")/${IMAGE_NAME:?image_name required}"
  export IMAGE_PREFIX="$image_prefix"
  python3 scripts/changelog.py "$variant" \
    "$artifact_dir/${variant}-output.env" "$artifact_dir/${variant}-changelog.md" \
    --package "$IMAGE_NAME" --variants-config "$variants_config" --pair "$prev_tag" "$curr_tag"
}

# ── cleanup package names ───────────────────────────────────────────────────

# The package names the GHCR cleanup action addresses. A package is the repository
# name plus the variant's suffix, lowercased (GHCR's namespace rule, the same one
# check-variants.sh applies through package_repo), so the cleanup job can never
# address a name the build job did not publish. Config policy (disabled, cleanup:
# false) picks the default set; naming packages explicitly overrides the policy,
# because naming one is an instruction to clean it. A filter that matches nothing
# prints nothing and is a caller's warning, not a failure.
# Usage: cleanup_packages <repo> [variants_config] [filter]
#   repo            owner/name or bare name; normalized by package_repo
#   filter          comma-separated package names (whitespace-insensitive)
# Prints: one package name per line, sorted-unique
cleanup_packages() {
  local repo="${1:?repo required}"
  local variants_config="${2:-.github/variants.json}"
  local filter="${3:-}"

  local base
  base="$(package_repo "$repo")"

  jq -r --arg base "$base" --arg filter "$filter" '
    def to_pkg: ($base + (.suffix // "")) | ascii_downcase;
    ($filter | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
      | map(ascii_downcase) | map(select(. != "")) | unique) as $want
    | if $filter == "" then
        [ .variants[] | select(.disabled != true and .cleanup != false) | to_pkg ] | unique
      elif $want == [] then
        []
      else
        [ .variants[] | to_pkg | . as $p | select($want | index($p)) ] | unique
      end
    | .[]
  ' "$variants_config"
}
