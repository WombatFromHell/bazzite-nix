# just-helpers-variants.bash — variant check/aggregate/preview and release
# resolution functions for just-helpers.
# Sourced by just-helpers.bash (no shebang/set — see umbrella).

# Lowercase registry URL for an owner
registry_url() {
  echo "ghcr.io/${1,,}"
}

# Preview which alias tags (and the step-summary markdown) a build would generate
# Usage: preview_tags <variants_csv> [variants_config] [image_name] [repo_organization]
# In CI (GITHUB_STEP_SUMMARY set), appends the pending-builds markdown table to the step summary.
preview_tags() {
  local variants_csv="${1:?variants_csv required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local repo_organization="${4:?repo_organization required}"
  local specs=()
  IFS=',' read -ra specs <<<"$variants_csv"

  local registry
  registry="$(registry_url "$repo_organization")"

  # shellcheck disable=SC2034
  local spec TAG VARIANT_NAME CANONICAL_TAG TAGS TARGET_IMAGE
  local suffix rows=()
  for spec in "${specs[@]}"; do
    eval "$(resolve_variant "$spec" "$variants_config" "$image_name")"
    suffix="${TARGET_IMAGE#localhost/"${image_name}"}"
    rows+=("| \`${VARIANT_NAME}\` | \`${registry}/${image_name}${suffix}\` | \`${TAGS}\` |")
    if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "== Tags that would be generated for '${VARIANT_NAME}' =="
      echo "Canonical tag: ${CANONICAL_TAG}"
      echo "Alias tags    : ${TAGS}"
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
# Writes results to /tmp/variants_results.json
check_variants() {
  local force_build="${1:-0}"
  local repo_organization="${2:?repo_organization required}"
  local image_name="${3:?image_name required}"
  local variants_config="${4:-.github/variants.json}"
  local variants_override="${5:-}"

  local registry date_iso image_desc

  registry="$(registry_url "$repo_organization")"
  image_desc="Customized Bazzite image with Nix mount support and other sugar"
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
  jq '.' /tmp/variants_results.json
}

# Aggregate check-variants results into CI-style outputs (mirrors the old
# check-variants action's "Aggregate results" step).
# Usage: aggregate_variants <registry> <repo> [step_summary_file]
# Reads /tmp/variants_results.json (written by check_variants).
# Writes variants_to_build / any_builds_needed to $GITHUB_OUTPUT when set.
aggregate_variants() {
  local registry="${1:?registry required}"
  local repo="${2:?repo required}"
  local step_summary_file="${3:-${GITHUB_STEP_SUMMARY:-}}"
  local results_file="/tmp/variants_results.json"

  if [[ ! -f "$results_file" ]]; then
    echo "::error::Variant results file not found - run check-variants first" >&2
    return 1
  fi

  if [[ ! -s "$results_file" ]]; then
    echo "::error::Variant results file is empty - check job may have failed silently" >&2
    echo "::notice::Treating as no builds needed to allow workflow to continue" >&2
    generate_step_summary "[]" "false" "$registry" "$repo" "$step_summary_file"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      echo "variants_to_build=[]" >>"$GITHUB_OUTPUT"
      echo "any_builds_needed=false" >>"$GITHUB_OUTPUT"
    fi
    return 0
  fi

  local results
  results=$(cat "$results_file")
  if ! echo "$results" | jq empty 2>/dev/null; then
    echo "::error::Invalid JSON in results file - check job may have produced corrupt output" >&2
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

# ── Build-result collection & release resolution ────────────────────────────

# Extract successful "Build & Push" variants from a `gh run view --json jobs`
# payload. Usage: collect_successful_builds <jobs_json>
# Prints the compact JSON array of {variant} entries and writes
# successful_variants / any_successful to $GITHUB_OUTPUT when set.
collect_successful_builds() {
  local jobs_json="${1:?jobs_json required}"
  local successful count
  successful=$(echo "$jobs_json" | jq -c '[.jobs[] | select(.name | startswith("Build & Push")) | select(.conclusion == "success") | {variant: (.name | sub("^Build & Push "; ""))}]')
  count=$(echo "$successful" | jq 'length')
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "successful_variants=${successful}" >>"$GITHUB_OUTPUT"
    echo "any_successful=$([ "$count" -gt 0 ] && echo true || echo false)" >>"$GITHUB_OUTPUT"
  fi
  echo "$successful"
  echo "Found $count successful builds" >&2
}

# List variants with successful "Build & Push" jobs across the most recent runs
# of the build workflow (deduplicated).
# Usage: recent_successful_builds [limit] [repo] [workflow]
# Auth: ambient gh session or GH_TOKEN. repo defaults to GITHUB_REPOSITORY,
# else gh infers it from the git remote.
recent_successful_builds() {
  local limit="${1:-5}"
  local repo="${2:-${GITHUB_REPOSITORY:-}}"
  local workflow="${3:-build.yml}"
  local repo_args=()
  [[ -n "$repo" ]] && repo_args=(--repo "$repo")
  local run_id
  gh run list "${repo_args[@]}" --workflow "$workflow" --limit "$limit" \
    --json databaseId --jq '.[].databaseId' |
    while read -r run_id; do
      gh run view "$run_id" "${repo_args[@]}" --json jobs --jq \
        '[.jobs[] | select(.name | startswith("Build & Push")) | select(.conclusion == "success") | (.name | sub("^Build & Push "; ""))][]'
    done | sort -u
}

# Resolve the variants to make releases for.
# Usage: resolve_release_variants <variants_csv> <variants_config>
# Blank csv → all enabled variants in the config. Explicit csv → intersected
# with recent_successful_builds (variants without a recent successful build are
# warned about and dropped). Prints one variant per line.
resolve_release_variants() {
  local variants_csv="${1:-}"
  local variants_config="${2:-.github/variants.json}"
  local requested recent missing
  if [[ -z "$variants_csv" ]]; then
    jq -r '.variants[] | select(.disabled != true) | .name' "$variants_config"
    return 0
  fi
  requested=$(echo "$variants_csv" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | sort -u)
  recent=$(recent_successful_builds | sort -u)
  missing=$(comm -23 <(printf '%s\n' "$requested") <(printf '%s\n' "$recent"))
  if [[ -n "$missing" ]]; then
    echo "::warning::Skipping variant(s) with no recent successful build: $(echo "$missing" | paste -sd ',' -)" >&2
  fi
  comm -12 <(printf '%s\n' "$requested") <(printf '%s\n' "$recent")
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
  local v img label prev_args=()
  [[ -n "$prev_ref" ]] && prev_args=(--prev "$prev_ref")

  if [[ -n "$variants_csv" ]]; then
    echo "$variants_csv" | tr ',' '\n'
  else
    jq -r '.variants[] | select(.disabled != true) | .name' "$variants_config"
  fi | while read -r v; do
    img="localhost/chunked-img:${v}"
    label=$(skopeo inspect "containers-storage:${img}" 2>/dev/null | jq -r '.Labels["ostree.rechunk.info"] // empty' 2>/dev/null || true)
    if [[ -z "$label" ]]; then
      echo "Warning: ${img} missing or lacks ostree.rechunk.info; trying localhost/chunked-img:latest" >&2
      img="localhost/chunked-img:latest"
      label=$(skopeo inspect "containers-storage:${img}" 2>/dev/null | jq -r '.Labels["ostree.rechunk.info"] // empty' 2>/dev/null || true)
    fi
    if [[ -z "$label" ]]; then
      echo "Skipping ${v}: no local chunked image with ostree.rechunk.info label" >&2
      continue
    fi
    python3 scripts/release-preview.py "$img" "${prev_args[@]}"
  done
}
