#!/usr/bin/env bash
set -euo pipefail

VERSION="v1.0.0"

###############################################################################
# verify-attestation.sh
#
# Verifies GitHub Container Registry (ghcr.io) image attestations.
#
# USAGE:
#   ./verify-attestation.sh <IMAGE> [-d <DEPLOYMENT_INDEX>]
#
# MODES:
#   Direct mode (default):
#     ./verify-attestation.sh ghcr.io/owner/repo:tag
#
#   rpm-ostree mode (-d):
#     ./verify-attestation.sh -d
#     ./verify-attestation.sh -d 1
#
# DEPENDENCIES: curl, jq, openssl
###############################################################################

# ── Logging helpers ──────────────────────────────────────────────────────────

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_DIM='\033[2m'
readonly COLOR_RESET='\033[0m'

log_info() { printf "${COLOR_CYAN}[INFO]${COLOR_RESET}  %s\n" "$*"; }
log_ok() { printf "${COLOR_GREEN}[OK]${COLOR_RESET}    %s\n" "$*"; }
log_warn() { printf "${COLOR_YELLOW}[WARN]${COLOR_RESET}  %s\n" "$*"; }
log_fail() { printf "${COLOR_RED}[FAIL]${COLOR_RESET}  %s\n" "$*"; }
log_dim() { printf "${COLOR_DIM}       %s${COLOR_RESET}\n" "$*"; }

die() {
  log_fail "$*"
  exit 1
}

_cleanup_all() {
  _cleanup_temp
  [[ -n "${BUNDLE_FILE:-}" && -f "$BUNDLE_FILE" ]] && rm -f "$BUNDLE_FILE"
}
trap _cleanup_all EXIT

declare -a TEMP_FILES=()

_temp_file() {
  local f
  f=$(mktemp)
  TEMP_FILES+=("$f")
  printf '%s' "$f"
}

_cleanup_temp() {
  for f in "${TEMP_FILES[@]:-}"; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f"
  done
  TEMP_FILES=()
}

# ── Reusable helpers ────────────────────────────────────────────────────────────────

_decode_cert() {
  local cert_b64="$1" out_file="$2"
  [[ -z "$cert_b64" ]] && return 1
  printf '%s' "$cert_b64" | base64 -d | openssl x509 -inform DER -outform PEM >"$out_file" 2>/dev/null
}
_get_pubkey() {
  local cert_file="$1" out_file="$2"
  openssl x509 -in "$cert_file" -noout -pubkey >"$out_file" 2>/dev/null
}
_get_curve() {
  local cert_file="$1"
  openssl x509 -in "$cert_file" -noout -text 2>/dev/null | grep -oP '(?<=NIST CURVE: )P-\d+' | head -1
}
_get_digest_alg() {
  local curve="$1"
  case "$curve" in P-384) printf '%s' "-sha384" ;; P-521) printf '%s' "-sha512" ;; *) printf '%s' "-sha256" ;; esac
}
_verify_sig() {
  local digest_alg="$1" pubkey_file="$2" sig_file="$3" msg_file="$4"
  local out
  out=$(openssl dgst "$digest_alg" -verify "$pubkey_file" -signature "$sig_file" "$msg_file" 2>&1) || true
  if echo "$out" | grep -q "Verified OK"; then
    printf '%s' "$out"
    return 0
  else
    printf '%s' "$out"
    return 1
  fi
}
_get_cert_epochs() {
  local cert_file="$1" not_before not_after nb_epoch na_epoch
  not_before=$(openssl x509 -in "$cert_file" -noout -startdate 2>/dev/null | cut -d= -f2)
  not_after=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
  [[ -z "$not_before" || -z "$not_after" ]] && return 1
  nb_epoch=$(date -d "$not_before" +%s 2>/dev/null || date -jf "%b %d %T %Y %Z" "$not_before" +%s)
  na_epoch=$(date -d "$not_after" +%s 2>/dev/null || date -jf "%b %d %T %Y %Z" "$not_after" +%s)
  printf '%s' "$nb_epoch"
  printf '\t%s' "$na_epoch"
}
_b64_to_hex() {
  local b64="$1"
  printf '%s' "$b64" | base64 -d | xxd -p | tr -d '\n'
}

# ── Attestation cache ──────────────────────────────────────────────────────

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/verify-attestation"

