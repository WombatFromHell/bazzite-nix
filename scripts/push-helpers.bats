#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# push-helpers.bats — Tests for scripts/push-helpers.bash
#
# Run with: bats scripts/push-helpers.bats
# Or:       bats --pretty scripts/push-helpers.bats
#
# podman and oras are stubbed: no containers-storage and no registry traffic.
# The podman stub writes the digest file a real push would have written, and the
# oras stub records one "call" header plus one line per argument, so tag
# membership and call counts are asserted exactly.

setup() {
  load 'push-helpers'
  MAX_ATTEMPTS=2
  RETRY_DELAY=0
  STUB_DIGEST="sha256:$(printf '0%.0s' {1..63})7"
  ORAS_CALLS="$(mktemp)"
  AUTHFILE="$(mktemp)"
  echo '{}' >"$AUTHFILE"
}

teardown() {
  rm -f "$ORAS_CALLS" "$AUTHFILE"
}

# Stub: podman push --authfile A --digestfile D SRC DEST
podman() {
  local digestfile=""
  while (($#)); do
    if [[ "$1" == "--digestfile" ]]; then
      digestfile="$2"
      break
    fi
    shift
  done
  printf '%s\n' "${STUB_DIGEST-}" >"$digestfile"
}

# Stub: one "call" header per oras invocation, then one line per argument.
oras() {
  printf 'call\n' >>"$ORAS_CALLS"
  printf '%s\n' "$@" >>"$ORAS_CALLS"
}

# ── push_image_with_tags ────────────────────────────────────────────────────

@test "digest comes from the push, and stdout keeps its contract" {
  local out
  out=$(push_image_with_tags "containers-storage:localhost/chunked-img:stable" "stable-44.1,stable" "ghcr.io/o/r" "$AUTHFILE")
  [ "$(grep -c '^call$' "$ORAS_CALLS")" = "1" ]
  grep -qE "^remote_digest=${STUB_DIGEST}$" <<<"$out"
  grep -qE "^remote_digest_ref=ghcr.io/o/r@${STUB_DIGEST}$" <<<"$out"
}

@test "extra tags and the digest tag are applied in one oras call" {
  push_image_with_tags "containers-storage:localhost/raw-img:testing" "testing-44.1,testing,latest" "ghcr.io/o/r" "$AUTHFILE" >/dev/null
  [ "$(grep -c '^call$' "$ORAS_CALLS")" = "1" ]
  grep -qxF -- '--registry-config' "$ORAS_CALLS"
  for wanted in testing latest "${STUB_DIGEST#sha256:}"; do
    grep -qxF -- "$wanted" "$ORAS_CALLS"
  done
}

@test "digest tag already in the tag list is not tagged a second time" {
  local short="${STUB_DIGEST#sha256:}"
  push_image_with_tags "containers-storage:localhost/raw-img:stable" "stable,$short" "ghcr.io/o/r" "$AUTHFILE" >/dev/null
  [ "$(grep -c '^call$' "$ORAS_CALLS")" = "1" ]
  [ "$(grep -cxF -- "$short" "$ORAS_CALLS")" = "1" ]
}

@test "empty digest fails instead of tagging a blank ref" {
  local err
  STUB_DIGEST=""
  err="$(mktemp)"
  push_image_with_tags "containers-storage:localhost/raw-img:stable" "stable" "ghcr.io/o/r" "$AUTHFILE" 2>"$err" || true
  grep -qxF -- '::error::podman push returned empty digest' "$err"
  [ "$(grep -c '^call$' "$ORAS_CALLS")" = "0" ]
  rm -f "$err"
}

@test "the tag call stops retrying at MAX_ATTEMPTS" {
  local counter_file tries
  MAX_ATTEMPTS=2
  counter_file="$(mktemp)"
  echo 0 >"$counter_file"
  oras() {
    tries=$(<"$counter_file")
    echo "$((tries + 1))" >"$counter_file"
    echo '503 upstream, retry later' >&2
    return 1
  }
  push_image_with_tags "containers-storage:localhost/raw-img:stable" "stable-1,stable" "ghcr.io/o/r" "$AUTHFILE" >/dev/null || true
  [ "$(cat "$counter_file")" = "2" ]
  [ "$(grep -c '^call$' "$ORAS_CALLS")" = "0" ]
  rm -f "$counter_file"
}

# ── release step summary ───────────────────────────────────────────────────

@test "the step summary carries the image, its tags, and the size" {
  local summary; summary="$(mktemp)"
  GITHUB_STEP_SUMMARY="$summary"
  GITHUB_ACTOR="octocat"
  GITHUB_TOKEN="fake-token"
  cosign() { return 0; }
  oras() { printf '{"layers":[{"size":%s}]}' "$((1234 * 1024 * 1024))"; }

  sign_and_verify_image '{"digest_ref":"ghcr.io/o/r@sha256:deadbeef","authfile":"/tmp/skopeo-auth/auth.json","variant":"stable","tags":"stable-44.20260520,stable","date":"2026-05-20","parent_version":"44.20260520","base_img":"ghcr.io/o/r:stable"}' >/dev/null

  grep -q '`ghcr.io/o/r:stable`' "$summary"
  grep -q '`stable-44.20260520,stable`' "$summary"
  grep -q '`deadbeef`' "$summary"
  grep -q '1234 MB' "$summary"
  grep -q 'Signed & verified' "$summary"
  rm -f "$summary"
}
