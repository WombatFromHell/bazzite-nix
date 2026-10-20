#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# check-variants.bats — Tests for the check-variants helper parts
#
# Run with: bats scripts/check-variants.bats
# Or:       bats --pretty scripts/check-variants.bats
#
# Sources the part files directly (not the umbrella) — also proves the
# parts are composable.

setup() {
  # check-variants-tags.bash — pure tag/metadata functions
  load 'check-variants-tags'
  # check-variants-registry.bash — skopeo primitives (+ retry globals)
  load 'check-variants-registry'
  # GHA log directives the parts call (fail / warn)
  load 'log-helpers'

  # Stub skopeo: `inspect` exits 0 iff the tag is listed in $FAKE_REGISTRY_TAGS
  STUB_DIR="$(mktemp -d)"
  cat >"$STUB_DIR/skopeo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "inspect" ]]; then
    ref="${2:-}"
    ref="${ref#docker://}"
    ref="${ref##*:}"
    case " ${FAKE_REGISTRY_TAGS:-} " in
    *" $ref "*) exit 0 ;;
    *) exit 1 ;;
    esac
fi
exit 0
EOF
  chmod +x "$STUB_DIR/skopeo"
  export PATH="$STUB_DIR:$PATH"
}

teardown() {
  rm -rf "$STUB_DIR"
}

# ── generate_tags ───────────────────────────────────────────────────────────

@test "generate_tags default fallback mirrors the unstable variant" {
  local out
  out=$(generate_tags "stable" "44.20260520" "false" "")
  [ "$out" = "stable-44.20260520,stable-44,stable" ]
}

@test "generate_tags appends latest last" {
  local out
  out=$(generate_tags "testing" "44.20260520" "true" "")
  [ "$out" = "testing-44.20260520,testing-44,testing,latest" ]
}

@test "generate_tags expands tags_json placeholders" {
  local tags_json='{"branch":"custom","versioned":["{branch}-{canonical}","{branch}-{major}-{canonical}"]}'
  local out
  out=$(generate_tags "unstable" "44.20260520.1" "false" "$tags_json")
  [ "$out" = "custom-44.20260520.1,custom-44-44.20260520.1" ]
}

@test "generate_tags defaults tags branch to base image tag" {
  local tags_json='{"versioned":["{branch}-{canonical}"]}'
  local out
  out=$(generate_tags "unstable" "44.20260520.1" "false" "$tags_json")
  [ "$out" = "unstable-44.20260520.1" ]
}

@test "generate_tags skips sha256 placeholders when digest is empty" {
  local tags_json='{"versioned":["{branch}-{canonical}","{branch}-{sha256}"]}'
  local out
  out=$(generate_tags "unstable" "44.20260520.1" "false" "$tags_json")
  [ "$out" = "unstable-44.20260520.1" ]
}

# ── extract_image_metadata ──────────────────────────────────────────────────

@test "extract_image_metadata parses version and digest" {
  local json='{"Digest":"sha256:abc123","Labels":{"org.opencontainers.image.version":"44.20260520"}}'
  local out
  out=$(extract_image_metadata "$json")
  [ "$out" = "44.20260520 abc123" ]
}

@test "extract_image_metadata fails when version label is missing" {
  local json='{"Digest":"sha256:abc123","Labels":{}}'
  run extract_image_metadata "$json"
  [ "$status" -eq 1 ]
}

@test "extract_image_metadata fails when version is latest" {
  local json='{"Digest":"sha256:abc123","Labels":{"org.opencontainers.image.version":"latest"}}'
  run extract_image_metadata "$json"
  [ "$status" -eq 1 ]
}

# ── compute_canonical_tag ───────────────────────────────────────────────────

@test "compute_canonical_tag strips branch prefix" {
  local out
  out=$(compute_canonical_tag "testing-44.20260520" "ghcr.io/owner/repo" "false" "testing")
  [ "$out" = "44.20260520 false" ]
}

@test "compute_canonical_tag force_build with free tag passes through" {
  export FAKE_REGISTRY_TAGS=""
  local out
  out=$(compute_canonical_tag "stable-44.20260520" "ghcr.io/owner/repo" "true" "stable")
  [ "$out" = "44.20260520 false" ]
}

@test "compute_canonical_tag bumps past colliding tags" {
  export FAKE_REGISTRY_TAGS="testing-44.20260520.1 testing-44.20260520.2"
  local out
  out=$(compute_canonical_tag "testing-44.20260520.1" "ghcr.io/owner/repo" "true" "testing")
  [ "$out" = "44.20260520.3 true" ]
}

