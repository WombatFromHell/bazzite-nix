#!/usr/bin/env bash
# helpers.sh — shared functions for SBOM generation, attach, and sign.

set -euo pipefail

# ── helper functions ────────────────────────────────────────────────────────

is_transient_error() {
  local output="$1"
  echo "$output" | grep -qiE \
    '502|503|504|429|connection reset|connection refused|EOF|i/o timeout|TLS|unexpected HTTP|context deadline|net/http'
}

sbom_validate_and_digest() {
  local sbom_file="$1"

  if [[ ! -s "$sbom_file" ]]; then
    echo "::error::SBOM file is empty or missing: ${sbom_file}"
    return 1
  fi

  echo "  SBOM size:"
  sudo du -sh "${sbom_file}"

  local sbom_digest
  sbom_digest=$(sudo sha256sum "${sbom_file}" | cut -d' ' -f1)
  echo "  SBOM digest: ${sbom_digest}"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "sbom_path=${sbom_file}" >>"$GITHUB_OUTPUT"
    echo "sbom_file_digest=${sbom_digest}" >>"$GITHUB_OUTPUT"
  fi
}

# ── retry logic ─────────────────────────────────────────────────────────────

run_with_retry() {
  local label="$1"
  shift

  local stdin_data=""
  local stream=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --stdin-data)
      stdin_data="$2"
      shift 2
      ;;
    --stream)
      stream=true
      shift
      ;;
    *)
      break
      ;;
    esac
  done

  local cmd=("$@")

  local attempt output exit_code tmpfile
  for attempt in $(seq 1 "${MAX_ATTEMPTS:-3}"); do
    echo "  ${label} (attempt ${attempt}/${MAX_ATTEMPTS:-3})" >&2

    tmpfile=$(mktemp)
    set +e
    if [[ -n "$stdin_data" ]]; then
      if $stream; then
        printf '%s' "$stdin_data" | "${cmd[@]}" 2>&1 | tee /dev/stderr >"$tmpfile"
        exit_code=${PIPESTATUS[1]}
      else
        printf '%s' "$stdin_data" | "${cmd[@]}" >"$tmpfile" 2>&1
        exit_code=$?
      fi
    else
      if $stream; then
        "${cmd[@]}" 2>&1 | tee /dev/stderr >"$tmpfile"
        exit_code=${PIPESTATUS[0]}
      else
        "${cmd[@]}" >"$tmpfile" 2>&1
        exit_code=$?
      fi
    fi
    set -e

    if [[ $exit_code -eq 0 ]]; then
      rm -f "$tmpfile"
      return 0
    fi

    output=$(cat "$tmpfile")
    rm -f "$tmpfile"

    echo "  ✗ exited ${exit_code}: $(echo "$output" | tail -3)" >&2

    if is_transient_error "$output"; then
      if [[ "$attempt" -ge "${MAX_ATTEMPTS:-3}" ]]; then
        echo "::error::All ${MAX_ATTEMPTS:-3} attempts failed for: ${label}" >&2
        return 1
      fi
      local delay=$((${RETRY_DELAY:-15} * attempt))
      echo "::warning::Transient error on attempt ${attempt}. Retrying in ${delay}s…" >&2
      sleep "$delay"
    else
      echo "::error::Permanent error — not retrying: ${label}" >&2
      echo "::error::Output: $output" >&2
      return 1
    fi
  done
  return 1
}

# ── SBOM generation ──────────────────────────────────────────────────────────

generate_sbom_to_file() {
  local source="$1"
  local source_name="$2"
  local syft_cmd="$3"
  local output_file="$4"

  echo "::group::Generate SBOM to file"

  echo "  Generating SBOM from ${source}..."
  echo "  Source name: ${source_name}"
  echo "  Output path: ${output_file}"

  local tmpdir="${TMPDIR:-/tmp/syft-tmp}"
  rm -rf "${tmpdir:?}/"
  mkdir -p "${tmpdir}"

  export SYFT_PARALLELISM=$(($(nproc) * 2))
  TMPDIR="$tmpdir" sudo "$syft_cmd" \
    "${source}" \
    --source-name "${source_name}" \
    --config syft-config.yaml \
    -o cyclonedx-json="${output_file}"

  sbom_validate_and_digest "${output_file}"

  echo "::endgroup::"

  echo "✓ SBOM generated successfully at ${output_file}"
}

