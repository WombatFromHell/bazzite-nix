#!/usr/bin/env bash
# verify-ostree-sbom.sh - Verify deployed image against remote SBOM attestation
#
# This script verifies that an image's SBOM attestation exists in the registry
# and optionally verifies its signature against a local cosign public key.
#
# Usage:
# ./verify-ostree-sbom.sh                     # Verify booted deployment + SBOM signature
# ./verify-ostree-sbom.sh -s                  # Also verify SBOM signature
# ./verify-ostree-sbom.sh -i ghcr.io/owner/repo:tag    # Verify remote image SBOM
# ./verify-ostree-sbom.sh -i ghcr.io/owner/repo:tag -s # Verify remote image SBOM + signature
# ./verify-ostree-sbom.sh -l /path/to/sbom.json [-m /path/to/manifest.json]  # Local debug mode
#
# Exit codes:
# 0 - SBOM verification passed
# 1 - SBOM verification failed
# 2 - Error (SBOM not found, network error, etc.)
# 3 - Signature verification failed

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

JSON_OUTPUT=false
LOCAL_MODE=false
VERIFY_SIGNATURE=false
NO_PULL=false
LOCAL_SBOM_PATH=""
LOCAL_MANIFEST_PATH=""
COSIGN_PUBLIC_KEY="/etc/pki/containers/cosign.pub"
TEMP_DIR=""
IMAGE_REF=""
IMAGE_TRANSPORT=""
PODMAN_REF=""
IMAGE_DIGEST=""
SBOM_DIGEST=""
SBOM_PATH=""
SIGNATURE_VALID=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Verify an image's SBOM attestation exists in the registry and optionally
verify its signature against a local cosign public key.

Options:
  -v, --verbose           Enable verbose output
  -j, --json              Output results as JSON
  -i, --image REF         Image reference to verify
  -l, --local-sbom PATH   Local SBOM file to compare against image manifest
  -m, --manifest PATH     Manifest path (extracted from image if not specified)
  --no-pull               Don't pull image, use local only
  -s, --verify-signature  Verify SBOM signature with cosign
  -k, --public-key PATH   Cosign public key path (default: /etc/pki/containers/cosign.pub)
  -h, --help              Show this help message

Modes:
  1. Default: Verify booted deployment's SBOM attestation
  2. -i <ref>: Verify remote image's SBOM attestation
  3. -l <sbom.json> -i <ref>: Compare local SBOM against image manifest

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

run_capture() {
  local err_file
  err_file=$(mktemp)
  local output
  output=$(eval "$1" 2>"$err_file") && rc=0 || rc=$?
  if [[ $rc -ne 0 ]]; then
    CAPTURED_ERROR=$(cat "$err_file")
    rm -f "$err_file"
    return "$rc"
  fi
  rm -f "$err_file"
  echo "$output"
}

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
  if ! status_json=$(rpm-ostree status --json 2>/dev/null) || [[ -z "$status_json" ]]; then
    log_error "Failed to get rpm-ostree status"
    exit 2
  fi

  local first_deployment
  first_deployment=$(echo "$status_json" | jq -r '.[0]')

  if [[ -z "$first_deployment" ]] || [[ "$first_deployment" == "null" ]]; then
    log_error "No deployments found"
    exit 2
  fi

  IMAGE_REF=$(echo "$first_deployment" | jq -r '.containerImageReference // .origin // empty')

  local version_string
  version_string=$(echo "$first_deployment" | jq -r '.version')
  local version_tag
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
  if [[ -n "${IMAGE_DIGEST}" ]]; then
    log_info "Image digest: ${IMAGE_DIGEST}"
  fi
}