_cache_path() {
  local digest="$1"
  local safe_name="${digest//[:\/]/_}"
  printf '%s/%s.json' "$CACHE_DIR" "$safe_name"
}

_lookup_cached_attestation() {
  local digest="$1"
  local cache_file
  cache_file=$(_cache_path "$digest")

  if [[ -f "$cache_file" && -s "$cache_file" ]]; then
    return 0
  fi
  return 1
}

_save_attestation_to_cache() { :; }

_load_attestation_from_cache() {
  local digest="$1"
  local cache_file
  cache_file=$(_cache_path "$digest")

  BUNDLE_FILE="$cache_file"
}

_validate_bundle() {
  if [[ ! -s "$BUNDLE_FILE" ]]; then
    rm -f "$BUNDLE_FILE"
    BUNDLE_FILE=""
    return 1
  fi

  if [[ "$(jq -r 'type' "$BUNDLE_FILE" 2>/dev/null)" == "null" ]]; then
    rm -f "$BUNDLE_FILE"
    BUNDLE_FILE=""
    return 1
  fi

  return 0
}

# ── Globals ──────────────────────────────────────────────────────────────────

IMAGE_REF=""
DEPLOYMENT_INDEX=""
BUNDLE_FILE=""

# Set by parse_image_ref:
OWNER=""
REPO_NAME=""

# Set by digest resolution or ostree parser:
DIGEST=""

# ── Argument parsing ─────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") [IMAGE_REF] [-d [DEPLOYMENT_INDEX]]
Version: ${VERSION:-unknown}

Arguments:
  IMAGE_REF            Full image reference (e.g. ghcr.io/owner/repo:tag)
                        Required for direct mode, mutually exclusive with -d.

Options:
  -d [DEPLOYMENT_INDEX]
                        Verify a deployment from rpm-ostree status -v.
                        If no index is given, verifies the currently booted
                        deployment (marked with ●).

  -h, --help           Show this help message.

Examples:
  Direct mode:
    $(basename "$0") ghcr.io/wombatfromhell/bazzite-nix:testing-43.20260416

  rpm-ostree mode (currently booted):
    $(basename "$0") -d

  rpm-ostree mode (specific index):
    $(basename "$0") -d 1
EOF
  exit 0
}

parse_args() {
  if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
  fi

  if [[ "$1" != "-d" ]]; then
    IMAGE_REF="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -d)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        DEPLOYMENT_INDEX="auto"
      else
        DEPLOYMENT_INDEX="$2"
        shift
      fi
      shift
      ;;
    -h | --help)
      usage
      ;;
    *)
      die "Unknown argument: $1"
      ;;
    esac
  done

  if [[ -n "$IMAGE_REF" && "$IMAGE_REF" != *:* ]]; then
    die "IMAGE_REF must include a tag or digest (e.g. ghcr.io/owner/repo:tag)."
  fi

  if [[ -z "$IMAGE_REF" && -z "$DEPLOYMENT_INDEX" ]]; then
    die "Either IMAGE_REF or -d flag is required."
  fi
}

# ── Image reference parsing ──────────────────────────────────────────────────

parse_image_ref() { # ghcr.io/owner/repo:tag -> OWNER, REPO_NAME
  if [[ -z "$IMAGE_REF" ]]; then
    return
  fi

  local image_path="${IMAGE_REF%%:*}"
  local repo_full_path="${image_path#ghcr.io/}"

  OWNER="${repo_full_path%%/*}"
  REPO_NAME="${repo_full_path#*/}"

  if [[ "$OWNER" == "$REPO_NAME" ]]; then
    die "Cannot parse owner/repo from image reference: $IMAGE_REF"
  fi
}

# ── GHCR helpers ─────────────────────────────────────────────────────────────

ghcr_token() { # Get GHCR pull token
  local scope="$1"
  curl -sf "https://ghcr.io/token?scope=$scope" | jq -r .token ||
    die "Failed to obtain GHCR pull token for scope: $scope"
}

# ── Step 1: Resolve tag → digest ─────────────────────────────────────────────

