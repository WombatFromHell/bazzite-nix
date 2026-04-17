#!/usr/bin/env bash
# verify-ostree-sbom.sh - Verify deployed image against GitHub SBOM attestation
#
# This script verifies that an image's SBOM attestation exists in GitHub
# and optionally verifies its signature.
#
# Usage:
# ./verify-ostree-sbom.sh                     # Verify booted deployment
# ./verify-ostree-sbom.sh -s                  # Also verify attestation signature
# ./verify-ostree-sbom.sh -i ghcr.io/owner/repo:tag    # Verify remote image
# ./verify-ostree-sbom.sh -l /path/to/sbom.json [-m /path/to/manifest.json]  # Local debug mode
#
# Exit codes:
# 0 - SBOM verification passed
# 1 - SBOM verification failed
# 2 - Error (SBOM not found, network error, etc.)
# 3 - Signature verification failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_HELPERS="${SCRIPT_DIR}/../.github/actions/sbom-reusable/helpers.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ -f "$ACTION_HELPERS" ]]; then
  # shellcheck disable=SC1090
  source "$ACTION_HELPERS"
fi

JSON_OUTPUT=false
LOCAL_MODE=false
VERIFY_SIGNATURE=false
NO_PULL=false
LOCAL_SBOM_PATH=""
LOCAL_MANIFEST_PATH=""
GITHUB_OWNER=""
GITHUB_REPO=""
GH_TOKEN=""
TEMP_DIR=""
IMAGE_REF=""
IMAGE_DIGEST=""
SBOM_DIGEST=""
SBOM_PATH=""
SIGNATURE_VALID=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Verify an image's SBOM attestation exists in GitHub and optionally
verify its signature.

Options:
  -v, --verbose           Enable verbose output
  -j, --json              Output results as JSON
  -i, --image REF         Image reference to verify
  -l, --local-sbom PATH  Local SBOM file to compare against image manifest
  -m, --manifest PATH    Manifest path (extracted from image if not specified)
  --no-pull               Don't pull image, use local only
  -s, --verify-signature  Verify attestation signature with GitHub
  -o, --owner OWNER       GitHub owner (org or user)
  -r, --repo REPO          GitHub repository name
  -t, --token TOKEN       GitHub token (default: GITHUB_TOKEN env)
  -h, --help              Show this help message

Exit codes:
  0 - Verification passed
  1 - Verification failed (SBOM missing or packages differ)
  2 - Error (network error, etc.)
  3 - Signature verification failed
EOF
  exit 0
}

log() {
  local level="$1"
  shift
  local prefix
  case "$level" in
  INFO) prefix="${BLUE}[INFO]${NC}" ;;
  PASS) prefix="${GREEN}[PASS]${NC}" ;;
  WARN) prefix="${YELLOW}[WARN]${NC}" ;;
  ERROR) prefix="${RED}[ERROR]${NC}" ;;
  esac
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo -e "$prefix $*" >&2
  else
    echo -e "$prefix $*"
  fi
}
log_info() { log INFO "$@"; }
log_success() { log PASS "$@"; }
log_warning() { log WARN "$@" >&2; }
log_error() { log ERROR "$@" >&2; }

count_lines() { wc -l <"$1" | tr -d ' '; }

file_to_json_array() {
  if [[ -s "$1" ]]; then
    jq -R . "$1" | jq -s .
  else
    echo "[]"
  fi
}

cleanup() {
  if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}

trap cleanup EXIT

setup_temp() {
  TEMP_DIR=$(mktemp -d)
}