@test "compute_canonical_tag stops the bump walk at the budget" {
  export FAKE_REGISTRY_TAGS="testing-44.20260520.1 testing-44.20260520.2 testing-44.20260520.3 testing-44.20260520.4 testing-44.20260520.5 testing-44.20260520.6 testing-44.20260520.7"
  local out
  ! out=$(compute_canonical_tag "testing-44.20260520.1" "ghcr.io/owner/repo" "true" "testing" 2>&1)
  [[ "$out" == *"stopping the bump walk"* ]]
}

# ── find_latest_versioned_tag ───────────────────────────────────────────────

@test "a tag listing that fails twice still resolves the newest tag" {
  printf '0\n' >"$STUB_DIR/attempts"
  cat >"$STUB_DIR/skopeo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list-tags" ]]; then
    n=$(<"$ATTEMPT_FILE")
    echo "$((n + 1))" >"$ATTEMPT_FILE"
    if (( n < 2 )); then exit 1; fi
    printf '{"Tags":["bazzite-stable-44.20260520","bazzite-stable-44"]}\n'
    exit 0
fi
exit 1
EOF
  chmod +x "$STUB_DIR/skopeo"
  export ATTEMPT_FILE="$STUB_DIR/attempts"
  RETRY_DELAY=0

  local out
  out=$(find_latest_versioned_tag "ghcr.io/owner/repo" "bazzite-stable")
  [ "$out" = "bazzite-stable-44.20260520" ]
  [ "$(<"$STUB_DIR/attempts")" = "3" ]
}

# ── version_of_tag ──────────────────────────────────────────────────────────

@test "version_of_tag strips the branch prefix" {
  local out
  out=$(version_of_tag "unstable-45.20261019.7" "unstable")
  [ "$out" = "45.20261019.7" ]
}

@test "version_of_tag leaves upstream's bare stable version unchanged" {
  local out
  out=$(version_of_tag "44.20261012.1" "stable")
  [ "$out" = "44.20261012.1" ]
}

@test "version_of_tag strips a hyphenated branch once" {
  local out
  out=$(version_of_tag "nvidia-open-44.20261012.1" "nvidia-open")
  [ "$out" = "44.20261012.1" ]
}

# ── find latest versioned tag, branch semantics ─────────────────────────────

@test "find_latest_versioned_tag ignores moving tags and other branches" {
  cat >"$STUB_DIR/skopeo" <<'EOF'
#!/usr/bin/env bash
printf '{"Tags":["unstable-45","unstable-45.20261019.7","unstable-45.20261020","stable-44.20261012.1","latest"]}\n'
exit 0
EOF
  chmod +x "$STUB_DIR/skopeo"

  local out
  out=$(find_latest_versioned_tag "ghcr.io/owner/repo" "unstable")
  [ "$out" = "unstable-45.20261020" ]
}

@test "find_latest_versioned_tag fails when the branch only has moving tags" {
  cat >"$STUB_DIR/skopeo" <<'EOF'
#!/usr/bin/env bash
printf '{"Tags":["unstable-45","unstable"]}\n'
exit 0
EOF
  chmod +x "$STUB_DIR/skopeo"

  run find_latest_versioned_tag "ghcr.io/owner/repo" "unstable"
  [ "$status" -eq 1 ]
}

# ── resolve_upstream_tag ────────────────────────────────────────────────────

@test "resolve_upstream_tag probes the branch-prefixed name and stops there" {
  cat >"$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"/commits/unstable-45.20261019.7"* ]]; then
    echo '{"sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}'
else
    echo '{"message":"Not Found"}'
fi
EOF
  chmod +x "$STUB_DIR/curl"

  local out
  out=$(resolve_upstream_tag "ublue-os/bazzite" "unstable" "45.20261019.7")
  [ "$out" = "unstable-45.20261019.7 45.20261019.7 prefixed" ]
}

@test "resolve_upstream_tag falls back to the bare version name" {
  cat >"$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"/commits/44.20261012.1"* ]]; then
    echo '{"sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}'
else
    echo '{"message":"Not Found"}'
fi
EOF
  chmod +x "$STUB_DIR/curl"

  local out
  out=$(resolve_upstream_tag "ublue-os/bazzite" "stable" "44.20261012.1")
  [ "$out" = "44.20261012.1 44.20261012.1 bare-version" ]
}

