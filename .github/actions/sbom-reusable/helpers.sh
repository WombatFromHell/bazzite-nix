#!/usr/bin/env bash
# helpers.sh — shared functions for SBOM generation, attach, and sign.

set -euo pipefail

is_transient_error() {
  local output="$1"
  echo "$output" | grep -qiE \
    '502|503|504|429|connection reset|connection refused|EOF|i/o timeout|TLS|unexpected HTTP|context deadline|net/http'
}

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

generate_sbom() {
  local image_name="$1"
  local version_tag="$2"
  local syft_cmd="$3"
  local oci_dir="$4"
  local image_ref="$5"

  echo "::group::Generate SBOM"

  mkdir -p "${oci_dir}/rootfs"

  echo "  Extracting container filesystem from ${image_ref}..."
  sudo podman container create --replace --name "sbom-extract-${image_name}" "${image_ref}"
  sudo podman export "sbom-extract-${image_name}" | sudo tar -C "${oci_dir}/rootfs" -xf -
  sudo podman container rm "sbom-extract-${image_name}"

  local sbom_dir sbom_file
  sbom_dir="$(mktemp -d)"
  sbom_file="${sbom_dir}/sbom.json"

  export SYFT_PARALLELISM=$(($(nproc) * 2))

  echo " Running Syft to generate SBOM..."
  echo " Source name: ${image_name}-${version_tag}"
  sudo "$syft_cmd" \
    --source-name "${image_name}-${version_tag}" \
    "${oci_dir}" \
    -o syft-json="${sbom_file}"

  echo "  SBOM size:"
  du -sh "${sbom_file}"

  if [[ ! -s "$sbom_file" ]]; then
    echo "::error::SBOM file is empty or missing: ${sbom_file}"
    return 1
  fi

  local sbom_digest
  sbom_digest=$(sha256sum "${sbom_file}" | cut -d' ' -f1)

  echo "  SBOM file digest: ${sbom_digest}"
  echo "sbom_path=${sbom_file}" >>"$GITHUB_OUTPUT"
  echo "sbom_file_digest=${sbom_digest}" >>"$GITHUB_OUTPUT"

  echo "  Cleaning up OCI directory..."
  sudo rm -rf "${oci_dir}"

  echo "::endgroup::"

  echo "✓ SBOM generated successfully"
}

attach_sbom_to_oci() {
  local sbom_path="$1"
  local image="$2"
  local image_digest="$3"
  local authfile="$4"

  echo "::group::Attach SBOM to OCI registry"

  local full_ref="${image}@${image_digest}"
  echo "  Attaching SBOM to: ${full_ref}"

  cd "$(dirname "${sbom_path}")"

  run_with_retry "oras attach ${full_ref}" \
    --stream \
    oras attach \
    --auth-file "${authfile}" \
    --artifact-type application/vnd.syft+json \
    --annotation "org.opencontainers.artifact.created=auto" \
    --annotation "sbom.source=anchore/syft" \
    "${full_ref}" \
    "$(basename "${sbom_path}")"

  echo "  Discovering attached SBOM digest..."
  local sbom_digest
  sbom_digest=$(oras discover --format json "${full_ref}" |
    jq -r '.referrers[] | select(.artifactType == "application/vnd.syft+json") | .digest')

  if [[ -z "$sbom_digest" ]] || [[ "$sbom_digest" == "null" ]]; then
    echo "::error::Failed to discover SBOM digest from OCI registry"
    return 1
  fi

  echo "  SBOM artifact digest: ${sbom_digest}"
  echo "sbom_remote_digest=${sbom_digest}" >>"$GITHUB_OUTPUT"

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

  echo "signed=true" >>"$GITHUB_OUTPUT"
  echo "✓ SBOM artifact signed"
}