get_deployed_info() {
  log_info "Querying currently deployed image..."

  local status_json
  status_json=$(rpm-ostree status --json) || {
    log_error "Failed to get rpm-ostree status"
    exit 2
  }

  local first_deployment
  first_deployment=$(echo "$status_json" | jq -r '.[0]')

  if [[ -z "$first_deployment" ]] || [[ "$first_deployment" == "null" ]]; then
    log_error "No deployments found"
    exit 2
  fi

  IMAGE_REF=$(echo "$first_deployment" | jq -r '.containerImageReference // .origin // empty')

  local version_string version_tag
  version_string=$(echo "$first_deployment" | jq -r '.version')
  version_tag=$(echo "$version_string" | awk '{print $1}')

  IMAGE_DIGEST=$(echo "$first_deployment" | jq -r '.checksum // .containerImageDigest // empty')

  if [[ "$IMAGE_REF" == docker://* ]] || [[ "$IMAGE_REF" == ghcr.io* ]]; then
    :
  elif [[ -n "$IMAGE_REF" ]]; then
    IMAGE_REF="docker://${IMAGE_REF}:${version_tag}"
  fi

  if [[ -z "${IMAGE_REF}" ]]; then
    log_error "Could not determine image reference from rpm-ostree status"
    exit 2
  fi

  log_info "Deployed image: ${IMAGE_REF}"
  [[ -n "${IMAGE_DIGEST}" ]] && log_info "Image digest: ${IMAGE_DIGEST}"
}

extract_sbom_from_image() {
  local image_ref="$1"
  log_info "Extracting embedded SBOM from image..."

  SBOM_PATH="${TEMP_DIR}/sbom.json"

  local podman_ref="$image_ref"
  if [[ "$image_ref" != docker://* ]] && [[ "$image_ref" != containers-storage:* ]]; then
    podman_ref="docker://${image_ref}"
  fi

  podman pull "$podman_ref" >/dev/null 2>&1 || true

  if ! podman run --rm --security-opt label=disable "$podman_ref" cat /usr/share/ublue-os/sbom.json >"$SBOM_PATH" 2>/dev/null; then
    log_error "Failed to extract /usr/share/ublue-os/sbom.json from image"
    log_info "Ensure SBOM was injected during build (requires syft)"
    exit 2
  fi

  if [[ ! -s "$SBOM_PATH" ]]; then
    log_error "Embedded SBOM is empty"
    exit 2
  fi

  local sbom_format
  sbom_format=$(jq -r '.spdxVersion // empty' "$SBOM_PATH" 2>/dev/null)
  if [[ -z "$sbom_format" ]]; then
    log_error "SBOM in image is not in SPDX format"
    log_info "Expected SPDX-JSON format with 'spdxVersion' field"
    exit 2
  fi

  if [[ "$sbom_format" != "SPDX-2.3" && "$sbom_format" != "SPDX-2.2" && "$sbom_format" != "SPDX-2.1" ]]; then
    log_error "Unsupported SPDX version in image: $sbom_format"
    log_info "Expected SPDX-2.1, SPDX-2.2, or SPDX-2.3"
    exit 2
  fi

  SBOM_DIGEST="sha256:$(sha256sum "$SBOM_PATH" | cut -d' ' -f1)"
  log_success "SBOM extracted ($(wc -c <"$SBOM_PATH" | tr -d ' ') bytes, ${sbom_format})"
  log_info "SBOM digest: ${SBOM_DIGEST}"
}

ensure_image_local() {
  log_info "Checking image availability: ${IMAGE_REF}..."

  local podman_ref="$IMAGE_REF"
  if [[ "$IMAGE_REF" == containers-storage:* ]]; then
    podman_ref="$IMAGE_REF"
  elif [[ "$IMAGE_REF" == localhost/* ]]; then
    podman_ref="containers-storage:${IMAGE_REF}"
  elif [[ "$IMAGE_REF" != docker://* ]]; then
    podman_ref="docker://${IMAGE_REF}"
  fi

  if ! podman image exists "$podman_ref" 2>/dev/null; then
    if [[ "$NO_PULL" == "true" ]]; then
      log_error "Image not found locally and --no-pull specified"
      exit 2
    fi
    log_info "Pulling image: ${podman_ref}..."
    podman pull "$podman_ref" || {
      log_error "Failed to pull image: ${podman_ref}"
      exit 2
    }
  fi

  IMAGE_DIGEST=$(podman inspect --format json "$podman_ref" | jq -r '.[0].Digest // .[0].Id // empty')
  log_info "Image digest: ${IMAGE_DIGEST:-N/A}"
}

extract_manifest_from_image() {
  log_info "Extracting manifest from image..."

  LOCAL_MANIFEST_PATH="${TEMP_DIR}/manifest.json"

  local podman_ref="$IMAGE_REF"
  if [[ "$IMAGE_REF" != docker://* ]] && [[ "$IMAGE_REF" != containers-storage:* ]]; then
    podman_ref="docker://${IMAGE_REF}"
  fi

  if ! podman run --rm --security-opt label=disable "$podman_ref" cat /usr/share/ublue-os/manifest.json >"$LOCAL_MANIFEST_PATH" 2>/dev/null; then
    log_error "Failed to extract manifest from image"
    log_info "Manifest may not exist at /usr/share/ublue-os/manifest.json"
    exit 2
  fi

  [[ -s "$LOCAL_MANIFEST_PATH" ]] || {
    log_error "Extracted manifest is empty"
    exit 2
  }
  log_info "Manifest extracted (${TEMP_DIR}/manifest.json)"
}

parse_github_repo() {
  local ref="${IMAGE_REF}"

  if [[ "$ref" == ghcr.io/* ]]; then
    ref="${ref#ghcr.io/}"
  elif [[ "$ref" == docker://* ]]; then
    ref="${ref#docker://}"
  elif [[ "$ref" == docker.io/* ]]; then
    ref="${ref#docker.io/}"
  fi

  ref="${ref%%:*}"
  ref="${ref%%@*}"

  local owner_repo="${ref%%/*}"
  [[ -z "$owner_repo" ]] && return 1

  GITHUB_OWNER="${owner_repo%%/*}"
  GITHUB_REPO="${owner_repo#*/}"

  GITHUB_OWNER="${GITHUB_OWNER,,}"
  GITHUB_REPO="${GITHUB_REPO,,}"

  log_info "GitHub owner: ${GITHUB_OWNER}"
  log_info "GitHub repo: ${GITHUB_REPO}"
}

fetch_attestation() {
  log_info "Fetching SBOM attestation from GitHub..."

  GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -z "${GH_TOKEN}" ]]; then
    log_error "GitHub token not provided. Set GITHUB_TOKEN or use -t"
    exit 2
  fi

  [[ -z "${GITHUB_OWNER}" ]] && parse_github_repo

  local subject_name="${GITHUB_OWNER}/${GITHUB_REPO}"
  if [[ "$IMAGE_REF" == *:* ]]; then
    local tag="${IMAGE_REF##*:}"
    tag="${tag%%@*}"
    [[ -n "$tag" && "$tag" != sha256:* ]] && subject_name="${subject_name}:${tag}"
  fi

  log_info "Subject name: ${subject_name}"
  log_info "Image digest: ${IMAGE_DIGEST:-N/A}"

  SBOM_PATH="${TEMP_DIR}/sbom.json"

  export GH_TOKEN

  log_info "Attempting to fetch SBOM attestation via gh attestation verify..."
  if gh attestation verify "oci://${subject_name}" \
    --owner "$GITHUB_OWNER" \
    --predicate-type "https://spdx.dev/Document/v2.3" \
    -o json 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1; then

    log_info "Found SPDX SBOM attestation, extracting..."

    local sbom_json
    if sbom_json=$(gh attestation verify "oci://${subject_name}" \
      --owner "$GITHUB_OWNER" \
      --predicate-type "https://spdx.dev/Document/v2.3" \
      -o json 2>/dev/null | jq -r '.[].verificationResult.statement.predicate' 2>/dev/null); then

      if [[ -n "$sbom_json" && "$sbom_json" != "null" ]]; then
        echo "$sbom_json" >"$SBOM_PATH"

        local sbom_format
        sbom_format=$(jq -r '.spdxVersion // empty' "$SBOM_PATH" 2>/dev/null)
        if [[ -n "$sbom_format" ]]; then
          SBOM_DIGEST="sha256:$(sha256sum "$SBOM_PATH" | cut -d' ' -f1)"
          log_success "SBOM attestation extracted via gh attestation verify ($(wc -c <"$SBOM_PATH" | tr -d ' ') bytes, ${sbom_format})"
          log_info "SBOM digest: ${SBOM_DIGEST}"
          return 0
        fi
      fi
    fi
  fi

  log_info "Trying fallback: gh attestation list and parse..."
  local attestations
  if ! attestations=$(gh attestation list "$subject_name" --owner "$GITHUB_OWNER" -o json 2>&1); then
    log_error "Failed to list attestations: ${attestations}"
    exit 2
  fi

  local attest_count
  attest_count=$(echo "$attestations" | jq 'length')

  if [[ "$attest_count" -eq 0 ]]; then
    log_error "No attestations found for ${subject_name}"
    log_info "This may mean:"
    log_info "  - SBOM generation was not enabled for this build"
    log_info "  - The image has not been pushed to GitHub Packages"
    log_info "  - The repository is not accessible"
    exit 2
  fi

  log_info "Found ${attest_count} attestation(s)"

  local sbom_found=false
  local check_digest="${IMAGE_DIGEST#sha256:}"

  for i in $(seq 0 $((attest_count - 1))); do
    local att att_name att_digest att_id
    att=$(echo "$attestations" | jq -r ".[$i]")
    att_name=$(echo "$att" | jq -r '.subject.name')
    att_digest=$(echo "$att" | jq -r '.subject.digest.sha256 // empty')
    att_id=$(echo "$att" | jq -r '.attestation_id')

    log_info "Checking attestation: ${att_name} (sha256:${att_digest:0:12}...)"

    [[ -n "$check_digest" && "$att_digest" != "$check_digest" ]] && continue

    log_info "Downloading attestation ${att_id}..."

    local attest_json
    attest_json=$(gh attestation download "$att_id" -o json 2>&1) || {
      log_warning "Failed to download attestation ${att_id}"
      continue
    }

    local bundle payload decoded_payload predicate_type
    bundle=$(echo "$attest_json" | jq -r '.bundle')
    payload=$(echo "$bundle" | jq -r '.payload')
    decoded_payload=$(echo "$payload" | base64 -d 2>/dev/null) || {
      log_warning "Failed to decode attestation payload"
      continue
    }

    predicate_type=$(echo "$decoded_payload" | jq -r '.predicateType // empty' 2>/dev/null)
    log_info "Predicate type: ${predicate_type:-unknown}"

    if [[ "$predicate_type" == *"spdx.dev"* ]] || [[ "$predicate_type" == "application/vnd.spdx+json" ]]; then
      log_info "Found SPDX SBOM attestation"

      local sbom_content
      sbom_content=$(echo "$decoded_payload" | jq -r '.statement.predicate' 2>/dev/null)
      if [[ -z "$sbom_content" ]] || [[ "$sbom_content" == "null" ]]; then
        sbom_content=$(echo "$decoded_payload" | jq -r '.predicate' 2>/dev/null)
      fi

      if [[ -n "$sbom_content" && "$sbom_content" != "null" ]]; then
        echo "$sbom_content" >"$SBOM_PATH"

        local sbom_format
        sbom_format=$(jq -r '.spdxVersion // empty' "$SBOM_PATH" 2>/dev/null)
        if [[ -n "$sbom_format" ]]; then
          SBOM_DIGEST="sha256:$(sha256sum "$SBOM_PATH" | cut -d' ' -f1)"
          sbom_found=true
          log_success "SBOM attestation downloaded ($(wc -c <"$SBOM_PATH" | tr -d ' ') bytes, ${sbom_format})"
          log_info "SBOM digest: ${SBOM_DIGEST}"
          break
        fi
      fi
    else
      log_info "Skipping non-SBOM attestation (type: ${predicate_type:-unknown})"
    fi
  done

  [[ "$sbom_found" != "true" ]] && {
    log_error "No SBOM attestation found in any attestation"
    log_info "The SBOM may not have been attached to this image"
    log_info "Ensure the sbom-attach workflow was run for this image"
    exit 2
  }
}

verify_attestation_signature() {
  log_info "Verifying SBOM attestation signature..."

  GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  [[ -z "${GH_TOKEN}" ]] && {
    log_warning "GitHub token not provided. Skipping signature verification"
    return 0
  }

  [[ -z "${GITHUB_OWNER}" ]] && parse_github_repo

  local subject_name="${GITHUB_OWNER}/${GITHUB_REPO}"
  if [[ "$IMAGE_REF" == *:* ]]; then
    local tag="${IMAGE_REF##*:}"
    tag="${tag%%@*}"
    [[ -n "$tag" && "$tag" != sha256:* ]] && subject_name="${subject_name}:${tag}"
  fi

  export GH_TOKEN

  gh attestation verify "oci://${subject_name}" \
    --owner "$GITHUB_OWNER" \
    --predicate-type "https://spdx.dev/Document/v2.3" \
    -o json >/dev/null 2>&1 || {
    log_error "SBOM attestation signature verification failed"
    log_info "The attestation may have been tampered with or uses different signing key"
    SIGNATURE_VALID=false
    return 3
  }

  log_success "SBOM attestation signature verified"
  SIGNATURE_VALID=true
  return 0
}

get_deployed_packages_rpm_ostree() {
  log_info "Getting deployed packages from rpm-ostree..."

  local status_json
  status_json=$(rpm-ostree status --json) || {
    log_error "Failed to get rpm-ostree status"
    exit 2
  }

  local packages
  packages=$(echo "$status_json" | jq -r '.[0].packages[]' 2>/dev/null || echo "")

  if [[ -z "$packages" ]]; then
    log_warning "No packages found in rpm-ostree status, using rpm query"
    packages=$(rpm -qa --qf '%{NAME}\n' | sort -u) || packages=""
  fi

  echo "$packages" | sort -u >"${TEMP_DIR}/deployed-packages.txt"
  log_info "Found $(count_lines "${TEMP_DIR}/deployed-packages.txt") deployed packages"
}

get_deployed_packages_local() {
  log_info "Getting deployed packages from local manifest..."

  [[ -f "$LOCAL_MANIFEST_PATH" ]] || {
    log_error "Manifest file not found: $LOCAL_MANIFEST_PATH"
    exit 2
  }

  jq -r '.packages | keys[]' "$LOCAL_MANIFEST_PATH" 2>/dev/null | sort -u >"${TEMP_DIR}/deployed-packages.txt"

  [[ -s "${TEMP_DIR}/deployed-packages.txt" ]] || {
    log_error "No packages found in manifest file"
    exit 2
  }

  log_info "Found $(count_lines "${TEMP_DIR}/deployed-packages.txt") packages in manifest"
}

extract_sbom_packages() {
  log_info "Extracting packages from SBOM..."

  [[ -f "$SBOM_PATH" ]] || {
    log_error "SBOM file not found: $SBOM_PATH"
    exit 2
  }

  local sbom_format
  sbom_format=$(jq -r '.spdxVersion // empty' "$SBOM_PATH" 2>/dev/null)

  if [[ -z "$sbom_format" ]]; then
    log_error "SBOM is not in SPDX format: $SBOM_PATH"
    log_info "Expected SPDX-JSON format with 'spdxVersion' field"
    exit 2
  fi

  if [[ "$sbom_format" != "SPDX-2.3" && "$sbom_format" != "SPDX-2.2" && "$sbom_format" != "SPDX-2.1" ]]; then
    log_error "Unsupported SPDX version: $sbom_format"
    log_info "Expected SPDX-2.1, SPDX-2.2, or SPDX-2.3"
    exit 2
  fi

  jq -r '
    .packages[] |
    select(.externalRefs != null) |
    .externalRefs[] |
    select(.referenceType == "purl" and (.referenceLocator | startswith("pkg:rpm"))) |
    .referenceLocator |
    sub("^pkg:rpm/[^/]+/"; "") |
    sub("@.*$"; "") |
    gsub("%2[Bb]"; "+") |
    gsub("%2[Ff]"; "/")
  ' "$SBOM_PATH" 2>/dev/null | sort -u >"${TEMP_DIR}/sbom-packages.txt"

  if [[ ! -s "${TEMP_DIR}/sbom-packages.txt" ]]; then
    log_error "No RPM packages found in SBOM"
    log_info "SBOM may be malformed or contain no package data"
    exit 2
  fi

  log_info "Found $(count_lines "${TEMP_DIR}/sbom-packages.txt") packages in SBOM"
}

setup_local_mode() {
  log_info "Running in local SBOM verification mode..."

  [[ -f "$LOCAL_SBOM_PATH" ]] || {
    log_error "Local SBOM file not found: $LOCAL_SBOM_PATH"
    exit 2
  }

  local sbom_format
  sbom_format=$(jq -r '.spdxVersion // empty' "$LOCAL_SBOM_PATH" 2>/dev/null)
  if [[ -z "$sbom_format" ]]; then
    log_error "Local SBOM is not in SPDX format: $LOCAL_SBOM_PATH"
    log_info "Expected SPDX-JSON format with 'spdxVersion' field"
    exit 2
  fi

  if [[ "$sbom_format" != "SPDX-2.3" && "$sbom_format" != "SPDX-2.2" && "$sbom_format" != "SPDX-2.1" ]]; then
    log_error "Unsupported SPDX version in local SBOM: $sbom_format"
    log_info "Expected SPDX-2.1, SPDX-2.2, or SPDX-2.3"
    exit 2
  fi

  SBOM_PATH="$LOCAL_SBOM_PATH"
  SBOM_DIGEST="sha256:$(sha256sum "$LOCAL_SBOM_PATH" | cut -d' ' -f1)"
  log_info "Local SBOM: $LOCAL_SBOM_PATH (${sbom_format})"

  if [[ -n "$IMAGE_REF" ]]; then
    ensure_image_local
    [[ -z "$LOCAL_MANIFEST_PATH" ]] && extract_manifest_from_image
  elif [[ -z "$LOCAL_MANIFEST_PATH" ]]; then
    log_error "No image specified and no manifest path provided"
    log_info "Use -i <image> or -m <manifest.json>"
    exit 2
  fi

  log_info "Manifest: $LOCAL_MANIFEST_PATH"
  [[ "$VERIFY_SIGNATURE" == "true" ]] && {
    log_warning "Signature verification not available in local mode"
    VERIFY_SIGNATURE=false
  }
}

compare_packages() {
  log_info "Comparing packages..."

  comm -23 "${TEMP_DIR}/sbom-packages.txt" "${TEMP_DIR}/deployed-packages.txt" >"${TEMP_DIR}/extra-packages.txt"
  comm -13 "${TEMP_DIR}/sbom-packages.txt" "${TEMP_DIR}/deployed-packages.txt" >"${TEMP_DIR}/missing-packages.txt"
  comm -12 "${TEMP_DIR}/sbom-packages.txt" "${TEMP_DIR}/deployed-packages.txt" >"${TEMP_DIR}/common-packages.txt"

  count_lines "${TEMP_DIR}/extra-packages.txt" >"${TEMP_DIR}/extra-count.txt"
  count_lines "${TEMP_DIR}/missing-packages.txt" >"${TEMP_DIR}/missing-count.txt"
  count_lines "${TEMP_DIR}/common-packages.txt" >"${TEMP_DIR}/common-count.txt"
}

generate_report() {
  local extra_count missing_count common_count
  extra_count=$(cat "${TEMP_DIR}/extra-count.txt")
  missing_count=$(cat "${TEMP_DIR}/missing-count.txt")
  common_count=$(cat "${TEMP_DIR}/common-count.txt")

  local total_sbom total_deployed
  total_sbom=$(count_lines "${TEMP_DIR}/sbom-packages.txt")
  total_deployed=$(count_lines "${TEMP_DIR}/deployed-packages.txt")

  local signature_status="not_checked"
  [[ "$VERIFY_SIGNATURE" == "true" ]] && signature_status=$([[ "$SIGNATURE_VALID" == "true" ]] && echo "valid" || echo "invalid")

  if [[ "$JSON_OUTPUT" == "true" ]]; then
    local extra_json missing_json
    extra_json=$(file_to_json_array "${TEMP_DIR}/extra-packages.txt")
    missing_json=$(file_to_json_array "${TEMP_DIR}/missing-packages.txt")

    cat <<EOF
{
"verified": $((extra_count == 0 && missing_count == 0)),
"image": "${IMAGE_REF}",
"digest": "${IMAGE_DIGEST}",
"sbom_digest": "${SBOM_DIGEST}",
"signature": {
"verified": $(if [[ "$VERIFY_SIGNATURE" == "true" ]] && [[ "$SIGNATURE_VALID" == "true" ]]; then echo "true"; else echo "false"; fi),
"status": "${signature_status}",
"public_key": $(if [[ "$VERIFY_SIGNATURE" == "true" ]]; then echo "\"github\""; else echo "null"; fi)
},
"packages": {
"sbom_total": ${total_sbom},
"deployed_total": ${total_deployed},
"common": ${common_count},
"extra_in_image": ${extra_count},
"missing_from_image": ${missing_count}
},
"extra_packages": ${extra_json},
"missing_packages": ${missing_json}
}
EOF
  else
    echo ""
    echo "============================================================"
    echo " SBOM VERIFICATION REPORT"
    echo "============================================================"
    echo ""
    echo -e "${BLUE}Image:${NC} ${IMAGE_REF}"
    echo -e "${BLUE}Digest:${NC} ${IMAGE_DIGEST:-N/A}"
    echo -e "${BLUE}SBOM:${NC} ${SBOM_DIGEST}"
    [[ "$VERIFY_SIGNATURE" == "true" ]] && echo -e "${BLUE}Signature:${NC} ${signature_status}"
    echo ""
    echo "------------------------------------------------------------"
    echo " PACKAGE SUMMARY"
    echo "------------------------------------------------------------"
    echo ""
    printf " %-20s %s\n" "Packages in SBOM:" "$total_sbom"
    printf " %-20s %s\n" "Packages deployed:" "$total_deployed"
    printf " %-20s %s\n" "In common:" "$common_count"
    echo ""

    if [[ $extra_count -gt 0 ]]; then
      echo "------------------------------------------------------------"
      echo " Packages in SBOM but NOT deployed (extra):"
      echo "------------------------------------------------------------"
      sed 's/^/  /' "${TEMP_DIR}/extra-packages.txt"
      echo ""
    fi

    if [[ $missing_count -gt 0 ]]; then
      echo "------------------------------------------------------------"
      echo " Packages deployed but NOT in SBOM (missing):"
      echo "------------------------------------------------------------"
      sed 's/^/  /' "${TEMP_DIR}/missing-packages.txt"
      echo ""
    fi

    echo "============================================================"

    if [[ "$VERIFY_SIGNATURE" == "true" ]] && [[ "$SIGNATURE_VALID" != "true" ]]; then
      echo -e "${RED}[FAIL] SIGNATURE VERIFICATION FAILED${NC}"
      echo ""
      echo "The attestation signature could not be verified."
      echo "This may indicate tampering."
      echo ""
      return 3
    fi

    if [[ $extra_count -eq 0 && $missing_count -eq 0 ]]; then
      echo -e "${GREEN}[PASS] VERIFICATION PASSED${NC}"
      echo ""
      echo "All packages in the SBOM match the deployed image."
      echo ""
      return 0
    else
      echo -e "${RED}[FAIL] VERIFICATION FAILED${NC}"
      echo ""
      echo "Differences found between SBOM and deployed image."
      echo ""
      return 1
    fi
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -v | --verbose)
      set -x
      shift
      ;;
    -j | --json)
      JSON_OUTPUT=true
      shift
      ;;
    -i | --image)
      IMAGE_REF="${2:?}"
      shift 2
      ;;
    -l | --local-sbom)
      LOCAL_MODE=true
      LOCAL_SBOM_PATH="${2:?}"
      shift 2
      ;;
    -m | --manifest)
      LOCAL_MANIFEST_PATH="${2:?}"
      shift 2
      ;;
    --no-pull)
      NO_PULL=true
      shift
      ;;
    -s | --verify-signature)
      VERIFY_SIGNATURE=true
      shift
      ;;
    -o | --owner)
      GITHUB_OWNER="${2:?}"
      shift 2
      ;;
    -r | --repo)
      GITHUB_REPO="${2:?}"
      shift 2
      ;;
    -t | --token)
      GH_TOKEN="${2:?}"
      shift 2
      ;;
    -h | --help)
      usage
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      ;;
    esac
  done

  setup_temp

  if [[ "$LOCAL_MODE" == "true" ]]; then
    setup_local_mode
    extract_sbom_packages
    get_deployed_packages_local
    compare_packages
    generate_report
  elif [[ -n "$IMAGE_REF" ]]; then
    ensure_image_local
    extract_manifest_from_image
    fetch_attestation
    [[ "$VERIFY_SIGNATURE" == "true" ]] && verify_attestation_signature || exit $?
    extract_sbom_packages
    get_deployed_packages_local
    compare_packages
    generate_report
  else
    get_deployed_info
    fetch_attestation
    [[ "$VERIFY_SIGNATURE" == "true" ]] && verify_attestation_signature || exit $?
    extract_sbom_packages
    get_deployed_packages_rpm_ostree
    compare_packages
    generate_report
  fi
}

main "$@"
