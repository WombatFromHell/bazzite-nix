#!/usr/bin/env bash
# check-variants-helpers.bash — shared functions for check-variants action.
# Umbrella file: sourced by check-variants.sh and just-helpers.bash (CHECK_VARIANTS_HELPERS).
# Function bodies live in single-concern parts, split out for readability:
#
#   check-variants-registry.bash  — skopeo retry/inspect, tag listing, prev-ref lookup
#   check-variants-tags.bash      — metadata extraction, canonical tag, tag generation
#   check-variants-check.bash     — build-needed decision
#   check-variants-summary.bash   — GitHub step summary rendering
#   check-variants-resolve.bash   — resolve_variant for just/preview/local paths
#
# Environment Variables (expected to be set by caller):
#   REGISTRY           - Full registry URL (e.g., "ghcr.io/ublue-os")
#   REPO               - Repository name (e.g., "bazzite-nix")
#   IMAGE_DESC         - Image description
#   DATE               - Build date timestamp
#   FORCE_BUILD        - "true" to force rebuild regardless of digest
#   VARIANTS_CONFIG    - Path to variants.json config file
#   GITHUB_STEP_SUMMARY - Path to GitHub step summary file (optional)
#   GITHUB_OUTPUT      - Path to GitHub outputs file (optional)

set -euo pipefail

_parts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1090
for _part in registry tags check summary resolve; do
  source "${_parts_dir}/check-variants-${_part}.bash"
done