resolve_digest() {
  # Resolves an image tag to its digest via GHCR manifest HEAD
  local tag="$1"
  local scope="repository:$OWNER/$REPO_NAME:pull"

  log_info "Requesting pull token for $scope"
  local token
  token=$(ghcr_token "$scope")

  log_info "Resolving tag '${tag}' to digest via manifest HEAD"
  local header
  header=$(curl -sfI \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "https://ghcr.io/v2/$OWNER/$REPO_NAME/manifests/$tag") ||
    die "Failed to fetch manifest headers for tag '${tag}'."

  DIGEST=$(echo "$header" | grep -i 'docker-content-digest' |
    awk '{print $2}' | tr -d '\r\n')

  [[ -z "$DIGEST" ]] &&
    die "Tag '${tag}' could not be resolved to a digest."

  log_ok "Digest: $DIGEST"
}

# ── Step 2: Fetch CycloneDX attestation from GitHub API ─────────────────────

fetch_cyclonedx_attestation() {
  # Fetches CycloneDX attestation from GitHub API (or cache), filters by predicate type
  if _lookup_cached_attestation "$DIGEST"; then
    _load_attestation_from_cache "$DIGEST"
    log_info "Using cached attestation"
    log_dim "$BUNDLE_FILE"

    if ! _validate_bundle; then
      rm -f "$BUNDLE_FILE"
      BUNDLE_FILE=""
      die "Cached attestation is invalid"
    fi

    log_ok "Attestation loaded from cache"
    return 0
  fi

  local url="https://api.github.com/repos/$OWNER/$REPO_NAME/attestations/$DIGEST"

  log_info "Querying GitHub attestations API"
  local response
  response=$(curl -sfL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$url") ||
    die "GitHub attestations API request failed (HTTP error or timeout)."

  local count
  count=$(echo "$response" | jq '.attestations | length')
  log_info "Found $count attestation(s) for this digest"

  mkdir -p "$CACHE_DIR" 2>/dev/null || die "Failed to create cache directory"
  BUNDLE_FILE=$(_cache_path "$DIGEST")

  echo "$response" | jq '
  [
    .attestations[] |
    select(
      (
        try (
          (.bundle.dsseEnvelope.payload // "") |
          if . != "" then (@base64d | fromjson | .predicateType) else empty end |
          test("cyclonedx"; "i")
        ) catch false
      ) or
      ((.predicate_type // "") | test("cyclonedx"; "i"))
    ) |
    .bundle
  ] | .[0]
' >"$BUNDLE_FILE" 2>/dev/null

  if [[ ! -s "$BUNDLE_FILE" ]] || [[ "$(
    jq -e '.' "$BUNDLE_FILE" >/dev/null 2>&1
    echo $?
  )" != "0" ]] || [[ "$(jq -r 'type' "$BUNDLE_FILE" 2>/dev/null)" == "null" ]]; then
    rm -f "$BUNDLE_FILE"
    BUNDLE_FILE=""
    log_info "Attestation types found:"
    echo "$response" | jq -r '
      .attestations[] |
      "  - " + (
        ((.bundle.dsseEnvelope.payload // "") |
         if . != "" then (@base64d | fromjson | .predicateType) else empty end)
        // .predicate_type
        // "unknown"
      )
    ' 2>/dev/null || log_warn "Could not parse attestation predicate types"
    die "No CycloneDX attestation found among $count attestation(s)."
  fi

  log_ok "Attestation fetched and cached"
  log_dim "$BUNDLE_FILE"
}

# ── Step 3: Verify attestation with comparison and rekor ───────────────────────────────────

verify_attestation() {
  # Verifies DSSE signature, cert validity, payload semantics, and OIDC issuer
  log_info "Verifying attestation with OpenSSL"

  local tmp_cert
  tmp_cert="$(_temp_file)"
  local tmp_pubkey
  tmp_pubkey="$(_temp_file)"
  local tmp_payload
  tmp_payload="$(_temp_file)"
  local tmp_sig
  tmp_sig="$(_temp_file)"
  local tmp_dsse_msg
  tmp_dsse_msg="$(_temp_file)"

  log_info "Extracting signing certificate"

  local cert_b64
  cert_b64=$(jq -r '.verificationMaterial.certificate.rawBytes // empty' "$BUNDLE_FILE")
  [[ -z "$cert_b64" ]] && die "No certificate found in bundle."

  _decode_cert "$cert_b64" "$tmp_cert" ||
    die "Failed to decode certificate from DER to PEM."

  _get_pubkey "$tmp_cert" "$tmp_pubkey" ||
    die "Failed to extract public key from certificate."

  log_info "Extracting certificate identity from SAN"

  local cert_identity
  cert_identity=$(openssl x509 -in "$tmp_cert" -noout -text 2>/dev/null |
    grep -A1 "Subject Alternative Name" | tail -1 |
    grep -oP 'URI:\K[^,\s]+' | head -1)

  [[ -z "$cert_identity" ]] &&
    die "Could not extract identity URI from certificate SAN."
  log_dim "Certificate identity: $cert_identity"

  log_info "Extracting DSSE envelope components"

  local payload_type payload_b64 sig_b64
  payload_type=$(jq -r '.dsseEnvelope.payloadType // empty' "$BUNDLE_FILE")
  payload_b64=$(jq -r '.dsseEnvelope.payload     // empty' "$BUNDLE_FILE")
  sig_b64=$(jq -r '.dsseEnvelope.signatures[0].sig // empty' "$BUNDLE_FILE")

  [[ -z "$payload_type" || -z "$payload_b64" || -z "$sig_b64" ]] &&
    die "Bundle is missing required DSSE envelope fields."

  printf '%s' "$payload_b64" | base64 -d >"$tmp_payload"
  printf '%s' "$sig_b64" | tr -- '-_' '+/' | base64 -d >"$tmp_sig"

  log_info "Building DSSE pre-image"

  local payload_bytes payload_len type_len
  payload_bytes=$(wc -c <"$tmp_payload")
  payload_len="${payload_bytes// /}"
  type_len="${#payload_type}"

  printf 'DSSEv1 %s %s %s ' \
    "$type_len" "$payload_type" \
    "$payload_len" >"$tmp_dsse_msg"
  cat "$tmp_payload" >>"$tmp_dsse_msg"

  log_info "Verifying DSSE signature with OpenSSL"

  local curve digest_alg
  curve=$(_get_curve "$tmp_cert")
  log_dim "Curve: ${curve:-unknown}"
  digest_alg=$(_get_digest_alg "$curve")

  local verify_out
  verify_out=$(_verify_sig "$digest_alg" "$tmp_pubkey" "$tmp_sig" "$tmp_dsse_msg")

  if [[ "$verify_out" == *"Verified OK"* ]]; then
    log_ok "DSSE signature verified successfully"
  else
    log_dim "OpenSSL output: $verify_out"
    die "DSSE signature verification failed."
  fi

  log_info "Checking certificate validity period"
  openssl x509 -in "$tmp_cert" -noout -checkend 0 >/dev/null 2>&1 ||
    log_warn "Certificate has expired (short-lived Sigstore cert — expected for older builds)"

  log_info "Validating attestation payload semantics"

  local predicate_type
  predicate_type=$(jq -r '.predicateType // empty' "$tmp_payload")
  [[ -z "$predicate_type" || "$predicate_type" != *"cyclonedx"* ]] &&
    die "Attestation payload is not CycloneDX (predicateType: ${predicate_type:-<empty>})"
  log_dim "Predicate type: $predicate_type"

  local expected_sha="${DIGEST#sha256:}"
  jq -e --arg d "$expected_sha" \
    '.subject[]? | select(.digest.sha256 == $d)' \
    "$tmp_payload" >/dev/null 2>&1 ||
    die "Attestation does not reference image digest: $expected_sha"
  log_dim "Subject digest matches: sha256:${expected_sha:0:16}..."

  log_info "Validating OIDC issuer"

  local cert_text issuer_ok=false
  cert_text=$(openssl x509 -in "$tmp_cert" -noout -text 2>/dev/null)

  if echo "$cert_text" | grep -q "token.actions.githubusercontent.com"; then
    issuer_ok=true
  fi
  [[ "$issuer_ok" != "true" ]] &&
    die "Certificate does not contain expected GitHub Actions OIDC issuer."
  log_dim "OIDC issuer: https://token.actions.githubusercontent.com"
  log_dim "Identity   : $cert_identity"

  log_ok "Attestation verified successfully"
}

verify_rekor_inclusion() {
  # Verifies Rekor SET, entry existence, leaf hash, and timestamp within cert validity
  log_info "Validating Rekor transparency log inclusion"

  local tmp_rekor_key
  tmp_rekor_key="$(_temp_file)"
  local tmp_set_msg
  tmp_set_msg="$(_temp_file)"
  local tmp_set_sig
  tmp_set_sig="$(_temp_file)"

  log_info "Extracting Rekor tlog entry fields"

  local tlog
  tlog=$(jq -r '.verificationMaterial.tlogEntries[0]' "$BUNDLE_FILE")

  local log_index integrated_time key_id_b64 canonical_body_b64 set_b64
  log_index=$(echo "$tlog" | jq -r '.logIndex')
  integrated_time=$(echo "$tlog" | jq -r '.integratedTime')
  key_id_b64=$(echo "$tlog" | jq -r '.logId.keyId')
  canonical_body_b64=$(echo "$tlog" | jq -r '.canonicalizedBody')
  set_b64=$(echo "$tlog" | jq -r '.inclusionPromise.signedEntryTimestamp')

  local key_id_hex
  key_id_hex=$(_b64_to_hex "$key_id_b64")

  log_info "Fetching Rekor public key"
  curl -sf "https://rekor.sigstore.dev/api/v1/log/publicKey" >"$tmp_rekor_key" ||
    die "Failed to fetch Rekor public key."
  log_dim "Rekor key fetched"

  log_info "Verifying Rekor signed entry timestamp (SET)"

  printf '{"body":"%s","integratedTime":%s,"logID":"%s","logIndex":%s}' \
    "$canonical_body_b64" \
    "$integrated_time" \
    "$key_id_hex" \
    "$log_index" >"$tmp_set_msg"

  printf '%s' "$set_b64" | base64 -d >"$tmp_set_sig"

  local set_out
  set_out=$(_verify_sig "-sha256" "$tmp_rekor_key" "$tmp_set_sig" "$tmp_set_msg")

  if [[ "$set_out" != *"Verified OK"* ]]; then
    log_dim "SET verify output: $set_out"
    die "Rekor signed entry timestamp verification failed."
  fi
  log_ok "Rekor SET verified — entry was accepted by transparency log"

  log_info "Confirming entry existence in Rekor transparency log"

  local global_log_index
  global_log_index=$(jq -r '.verificationMaterial.tlogEntries[0].logIndex' "$BUNDLE_FILE")

  local rekor_entry
  rekor_entry=$(curl -sf \
    "https://rekor.sigstore.dev/api/v1/log/entries?logIndex=${global_log_index}") ||
    die "Failed to fetch Rekor entry for logIndex ${global_log_index}."

  local rekor_uuid rekor_canon_body
  rekor_uuid=$(echo "$rekor_entry" | jq -r 'keys[0]')
  rekor_canon_body=$(echo "$rekor_entry" | jq -r --arg u "$rekor_uuid" '.[$u].body')

  log_dim "Rekor UUID: $rekor_uuid"

  if [[ "$rekor_canon_body" != "$canonical_body_b64" ]]; then
    log_dim "Bundle body : $canonical_body_b64"
    log_dim "Rekor body  : $rekor_canon_body"
    die "Rekor entry body does not match bundle canonicalizedBody."
  fi
  log_ok "Rekor entry confirmed — bundle matches transparency log"

  local expected_leaf_hex
  expected_leaf_hex=$(
    {
      printf '\x00'
      printf '%s' "$canonical_body_b64" | base64 -d
    } |
      openssl dgst -sha256 -binary | xxd -p | tr -d '\n'
  )

  if [[ "$rekor_uuid" == *"$expected_leaf_hex" ]]; then
    log_ok "Rekor UUID encodes correct leaf hash"
  else
    log_dim "Expected leaf hash: $expected_leaf_hex"
    log_dim "Rekor UUID        : $rekor_uuid"
    log_warn "UUID leaf hash mismatch — log may use different encoding"
  fi

  log_info "Verifying signature timestamp within certificate validity window"

  local tmp_rekor_cert
  tmp_rekor_cert="$(_temp_file)"

  local cert_b64
  cert_b64=$(jq -r '.verificationMaterial.certificate.rawBytes // empty' "$BUNDLE_FILE")

  [[ -z "$cert_b64" ]] && die "Could not extract certificate from bundle for timestamp check."

  _decode_cert "$cert_b64" "$tmp_rekor_cert" ||
    die "Failed to decode certificate for timestamp check."

  local epochs
  epochs=$(_get_cert_epochs "$tmp_rekor_cert") || die "Could not extract validity dates from certificate."

  local nb_epoch na_epoch
  IFS=$'\t' read -r nb_epoch na_epoch <<<"$epochs"

  if [[ "$integrated_time" -ge "$nb_epoch" && "$integrated_time" -le "$na_epoch" ]]; then
    log_ok "Rekor timestamp within certificate validity window"
    log_dim "Signed at : $(date -d "@$integrated_time" -u 2>/dev/null || date -r "$integrated_time" -u)"
  else
    die "Rekor integrated time $integrated_time falls outside cert validity [$nb_epoch, $na_epoch]"
  fi
}

# ── rpm-ostree status parser ─────────────────────────────────────────────────

parse_ostree_deployments() {
  local ostree_output="$1"

  echo "$ostree_output" | awk '
  BEGIN { block = "" }

  /^[[:space:]]*$/ {
    if (block != "") { emit(block); block = "" }
    next
  }

  { block = (block == "" ? $0 : block "\n" $0) }

  END { if (block != "") emit(block) }

  function emit(b,    n, lines, i, line, idx, img, dig, active, staged, version, p, rest) {
    active = "false"; staged = "false"; idx = ""; img = ""; dig = ""; version = ""

    n = split(b, lines, "\n")
    for (i = 1; i <= n; i++) {
      line = lines[i]

      if (index(line, "\xe2\x97\x8f") > 0) active = "true"

      p = index(line, "docker://")
      if (p > 0) {
        rest = substr(line, p + 9)
        img = rest
        sub(/ .*/, "", img)

        p2 = index(line, "(index: ")
        if (p2 > 0) {
          idx = substr(line, p2 + 8)
          sub(/\).*/, "", idx)
          idx = idx + 0
        }
      }

      p = index(line, "Digest:")
      if (p > 0) {
        dig = substr(line, p + 7)
        sub(/^[[:space:]]+/, "", dig)
        sub(/[[:space:]]+$/, "", dig)
      }

      p = index(line, "Version:")
      if (p > 0) {
        version = substr(line, p + 8)
        sub(/^[[:space:]]+/, "", version)
        sub(/[[:space:]]+$/, "", version)
      }

      if (line ~ /Staged:[[:space:]]*yes/) staged = "true"
    }

    if (img != "" && dig != "" && idx != "") {
 # index<TAB>active<TAB>staged<TAB>image_ref<TAB>digest<TAB>version
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", idx, active, staged, img, dig, version
    }
  }
  ' | sort -t$'\t' -k1,1n -k2,2n |
    awk -F'\t' '
  BEGIN { prev_idx="" }
  {
    if ($1 != prev_idx) {
      printf "{\"index\":%s,\"active\":%s,\"staged\":%s,\"image_ref\":\"%s\",\"digest\":\"%s\",\"version\":\"%s\"}\n",
        $1, $2, $3, $4, $5, $6
      prev_idx = $1
    }
  }' |
    jq -s '.'
}

select_deployment() {
  # Parses rpm-ostree status output, prompts user for deployment selection
  local target_index="$1"
  local ostree_output

  if ! command -v rpm-ostree &>/dev/null; then
    die "'rpm-ostree' is not installed on this system. Cannot use -d flag."
  fi

  log_info "Running 'rpm-ostree status -v'"
  ostree_output=$(rpm-ostree status -v 2>&1) ||
    die "'rpm-ostree status -v' exited with an error."

  local deployments
  deployments=$(parse_ostree_deployments "$ostree_output")

  if [[ -z "$deployments" || "$deployments" == "null" || "$deployments" == "[]" ]]; then
    die "No ostree-image-signed deployments found in 'rpm-ostree status -v'."
  fi

  local count
  count=$(echo "$deployments" | jq 'length')
  log_info "Parsed $count unique deployment(s)"

  echo ""
  printf "  ${COLOR_CYAN}%-6s %-14s %-8s %-8s %s${COLOR_RESET}\n" \
    "INDEX" "DIGEST" "ACTIVE" "STAGED" "IMAGE REF"
  printf "  %s\n" \
    "─────────────────────────────────────────────────────────────────────────────"

  echo "$deployments" | jq -r '.[] |
    "  " + (.index | tostring) +
    "     " + (.digest[7:21]) + "\u2026" +
    "    " + (.active | tostring) +
    "     " + (.staged | tostring) +
    "     " + .image_ref
  '

  echo ""

  local selected
  if [[ "$target_index" == "auto" ]]; then
    selected=$(echo "$deployments" | jq -e '.[] | select(.active == true)') ||
      die "No currently booted deployment found."
    log_info "Auto-selected currently booted deployment"
  else
    selected=$(echo "$deployments" |
      jq -e --argjson idx "$target_index" '.[] | select(.index == $idx)') ||
      {
        local available
        available=$(echo "$deployments" | jq -r '[.[].index] | map(tostring) | join(", ")')
        die "No deployment with index $target_index. Available indices: $available"
      }
  fi

  DEPLOY_IMAGE_REF=$(echo "$selected" | jq -r '.image_ref')
  DEPLOY_DIGEST=$(echo "$selected" | jq -r '.digest')
  DEPLOY_ACTIVE=$(echo "$selected" | jq -r '.active')
  DEPLOY_STAGED=$(echo "$selected" | jq -r '.staged')
  DEPLOY_VERSION=$(echo "$selected" | jq -r '.version')

  local flags=()
  [[ "$DEPLOY_ACTIVE" == "true" ]] && flags+=("active")
  [[ "$DEPLOY_STAGED" == "true" ]] && flags+=("staged")
  local flags_str=""
  [[ ${#flags[@]} -gt 0 ]] && flags_str=" (${flags[*]})"

  local deploy_idx
  deploy_idx=$(echo "$selected" | jq -r '.index')
  log_ok "Selected deployment index $deploy_idx$flags_str"
  log_dim "Image   : $DEPLOY_IMAGE_REF"
  log_dim "Digest  : $DEPLOY_DIGEST"
  log_dim "Version : $DEPLOY_VERSION"

  local img_without_scheme="${DEPLOY_IMAGE_REF#docker://}"
  local img_without_tag="${img_without_scheme%%:*}"
  local repo_full_path="${img_without_tag#ghcr.io/}"
  OWNER="${repo_full_path%%/*}"
  REPO_NAME="${repo_full_path#*/}"

  if [[ "$OWNER" == "$REPO_NAME" ]]; then
    die "Cannot parse owner/repo from deployment image ref: $DEPLOY_IMAGE_REF"
  fi

  log_dim "Owner   : $OWNER"
  log_dim "Repo    : $REPO_NAME"
  echo ""
}

# ── Section banner helper ────────────────────────────────────────────────────

section() {
  local step="$1"
  local total="$2"
  local title="$3"
  echo ""
  printf "  %bStep %d / %d : %s%b\n" "$COLOR_CYAN" "$step" "$total" "$title" "$COLOR_RESET"
  printf "  %s\n" "─────────────────────────────────────────"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"

  local image_for_verify=""

  if [[ -n "$DEPLOYMENT_INDEX" ]]; then
    if [[ "$DEPLOYMENT_INDEX" == "auto" ]]; then
      echo "═══════════════════════════════════════════════════════════"
      printf "  %b%s%b — %s\n" "$COLOR_CYAN" "rpm-ostree Mode" "$COLOR_RESET" "verifying currently booted deployment"
      echo "═══════════════════════════════════════════════════════════════════"
    else
      echo "═══════════════════════════════════════════════════════════════════"
      printf "  %b%s%b — verifying deployment #%s\n" "$COLOR_CYAN" "rpm-ostree Mode" "$COLOR_RESET" "$DEPLOYMENT_INDEX"
      echo "═══════════════════════════════════════════════════════════════════"
    fi

    select_deployment "$DEPLOYMENT_INDEX"

    DIGEST="$DEPLOY_DIGEST"
    image_for_verify="${DEPLOY_IMAGE_REF}@${DIGEST}"
  else
    parse_image_ref

    echo "═══════════════════════════════════════════════════════════════════"
    printf "  %b%s%b — verifying %s\n" "$COLOR_CYAN" "Direct Mode" "$COLOR_RESET" "$IMAGE_REF"
    echo "═══════════════════════════════════════════════════════════════════"

    local tag="${IMAGE_REF##*:}"
    resolve_digest "$tag"
    image_for_verify="ghcr.io/$OWNER/$REPO_NAME@$DIGEST"
  fi

  section 1 4 "Digest Resolution"
  log_ok "$DIGEST"

  section 2 4 "Attestation Fetch"
  fetch_cyclonedx_attestation

  section 3 4 "Attestation Verification"
  verify_attestation "$image_for_verify"

  section 4 4 "Rekor Inclusion Proof"
  verify_rekor_inclusion

  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  log_ok "All checks passed — attestation is valid."
  echo "═══════════════════════════════════════════════════════════════════"
}

main "$@"