normalize_image_ref() {
  if [[ "$IMAGE_REF" == containers-storage:* ]]; then
    IMAGE_TRANSPORT="containers-storage"
    PODMAN_REF="$IMAGE_REF"
  elif [[ "$IMAGE_REF" == localhost/* ]]; then
    IMAGE_TRANSPORT="containers-storage"
    PODMAN_REF="containers-storage:${IMAGE_REF}"
  else
    IMAGE_TRANSPORT="registry"
    PODMAN_REF="$IMAGE_REF"
  fi
}

ensure_image_local() {
  log_info "Checking image availability: ${IMAGE_REF}..."

  normalize_image_ref

  if [[ "$IMAGE_TRANSPORT" == "containers-storage" ]]; then
    if ! podman image exists "$PODMAN_REF" 2>/dev/null; then
      if [[ "$NO_PULL" == "true" ]]; then
        log_error "Image not found locally and --no-pull specified"
        exit 2
      fi
      if [[ "$IMAGE_REF" == localhost/* ]]; then
        log_error "Image not found in local storage: ${IMAGE_REF}"
        log_info "Build or pull the image first"
        exit 2
      fi
    else
      log_info "Image available in containers-storage"
    fi
  else
    if ! podman image exists "$PODMAN_REF" 2>/dev/null; then
      if [[ "$NO_PULL" == "true" ]]; then
        log_error "Image not found locally and --no-pull specified"
        exit 2
      fi
      log_info "Pulling image: ${PODMAN_REF}..."
      if ! podman pull "$PODMAN_REF"; then
        log_error "Failed to pull image: ${PODMAN_REF}"
        exit 2
      fi
    else
      log_info "Image available locally"
    fi
  fi

  local inspect_json
  inspect_json=$(podman inspect --format json "$PODMAN_REF" 2>/dev/null) || {
    log_error "Failed to inspect local image"
    exit 2
  }
  IMAGE_DIGEST=$(echo "$inspect_json" | jq -r '.[0].Digest // .[0].Id // empty')
  log_info "Image digest: ${IMAGE_DIGEST:-N/A}"
}

extract_manifest_from_image() {
  log_info "Extracting manifest from image..."

  LOCAL_MANIFEST_PATH="${TEMP_DIR}/manifest.json"

  if ! podman run --rm --security-opt label=disable "$PODMAN_REF" cat /usr/share/ublue-os/manifest.json >"$LOCAL_MANIFEST_PATH" 2>/dev/null; then
    log_error "Failed to extract manifest from image"
    log_info "Manifest may not exist at /usr/share/ublue-os/manifest.json"
    exit 2
  fi

  if [[ ! -s "$LOCAL_MANIFEST_PATH" ]]; then
    log_error "Extracted manifest is empty"
    exit 2
  fi

  log_info "Manifest extracted (${TEMP_DIR}/manifest.json)"
}

get_remote_image_info() {
  log_info "Fetching image info: ${IMAGE_REF}..."

  local skopeo_ref="${IMAGE_REF}"
  if [[ "$IMAGE_REF" != docker://* ]]; then
    skopeo_ref="docker://${IMAGE_REF}"
  fi

  local inspect_json
  inspect_json=$(run_capture "skopeo inspect '$skopeo_ref'") || {
    log_error "Failed to inspect image: ${skopeo_ref}"
    [[ -n "${CAPTURED_ERROR:-}" ]] && log_info "skopeo error: ${CAPTURED_ERROR}"
    log_info "Image may not exist or network/authentication issue"
    exit 2
  }

  IMAGE_DIGEST=$(echo "$inspect_json" | jq -r '.Digest')
  log_info "Image digest: ${IMAGE_DIGEST}"
}

fetch_sbom() {
  log_info "Fetching SBOM from registry..."

  local skopeo_ref="${IMAGE_REF}"
  if [[ "$IMAGE_REF" != docker://* ]]; then
    skopeo_ref="docker://${IMAGE_REF}"
  fi

  local image_without_scheme="${skopeo_ref#docker://}"
  local registry_host="${image_without_scheme%%/*}"
  local repo_path="${image_without_scheme#*/}"
  repo_path="${repo_path%:*}"
  local image_name="${repo_path%@*}"

  if [[ -z "${IMAGE_DIGEST}" ]]; then
    get_remote_image_info
  fi

  log_info "Querying SBOM referrers..."

  local referrers_url="https://${registry_host}/v2/${image_name}/referrers/${IMAGE_DIGEST#sha256:}"
  local referrers_response
  referrers_response=$(run_capture "curl -s -f -H 'Accept: application/json' '$referrers_url'") || {
    log_warning "Failed to query referrers API"
    [[ -n "${CAPTURED_ERROR:-}" ]] && log_info "curl error: ${CAPTURED_ERROR}"
    log_info "This registry may not support OCI referrers API"
    referrers_response='{"referrers":[]}'
  }

  SBOM_DIGEST=$(echo "$referrers_response" | jq -r \
    '.referrers[] | select(.artifactType == "application/vnd.spdx+json") | .digest' 2>/dev/null | head -1)

  if [[ -z "${SBOM_DIGEST}" ]] || [[ "${SBOM_DIGEST}" == "null" ]]; then
    log_warning "No SBOM attestation found for this image"
    log_info "This may mean:"
    log_info "  - SBOM generation was not enabled for this build"
    log_info "  - The registry does not support OCI referrers API"
    log_info "  - The image tag does not exist at this registry"
    exit 1
  fi

  log_info "Found SBOM attestation: ${SBOM_DIGEST}"

  SBOM_PATH="${TEMP_DIR}/sbom.json"
  log_info "Downloading SBOM..."

  local sbom_url="https://${registry_host}/v2/${image_name}/blobs/${SBOM_DIGEST#sha256:}"
  run_capture "curl -s -L -f -o '$SBOM_PATH' -H 'Accept: application/vnd.spdx+json' '$sbom_url'" || {
    log_error "Failed to download SBOM"
    [[ -n "${CAPTURED_ERROR:-}" ]] && log_info "curl error: ${CAPTURED_ERROR}"
    exit 2
  }

  if [[ ! -s "$SBOM_PATH" ]]; then
    log_error "Downloaded SBOM is empty"
    exit 2
  fi

  log_success "SBOM attestation downloaded ($(wc -c <"$SBOM_PATH" | tr -d ' ') bytes)"
}

verify_sbom_signature() {
  log_info "Verifying SBOM signature..."

  if [[ ! -f "$COSIGN_PUBLIC_KEY" ]]; then
    log_error "Cosign public key not found: $COSIGN_PUBLIC_KEY"
    log_info "Specify a different key with --public-key PATH"
    exit 2
  fi

  if ! command -v cosign &>/dev/null; then
    log_error "cosign not found in PATH"
    log_info "Install cosign: https://docs.sigstore.dev/cosign/installation/"
    exit 2
  fi

  log_info "Using public key: $COSIGN_PUBLIC_KEY"

  local sbom_ref="${IMAGE_REF%@*}@${SBOM_DIGEST}"
  log_info "Verifying signature for: ${sbom_ref}"

  run_capture "cosign verify --key '$COSIGN_PUBLIC_KEY' '$sbom_ref'" || {
    log_error "SBOM signature verification failed"
    [[ -n "${CAPTURED_ERROR:-}" ]] && log_info "cosign error: ${CAPTURED_ERROR}"
    log_info "The SBOM may have been tampered with or signed with a different key"
    log_info "Make sure the public key matches the key used to sign the image"
    SIGNATURE_VALID=false
    return 3
  }

  log_success "SBOM signature verified"
  SIGNATURE_VALID=true
  return 0
}

get_deployed_packages_rpm_ostree() {
  log_info "Getting deployed packages from rpm-ostree..."

  local status_json
  if ! status_json=$(run_capture "rpm-ostree status --json"); then
    log_error "Failed to get rpm-ostree status"
    exit 2
  fi

  local packages
  packages=$(echo "$status_json" | jq -r '.[0].packages[]' 2>/dev/null || echo "")

  if [[ -z "$packages" ]]; then
    log_warning "No packages found in rpm-ostree status"
    packages=$(run_capture "rpm -qa --qf '%{NAME}\n' | sort -u") || packages=""
  fi

  echo "$packages" | sort -u >"${TEMP_DIR}/deployed-packages.txt"
  log_info "Found $(count_lines "${TEMP_DIR}/deployed-packages.txt") deployed packages"
}

get_deployed_packages_local() {
  log_info "Getting deployed packages from local manifest..."

  if [[ ! -f "$LOCAL_MANIFEST_PATH" ]]; then
    log_error "Manifest file not found: $LOCAL_MANIFEST_PATH"
    log_info "Hint: Run this on a system with the image deployed, or specify --manifest"
    exit 2
  fi

  jq -r '.packages | keys[]' "$LOCAL_MANIFEST_PATH" 2>/dev/null | sort -u >"${TEMP_DIR}/deployed-packages.txt"

  if [[ ! -s "${TEMP_DIR}/deployed-packages.txt" ]]; then
    log_error "No packages found in manifest file"
    exit 2
  fi

  log_info "Found $(count_lines "${TEMP_DIR}/deployed-packages.txt") packages in manifest"
}

extract_sbom_packages() {
  log_info "Extracting packages from SBOM..."

  if [[ ! -f "$SBOM_PATH" ]]; then
    log_error "SBOM file not found: $SBOM_PATH"
    exit 2
  fi

  local sbom_format
  sbom_format=$(jq -r '.spdxVersion // empty' "$SBOM_PATH" 2>/dev/null)

  if [[ -n "$sbom_format" ]]; then
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
  else
    jq -r '.artifacts[].name' "$SBOM_PATH" 2>/dev/null | sort -u >"${TEMP_DIR}/sbom-packages.txt"
  fi
  log_info "Found $(count_lines "${TEMP_DIR}/sbom-packages.txt") packages in SBOM"
}

setup_local_mode() {
  log_info "Running in local SBOM verification mode..."

  if [[ ! -f "$LOCAL_SBOM_PATH" ]]; then
    log_error "Local SBOM file not found: $LOCAL_SBOM_PATH"
    exit 2
  fi

  SBOM_PATH="$LOCAL_SBOM_PATH"
  SBOM_DIGEST="sha256:$(sha256sum "$LOCAL_SBOM_PATH" | cut -d' ' -f1)"

  log_info "Local SBOM: $LOCAL_SBOM_PATH"

  if [[ -n "$IMAGE_REF" ]]; then
    ensure_image_local
    if [[ -z "$LOCAL_MANIFEST_PATH" ]]; then
      extract_manifest_from_image
    fi
  elif [[ -z "$LOCAL_MANIFEST_PATH" ]]; then
    log_error "No image specified and no manifest path provided"
    log_info "Use -i <image> or -m <manifest.json>"
    exit 2
  fi

  log_info "Manifest: $LOCAL_MANIFEST_PATH"

  if [[ "$VERIFY_SIGNATURE" == "true" ]]; then
    log_warning "Signature verification not available in local mode"
    VERIFY_SIGNATURE=false
  fi
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
  if [[ "$VERIFY_SIGNATURE" == "true" ]]; then
    signature_status=$([[ "$SIGNATURE_VALID" == "true" ]] && echo "valid" || echo "invalid")
  fi

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
"public_key": $(if [[ "$VERIFY_SIGNATURE" == "true" ]]; then echo "\"$COSIGN_PUBLIC_KEY\""; else echo "null"; fi)
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

    if [[ "$VERIFY_SIGNATURE" == "true" ]]; then
      echo -e "${BLUE}Signature:${NC} ${signature_status} (key: ${COSIGN_PUBLIC_KEY})"
    fi

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
      echo "The SBOM signature could not be verified."
      echo "This may indicate tampering or a mismatched signing key."
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
    -k | --public-key)
      COSIGN_PUBLIC_KEY="${2:?}"
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
    fetch_sbom

    if [[ "$VERIFY_SIGNATURE" == "true" ]]; then
      verify_sbom_signature || exit $?
    fi

    extract_sbom_packages
    get_deployed_packages_local
    compare_packages
    generate_report
  else
    get_deployed_info
    fetch_sbom

    if [[ "$VERIFY_SIGNATURE" == "true" ]]; then
      verify_sbom_signature || exit $?
    fi

    extract_sbom_packages
    get_deployed_packages_rpm_ostree
    compare_packages
    generate_report
  fi
}

main "$@"