@test "resolve_upstream_tag answers 1, not 2, when the walk budget cut the search short" {
  cat >"$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"message":"Not Found"}'
EOF
  chmod +x "$STUB_DIR/curl"

  run resolve_upstream_tag "ublue-os/bazzite" "unstable" "45.20261019.7"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No upstream git tag for version 45.20261019.7 of branch unstable"* ]]
}

@test "the day's first build is published before upstream tags it, in either family" {
  # Shape probed live 2026-10-20: ghcr.io/ublue-os/bazzite:testing is labelled
  # testing-45.20261020.1, /commits/testing-45.20261020.1 answered 404 minutes
  # after that build was pushed, and the bare 45.20261020.1 never exists (a
  # testing build is only ever named with the branch prefix), so the same-day
  # walk has nothing lower than counter .1 to try.
  cat >"$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"message":"Not Found"}'
EOF
  chmod +x "$STUB_DIR/curl"

  run resolve_upstream_tag "ublue-os/bazzite" "testing" "45.20261020.1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"upstream has no tag testing-45.20261020.1"* ]]
  [[ "$output" == *"upstream has no tag 45.20261020.1"* ]]
}

@test "resolve_upstream_tag names the upstream answer for each name it probed" {
  cat >"$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"message":"API rate limit exceeded"}'
EOF
  chmod +x "$STUB_DIR/curl"

  run resolve_upstream_tag "ublue-os/bazzite" "unstable" "45.20261019.7"
  [ "$status" -eq 1 ]
  [[ "$output" == *"rate limit exceeded"* ]]
}

@test "resolve_upstream_tag walks down to the build counter upstream tagged" {
  cat >"$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"/commits/testing-45.20261019.3"* ]]; then
    echo '{"sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}'
else
    echo '{"message":"Not Found"}'
fi
EOF
  chmod +x "$STUB_DIR/curl"

  local out
  out=$(resolve_upstream_tag "ublue-os/bazzite" "testing" "45.20261019.4")
  [ "$out" = "testing-45.20261019.3 45.20261019.3 prefixed" ]
}

@test "resolve_upstream_tag walks a zero-padded build counter without tripping octal" {
  cat >"$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"/commits/testing-45.20261019.7"* ]]; then
    echo '{"sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}'
else
    echo '{"message":"Not Found"}'
fi
EOF
  chmod +x "$STUB_DIR/curl"

  local out
  out=$(resolve_upstream_tag "ublue-os/bazzite" "testing" "45.20261019.08")
  [ "$out" = "testing-45.20261019.7 45.20261019.7 prefixed" ]
}

@test "resolve_upstream_tag stops walking at the build-counter budget" {
  cat >"$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"/commits/testing-45.20261019.1"* ]]; then
    echo '{"sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}'
else
    echo '{"message":"Not Found"}'
fi
EOF
  chmod +x "$STUB_DIR/curl"

  run resolve_upstream_tag "ublue-os/bazzite" "testing" "45.20261019.9"
  [ "$status" -eq 1 ]
}

# ── check build needed, branch identity ─────────────────────────────────────

@test "check_build_needed compares the unstable branch against its own primary tag" {
  cat >"$STUB_DIR/skopeo" <<'EOF'
#!/usr/bin/env bash
if [[ "${2:-}" == "docker://ghcr.io/owner/repo:unstable" ]]; then
    printf '{"Labels":{"org.opencontainers.image.version":"45.20261017.2"},"Digest":"sha256:abc"}\n'
    exit 0
fi
exit 1
EOF
  chmod +x "$STUB_DIR/skopeo"

  run check_build_needed "ghcr.io/owner/repo" "unstable" "45.20261019.7" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *'REASON="Upstream changed (45.20261017.2 → 45.20261019.7)"'* ]]
}

@test "check_build_needed skips a branch already at the upstream version" {
  cat >"$STUB_DIR/skopeo" <<'EOF'
#!/usr/bin/env bash
if [[ "${2:-}" == "docker://ghcr.io/owner/repo:unstable" ]]; then
    printf '{"Labels":{"org.opencontainers.image.version":"45.20261019.7"},"Digest":"sha256:abc"}\n'
    exit 0
fi
exit 1
EOF
  chmod +x "$STUB_DIR/skopeo"

  run check_build_needed "ghcr.io/owner/repo" "unstable" "45.20261019.7" "false"
  [ "$status" -eq 1 ]
  [[ "$output" == *'REASON="Upstream unchanged (parent_version: 45.20261019.7)"'* ]]
}

# ── upstream identity of an image we published ──────────────────────────────

