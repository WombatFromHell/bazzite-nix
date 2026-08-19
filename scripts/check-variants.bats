#!/usr/bin/env bats
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
  out=$(generate_tags "stable" "44.20260520" "false" "" "")
  [ "$out" = "stable-44.20260520,stable-44,stable" ]
}

@test "generate_tags appends latest last" {
  local out
  out=$(generate_tags "testing" "44.20260520" "true" "" "")
  [ "$out" = "testing-44.20260520,testing-44,testing,latest" ]
}

@test "generate_tags expands tags_json placeholders" {
  local tags_json='{"branch":"custom","versioned":["{branch}-{canonical}","{branch}-{major}-{canonical}"]}'
  local out
  out=$(generate_tags "unstable" "44.20260520.1" "false" "$tags_json" "")
  [ "$out" = "custom-44.20260520.1,custom-44-44.20260520.1" ]
}

@test "generate_tags defaults tags branch to base image tag" {
  local tags_json='{"versioned":["{branch}-{canonical}"]}'
  local out
  out=$(generate_tags "unstable" "44.20260520.1" "false" "$tags_json" "")
  [ "$out" = "unstable-44.20260520.1" ]
}

@test "generate_tags skips sha256 placeholders when digest is empty" {
  local tags_json='{"versioned":["{branch}-{canonical}","{branch}-{sha256}"]}'
  local out
  out=$(generate_tags "unstable" "44.20260520.1" "false" "$tags_json" "")
  [ "$out" = "unstable-44.20260520.1" ]
}

@test "generate_tags resolves sha256 placeholder when digest is given" {
  local tags_json='{"versioned":["{branch}-{sha256}"]}'
  local out
  out=$(generate_tags "unstable" "44.20260520.1" "false" "$tags_json" "abc123")
  [ "$out" = "unstable-abc123" ]
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