extract_embedded_sbom() {
  local image_ref="$1"

  echo "::group::Extract embedded SBOM"

  echo "  Pulling image ${image_ref}..."
  sudo podman pull "${image_ref}"

  local sbom_dir
  sbom_dir="$(mktemp -d)"
  local sbom_file="${sbom_dir}/sbom.json"

  echo "  Extracting SBOM from image..."
  sudo podman run --rm "${image_ref}" cat /usr/share/ublue-os/sbom.json | sudo tee "${sbom_file}" >/dev/null

  if [[ ! -s "$sbom_file" ]]; then
    echo "::error::Embedded SBOM not found or is empty"
    rm -rf "${sbom_dir}"
    exit 1
  fi

  sbom_validate_and_digest "${sbom_file}"

  echo "::endgroup::"

  echo "✓ SBOM extracted successfully"
}

# ── OCI operations ───────────────────────────────────────────────────────────

attach_sbom_to_oci() {
  local sbom_path="$1"
  local image="$2"
  local image_digest="$3"
  local authfile="$4"

  echo "::group::Attach SBOM to OCI registry"

  local full_ref="${image}@${image_digest}"
  local sbom_filename
  sbom_filename="$(basename "${sbom_path}")"
  local sbom_dir
  sbom_dir="$(dirname "${sbom_path}")"

  echo "  Attaching SBOM to: ${full_ref}"

  cd "${sbom_dir}"

  run_with_retry "oras attach ${full_ref}" \
    --stream \
    oras attach \
    --registry-config "${authfile}" \
    --artifact-type application/vnd.cyclonedx+json \
    --annotation "org.opencontainers.artifact.created=auto" \
    --annotation "sbom.source=anchore/syft" \
    "${full_ref}" \
    "${sbom_filename}"

  echo "  Discovering attached SBOM digest..."
  local sbom_digest
  sbom_digest=$(oras discover --format json "${full_ref}" |
    jq -r '.referrers[] | select(.artifactType == "application/vnd.cyclonedx+json") | .digest')

  if [[ -z "$sbom_digest" ]] || [[ "$sbom_digest" == "null" ]]; then
    echo "::error::Failed to discover SBOM digest from OCI registry"
    return 1
  fi

  echo "  SBOM artifact digest: ${sbom_digest}"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "sbom_remote_digest=${sbom_digest}" >>"$GITHUB_OUTPUT"

  echo "::endgroup::"

  echo "✓ SBOM attached to OCI registry"
}

sign_sbom_artifact() {
  local signing_secret="$1"
  local image="$2"
  local sbom_digest="$3"
  local github_actor="$4"
  local github_token="$5"

  echo "::group::Sign SBOM artifact"

  local full_ref="${image}@${sbom_digest}"
  echo "  Signing SBOM artifact: ${full_ref}"

  export COSIGN_PRIVATE_KEY="${signing_secret}"

  run_with_retry "cosign sign ${full_ref}" \
    --stream \
    cosign sign -y \
    --key env://COSIGN_PRIVATE_KEY \
    --new-bundle-format=false \
    --use-signing-config=false \
    --registry-referrers-mode=legacy \
    --registry-username "${github_actor}" \
    --registry-password "${github_token}" \
    "${full_ref}"

  echo "::endgroup::"

  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "signed=true" >>"$GITHUB_OUTPUT"
  echo "✓ SBOM artifact signed"
}

# ── registry helpers ────────────────────────────────────────────────────────

find_latest_tag() {
  local repo="$1"
  local variant="$2"

  local tags_output
  tags_output=$(crane ls "$repo" 2>&1) || return 1

  echo "$tags_output" |
    grep -E "^${variant}-[0-9]+\.[0-9]{8}(\.[0-9]+)?$" |
    grep -vE '^[0-9a-f]{64}$' |
    grep -vE '\.sig$' |
    sort -t. -k1,1n -k2,2n -k3,3n |
    tail -1 || true
}