@test "upstream_version_of_our_image names the version its upstream tag label holds" {
  cat >"$STUB_DIR/skopeo" <<'EOF'
#!/usr/bin/env bash
if [[ "${2:-}" == "docker://ghcr.io/owner/repo:unstable" ]]; then
    printf '{"Labels":{"org.opencontainers.image.upstream-version":"unstable-45.20261019.7","org.opencontainers.image.version":"45.20261017.2"}}\n'
    exit 0
fi
exit 1
EOF
  chmod +x "$STUB_DIR/skopeo"

  run upstream_version_of_our_image "ghcr.io/owner/repo:unstable" "unstable"
  [ "$status" -eq 0 ]
  [ "$output" = "45.20261019.7" ]
}

@test "upstream_version_of_our_image falls back to the plain version label when its upstream tag label is absent" {
  cat >"$STUB_DIR/skopeo" <<'EOF'
#!/usr/bin/env bash
if [[ "${2:-}" == "docker://ghcr.io/owner/repo:unstable" ]]; then
    printf '{"Labels":{"org.opencontainers.image.version":"45.20261019.7"}}\n'
    exit 0
fi
exit 1
EOF
  chmod +x "$STUB_DIR/skopeo"

  run upstream_version_of_our_image "ghcr.io/owner/repo:unstable" "unstable"
  [ "$status" -eq 0 ]
  [ "$output" = "45.20261019.7" ]
}

@test "upstream_version_of_our_image leaves upstream's bare stable tag as its version" {
  cat >"$STUB_DIR/skopeo" <<'EOF'
#!/usr/bin/env bash
if [[ "${2:-}" == "docker://ghcr.io/owner/repo:stable" ]]; then
    printf '{"Labels":{"org.opencontainers.image.upstream-version":"44.20261012.1"}}\n'
    exit 0
fi
exit 1
EOF
  chmod +x "$STUB_DIR/skopeo"

  run upstream_version_of_our_image "ghcr.io/owner/repo:stable" "stable"
  [ "$status" -eq 0 ]
  [ "$output" = "44.20261012.1" ]
}

@test "upstream_version_of_our_image fails when the image carries neither label" {
  cat >"$STUB_DIR/skopeo" <<'EOF'
#!/usr/bin/env bash
if [[ "${2:-}" == "docker://ghcr.io/owner/repo:unstable" ]]; then
    printf '{"Labels":{"org.opencontainers.image.title":"unstable"}}\n'
    exit 0
fi
exit 1
EOF
  chmod +x "$STUB_DIR/skopeo"

  run upstream_version_of_our_image "ghcr.io/owner/repo:unstable" "unstable"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}

# ── the CI driver, end to end ───────────────────────────────────────────────
# check-variants.sh is a subprocess, so these tests stub the binaries it shells
# out to (not the lib functions) and drive it and resolve_variant over the same
# canned answers: one identity rule, whichever driver reads it.

ci_fixture() {
  local dir
  dir="$(mktemp -d)"
  cat >"$dir/variants.json" <<'EOF'
{"variants": [{"name": "stable", "base_image": "ghcr.io/ublue-os/bazzite:stable"}]}
EOF
  cat >"$STUB_DIR/skopeo" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" != "inspect" ]] && exit 0
ref="${2:-}"; ref="${ref#docker://}"
if [[ "$ref" == "ghcr.io/ublue-os/bazzite:stable" ]]; then
    printf '{"Digest":"sha256:aa","Labels":{"org.opencontainers.image.version":"44.20261012.1"}}\n'
    exit 0
fi
ref="${ref##*:}"
case " ${FAKE_REGISTRY_TAGS:-} " in
  *" $ref "*) exit 0 ;;
esac
exit 1
EOF
  cat >"$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do [[ "$a" == */commits/* ]] && url="${a##*/commits/}"; done
case "${url:-}" in
  44.20261012.1) echo '{"sha":"ffffffffffffffffffffffffffffffffffffffff"}' ;;
  *) echo '{"message":"Not Found"}' ;;
esac
EOF
  chmod +x "$STUB_DIR/skopeo" "$STUB_DIR/curl"
  echo "$dir"
}

ci_run() {
  local dir="$1" force="${2:-false}"
  REGISTRY=ghcr.io/test REPO=repo ARTIFACTS_DIR="$dir/artifacts" FORCE_BUILD="$force" \
    VARIANTS_CONFIG="$dir/variants.json" DATE="2026-01-01T00:00:00Z" IMAGE_DESC="d" \
    bash scripts/check-variants.sh
}

