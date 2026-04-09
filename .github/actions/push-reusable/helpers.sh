#!/usr/bin/env bash
# helpers.sh — shared functions for push, sign, and verify steps.
# Expects MAX_ATTEMPTS, RETRY_DELAY, GITHUB_ACTOR, GITHUB_TOKEN to be set
# in the calling environment.

set -euo pipefail

# ── error classification ────────────────────────────────────────────────────

is_transient_error() {
  local output="$1"
  echo "$output" | grep -qiE \
    '502|503|504|429|connection reset|connection refused|EOF|i/o timeout|TLS|unexpected HTTP|context deadline|net/http'
}

# ── generic retry wrapper for arbitrary commands ────────────────────────────
# Usage: run_with_retry <label> [--stdin-data <data>] [--stream] <cmd> [args...]
# Applies the same transient-error classification and exponential backoff.
#
# Options:
#   --stdin-data <data>  Pipe the provided string to the command's stdin.
#   --stream             Stream output to terminal in real-time via tee while
#                        also capturing to a temp file for error classification.
#                        Without this flag, output is only visible on failure.

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
  for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    echo "  ${label} (attempt ${attempt}/${MAX_ATTEMPTS})"

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

    echo "  ✗ exited ${exit_code}: $(echo "$output" | tail -3)"

    if is_transient_error "$output"; then
      if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
        echo "::error::All ${MAX_ATTEMPTS} attempts failed for: ${label}"
        return 1
      fi
      local delay=$((RETRY_DELAY * attempt))
      echo "::warning::Transient error on attempt ${attempt}. Retrying in ${delay}s…"
      sleep "$delay"
    else
      echo "::error::Permanent error — not retrying: ${label}"
      echo "::error::Output: ${output}"
      return 1
    fi
  done
  # Defensive: should never reach here (all branches return inside the loop)
  return 1
}

# ── convenience wrapper for skopeo copy ─────────────────────────────────────
# Hardcodes authfile, streams output, and retries on transient errors.

skopeo_copy_with_retry() {
  local src="$1"
  local dst="$2"
  shift 2
  local extra_flags=("$@")

  run_with_retry "skopeo copy ${src} → ${dst}" \
    --stream \
    sudo skopeo copy \
    --authfile /tmp/skopeo-auth/auth.json \
    "${extra_flags[@]}" \
    "${src}" "${dst}"
}

# ── digest verification ─────────────────────────────────────────────────────

verify_digest() {
  local ref="$1"
  local expected="$2"
  local actual
  actual=$(sudo skopeo inspect \
    --authfile /tmp/skopeo-auth/auth.json \
    --format='{{.Digest}}' \
    "docker://${ref}" 2>/dev/null || true)
  if [[ "$actual" != "$expected" ]]; then
    echo "::error::Digest mismatch — expected ${expected}, got ${actual}"
    return 1
  fi
  echo "  ✓ digest verified: ${actual}"
}

# ── push image and additional tags ──────────────────────────────────────────
# Usage: push_image_with_tags <source_ref> <tags_csv> <base_img>
# Writes to stderr (logs/groups); prints to stdout for $GITHUB_OUTPUT:
#   remote_digest=<digest>
#   remote_digest_ref=<ref>

push_image_with_tags() {
  local source_ref="$1"
  local tags_csv="$2"
  local base_img="$3"

  IFS=',' read -r -a TAGS_ARR <<<"$tags_csv"

  echo "::group::Push primary tag (${TAGS_ARR[0]})" >&2
  echo "Source ref : ${source_ref}" >&2
  echo "Target     : docker://${base_img}:${TAGS_ARR[0]}" >&2
  skopeo_copy_with_retry \
    "${source_ref}" \
    "docker://${base_img}:${TAGS_ARR[0]}"
  echo "::endgroup::" >&2

  echo "::group::Inspect + verify primary digest" >&2
  local remote_digest
  remote_digest=$(sudo skopeo inspect \
    --authfile /tmp/skopeo-auth/auth.json \
    --format='{{.Digest}}' \
    "docker://${base_img}:${TAGS_ARR[0]}")

  [[ -z "$remote_digest" ]] &&
    {
      echo "::error::inspect returned empty digest" >&2
      return 1
    }

  verify_digest "${base_img}:${TAGS_ARR[0]}" "$remote_digest" >&2

  local short_digest="${remote_digest#sha256:}"
  local remote_digest_ref="${base_img}@${remote_digest}"
  echo "Digest     : ${remote_digest}" >&2
  echo "Digest ref : ${remote_digest_ref}" >&2
  echo "::endgroup::" >&2

  echo "::group::Push additional tags" >&2
  local tag
  for tag in "${TAGS_ARR[@]:1}" "$short_digest"; do
    echo "  → ${base_img}:${tag}" >&2
    skopeo_copy_with_retry \
      "docker://${remote_digest_ref}" \
      "docker://${base_img}:${tag}"
  done
  echo "::endgroup::" >&2

  echo "remote_digest=${remote_digest}"
  echo "remote_digest_ref=${remote_digest_ref}"
}

# ── sign, verify, and inspect image ─────────────────────────────────────────
# Usage: sign_and_verify_image <digest_ref> <cosign_pub_key> <authfile> \
#                              <github_actor> <github_token> \
#                              <github_step_summary> <variant_name> <tags> \
#                              <date> <parent_version> <registry> <repo> <suffix>
# Exports SIGNING_SECRET for cosign env:// key reference.
# Writes to stderr (logs/groups) and $GITHUB_STEP_SUMMARY; prints to stdout:
#   status=success

sign_and_verify_image() {
  local digest_ref="$1"
  local cosign_pub_key="$2"
  local authfile="$3"
  local github_actor="$4"
  local github_token="$5"
  local github_step_summary="$6"
  local variant_name="$7"
  local tags="$8"
  local date="$9"
  local parent_version="${10}"
  local registry="${11}"
  local repo="${12}"
  local suffix="${13}"

  echo "::group::Sign image" >&2
  run_with_retry "cosign sign ${digest_ref}" \
    --stream \
    cosign sign -y \
    --key env://SIGNING_SECRET \
    --new-bundle-format=false \
    --use-signing-config=false \
    --registry-referrers-mode=legacy \
    --registry-username "${github_actor}" \
    --registry-password "${github_token}" \
    "${digest_ref}"
  echo "::endgroup::" >&2

  echo "::group::Verify image" >&2
  run_with_retry "cosign verify ${digest_ref}" \
    --stream \
    cosign verify \
    --key "${cosign_pub_key}" \
    "${digest_ref}"
  echo "::endgroup::" >&2

  echo "::group::Inspect layer sizes" >&2
  local total_mb
  total_mb=$(sudo skopeo inspect --raw \
    --authfile "${authfile}" \
    "docker://${digest_ref}" |
    jq '([.layers[].size] | add) / 1024 / 1024 | round')
  echo "Total compressed size: ${total_mb} MB" >&2
  echo "::endgroup::" >&2

  local remote_digest="${digest_ref#*@sha256:}"

  {
    echo "## ${variant_name}"
    echo ""
    echo "| Field | Value |"
    echo "| ----- | ----- |"
    echo "| **Image**             | \`${registry}/${repo}${suffix}\` |"
    echo "| **Digest**            | \`${remote_digest}\` |"
    echo "| **Tags**              | \`${tags}\` |"
    echo "| **Parent version**    | \`${parent_version}\` |"
    echo "| **Built**             | \`${date}\` |"
    echo "| **Image size**        | \`${total_mb} MB\` |"
    echo "| **Signed & verified** | ✅ |"
  } >>"$github_step_summary"

  echo "status=success"
}
