# check-variants-summary.bash — GitHub step summary rendering for check-variants.
# Sourced by check-variants-helpers.bash (no shebang/set — see umbrella).

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