@test "the check job and the resolver name the same identity for one variant" {
  local dir driver resolver field
  dir="$(ci_fixture)"
  ci_run "$dir" >/dev/null 2>&1

  driver="$(jq -c '.[0]' "$dir/artifacts/variants_results.json")"
  resolver="$(resolve_variant "stable" "$dir/variants.json" "repo" "false" "ghcr.io/test")"

  [ "$(jq -r '.needs_build' <<<"$driver")" = "true" ]
  for field in variant base_image build_script suffix parent_version canonical_tag upstream_tag tags collision_detected; do
    [[ "$(jq -r ".$field" <<<"$driver")" == "$(jq -r ".$field" <<<"$resolver")" ]]
  done
}

@test "a base image labelled latest is not a release version, in either driver" {
  local dir
  dir="$(ci_fixture)"
  cat >"$STUB_DIR/skopeo" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" != "inspect" ]] && exit 0
ref="${2:-}"; ref="${ref#docker://}"
if [[ "$ref" == "ghcr.io/ublue-os/bazzite:stable" ]]; then
    printf '{"Digest":"sha256:aa","Labels":{"org.opencontainers.image.version":"latest"}}\n'
    exit 0
fi
exit 1
EOF
  chmod +x "$STUB_DIR/skopeo"
  # upstream really does keep a moving tag named `latest`, so a label that reads
  # `latest` would resolve to a tag if anything trusted the label as a version.
  cat >"$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do [[ "$a" == */commits/* ]] && url="${a##*/commits/}"; done
case "$url" in
  stable-latest) echo '{"sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}' ;;
  *) echo '{"message":"Not Found"}' ;;
esac
EOF
  chmod +x "$STUB_DIR/curl"

  run ci_run "$dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *'::error::'* ]]
  [ "$(jq -c '.[0] // "no record"' "$dir/artifacts/variants_results.json")" = '"no record"' ]

  run resolve_variant "stable" "$dir/variants.json" "repo" "false" "ghcr.io/test"
  [ "$status" -eq 1 ]
}

@test "an exhausted bump walk skips that variant, the check still succeeds" {
  local dir out
  dir="$(ci_fixture)"
  export FAKE_REGISTRY_TAGS="stable-44.20261012.1 stable-44.20261012.2 stable-44.20261012.3 stable-44.20261012.4 stable-44.20261012.5 stable-44.20261012.6"

  run ci_run "$dir" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exist"* ]]
  [ "$(jq 'length' "$dir/artifacts/variants_results.json")" = "0" ]
}

@test "the check job survives upstream publishing a build before tagging it" {
  # Both variants are the ones that were failing in the check job on 2026-10-20:
  # testing is labelled testing-45.20261020.1 and untagged when its day's first
  # build is pushed, stable is labelled 44.20261012.1 and tagged bare.
  local dir
  dir="$(mktemp -d)"
  cat >"$dir/variants.json" <<'EOF'
{"variants": [
  {"name": "testing", "base_image": "ghcr.io/ublue-os/bazzite:testing"},
  {"name": "stable", "base_image": "ghcr.io/ublue-os/bazzite:stable"}
]}
EOF
  cat >"$STUB_DIR/skopeo" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" != "inspect" ]] && exit 0
ref="${2:-}"; ref="${ref#docker://}"
case "$ref" in
  ghcr.io/ublue-os/bazzite:testing)
    printf '{"Digest":"sha256:bb","Labels":{"org.opencontainers.image.version":"testing-45.20261020.1"}}\n'
    exit 0 ;;
  ghcr.io/ublue-os/bazzite:stable)
    printf '{"Digest":"sha256:aa","Labels":{"org.opencontainers.image.version":"44.20261012.1"}}\n'
    exit 0 ;;
esac
exit 1
EOF
  cat >"$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do [[ "$a" == */commits/* ]] && url="${a##*/commits/}"; done
case "${url:-}" in
  44.20261012.1) echo '{"sha":"ffffffffffffffffffffffffffffffffffffffff"}' ;;
  *) echo '{"message":"Not Found"}' ;;
esac
EOF
  chmod +x "$STUB_DIR/skopeo" "$STUB_DIR/curl"

  run ci_run "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [ "$(jq 'length' "$dir/artifacts/variants_results.json")" = "1" ]
  [ "$(jq -r '.[0].variant' "$dir/artifacts/variants_results.json")" = "stable" ]
  [ "$(jq -r '.[0].upstream_tag' "$dir/artifacts/variants_results.json")" = "44.20261012.1" ]

  run resolve_variant "testing" "$dir/variants.json" "repo" "false" "ghcr.io/test"
  [ "$status" -eq 2 ]
}