build_matrix() {
  local variants="$1"
  local output_repo_base="$2"
  local repo_name="$3"

  local owner_lower="${output_repo_base#ghcr.io/}"
  owner_lower="${owner_lower,,}"
  local output_repo_base_lower="ghcr.io/${owner_lower}"

  local matrix_entries="[]"

  for variant in $(echo "$variants" | jq -r '.[]'); do
    echo "::group::Processing variant: ${variant}"

    local variant_config
    variant_config=$(jq -c --arg v "$variant" '.variants[] | select(.name == $v)' .github/variants.json)

    local suffix disabled output_repo
    suffix=$(echo "$variant_config" | jq -r '.suffix // ""')
    disabled=$(echo "$variant_config" | jq -r '.disabled // false')

    if [ "$disabled" = "true" ]; then
      echo "  Variant '${variant}' is disabled in variants.json, skipping"
      echo "::endgroup::"
      continue
    fi

    output_repo=$(echo "$variant_config" | jq -r '.output_repo // empty')
    output_repo="${output_repo:-${output_repo_base_lower}/${repo_name}}"
    local full_repo="${output_repo}${suffix}"

    echo "  Output repo: ${full_repo}, Suffix: '${suffix}'"

    local latest_tag
    latest_tag=$(find_latest_tag "$full_repo" "$variant")

    if [ -z "$latest_tag" ]; then
      echo "::warning::No matching tag for '${variant}' in ${full_repo}"
      echo "::endgroup::"
      continue
    fi

    echo "  Latest tag: ${latest_tag}"

    local digest
    digest=$(crane digest "${full_repo}:${latest_tag}" 2>&1 || true)
    if [ -z "$digest" ] || [ "$digest" = "null" ]; then
      echo "::error::Could not get digest for ${full_repo}:${latest_tag}"
      echo "::endgroup::"
      continue
    fi

    local canonical_tag="${latest_tag#"${variant}"-}"

    matrix_entries=$(echo "$matrix_entries" | jq --arg v "$variant" --arg t "$canonical_tag" --arg s "$suffix" --arg d "$digest" --arg tag "$latest_tag" \
      '. + [{"variant": $v, "canonical_tag": $t, "suffix": $s, "image_digest": $d, "image_tag": $tag}]')

    echo "::endgroup::"
  done

  local count
  count=$(echo "$matrix_entries" | jq 'length')
  if [ "$count" -gt 0 ]; then
    [[ -n "${GITHUB_OUTPUT:-}" ]] && {
      echo "has_entries=true"
      echo "matrix<<EOF"
      echo "$matrix_entries" | jq -c '.'
      echo "EOF"
    } >>"$GITHUB_OUTPUT"
  else
    echo "::error::No variants had matching images"
    [[ -n "${GITHUB_OUTPUT:-}" ]] && {
      echo "has_entries=false"
      echo "matrix=[]"
    } >>"$GITHUB_OUTPUT"
  fi
}

check_attestation() {
  local image_ref="$1"
  local referrer_type="${2:-application/vnd.cyclonedx+json}"

  local attestations
  attestations=$(oras discover --format json "$image_ref" 2>/dev/null || true)

  local has_provenance
  has_provenance=$(echo "$attestations" | jq -r '.referrers[] | select(.artifactType == "application/in-toto+json") | .digest' 2>/dev/null || true)

  local has_sbom=false
  if [[ "$referrer_type" != "none" ]]; then
    local sbom_digest
    sbom_digest=$(echo "$attestations" | jq -r ".referrers[] | select(.artifactType == \"${referrer_type}\") | .digest" 2>/dev/null || true)
    if [[ -n "$sbom_digest" ]] && [[ "$sbom_digest" != "null" ]]; then
      has_sbom=true
    fi
  fi

  local has_attestation=false
  if [[ -n "$has_provenance" ]] && [[ "$has_provenance" != "null" ]]; then
    has_attestation=true
  fi

  echo "  Attestation found: ${has_attestation}"
  echo "  SBOM referrer found: ${has_sbom}"

  [[ -n "${GITHUB_OUTPUT:-}" ]] && {
    echo "has_attestation=${has_attestation}"
    echo "has_sbom_referrer=${has_sbom}"
  } >>"$GITHUB_OUTPUT"

  if [[ "$has_attestation" == "true" ]] && [[ "$has_sbom" == "true" ]]; then
    return 0
  else
    return 1
  fi
}
