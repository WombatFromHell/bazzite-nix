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

@test "resolve_upstream_tag fails when upstream names neither form" {
  cat >"$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"message":"Not Found"}'
EOF
  chmod +x "$STUB_DIR/curl"

  run resolve_upstream_tag "ublue-os/bazzite" "unstable" "45.20261019.7"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No upstream git tag for version 45.20261019.7 of branch unstable"* ]]
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
