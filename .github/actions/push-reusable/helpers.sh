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

# ── per-call retry wrapper for skopeo copy ──────────────────────────────────

skopeo_copy_with_retry() {
  local src="$1"
  local dst="$2"
  shift 2
  local extra_flags=("$@")

  local attempt output exit_code
  for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    echo "  copy ${src} → ${dst} (attempt ${attempt}/${MAX_ATTEMPTS})"

    set +e
    output=$(sudo skopeo copy \
      --authfile /tmp/skopeo-auth/auth.json \
      "${extra_flags[@]}" \
      "${src}" "${dst}" 2>&1)
    exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
      return 0
    fi

    echo "  ✗ skopeo exited ${exit_code}: $(echo "$output" | tail -3)"

    if is_transient_error "$output"; then
      if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
        echo "::error::All ${MAX_ATTEMPTS} attempts failed for ${dst}"
        echo "::error::Last output: ${output}"
        return 1
      fi
      local delay=$((RETRY_DELAY * attempt))
      echo "::warning::Transient error on attempt ${attempt}. Retrying in ${delay}s…"
      sleep "$delay"
    else
      echo "::error::Permanent error pushing to ${dst} — not retrying."
      echo "::error::Output: ${output}"
      return 1
    fi
  done
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

# ── generic retry wrapper for arbitrary commands ────────────────────────────
# Usage: run_with_retry <label> <cmd> [args...]
# Applies the same transient-error classification and exponential backoff.
# The command's combined stdout+stderr is captured only on failure — on
# success it streams directly so callers see live output.

run_with_retry() {
  local label="$1"
  shift
  local cmd=("$@")

  local attempt output exit_code tmpfile
  for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    echo "  ${label} (attempt ${attempt}/${MAX_ATTEMPTS})"

    tmpfile=$(mktemp)
    set +e
    "${cmd[@]}" >"$tmpfile" 2>&1
    exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
      cat "$tmpfile"
      rm -f "$tmpfile"
      return 0
    fi

    output=$(cat "$tmpfile")
    rm -f "$tmpfile"

    echo "  ✗ exited ${exit_code}: $(echo "$output" | tail -3)"

    if is_transient_error "$output"; then
      if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
        echo "::error::All ${MAX_ATTEMPTS} attempts failed for: ${label}"
        echo "::error::Last output: ${output}"
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
}
