#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# just-helpers.bats — Tests for scripts/just-helpers.sh
#
# Run with: bats scripts/just-helpers.bats
# Or:       bats --pretty scripts/just-helpers.bats

setup() {
  # Source the helper script before each test
  load 'just-helpers'
}

# ── clean_artifacts ─────────────────────────────────────────────────────────

@test "clean_artifacts removes *_build* directories" {
  local test_dir
  test_dir="$(mktemp -d)"
  cd "$test_dir"
  mkdir -p test_build another_build_dir
  touch test_build/file.txt another_build_dir/file.txt
  clean_artifacts
  [ ! -d "test_build" ]
  [ ! -d "another_build_dir" ]
}

@test "clean_artifacts removes manifest, artifact directory, and output dir" {
  cd "$(mktemp -d)"
  touch previous.manifest.json
  mkdir -p .artifacts/testing output/
  touch .artifacts/testing/changelog.md
  clean_artifacts
  [ ! -f "previous.manifest.json" ]
  [ ! -d ".artifacts" ]
  [ ! -d "output" ]
}

# ── clean_oci_layout ────────────────────────────────────────────────────────

@test "clean_oci_layout removes the layout base dir (per-variant layouts underneath)" {
  local test_dir
  test_dir="$(mktemp -d)"
  mkdir -p "$test_dir/stable/chunked"

  clean_oci_layout "$test_dir"
  [ ! -d "$test_dir" ]
}

@test "clean_oci_layout is a no-op when the base dir is absent" {
  local output
  output=$(clean_oci_layout "$(mktemp -d)/nonexistent" 2>&1)
  [ -z "$output" ]
}

# ── clean_vm_cache ──────────────────────────────────────────────────────────

@test "clean_vm_cache removes only the cached disk images" {
  local test_dir
  test_dir="$(mktemp -d)"
  touch "$test_dir/disk.qcow2" "$test_dir/disk.raw" "$test_dir/install.iso"
  touch "$test_dir/something-else"

  clean_vm_cache "$test_dir"
  [ ! -f "$test_dir/disk.qcow2" ]
  [ ! -f "$test_dir/disk.raw" ]
  [ ! -f "$test_dir/install.iso" ]
  [ -f "$test_dir/something-else" ]
  [ -d "$test_dir" ]
}

@test "clean_vm_cache reports when cache does not exist" {
  local test_dir
  test_dir="$(mktemp -d)/nonexistent"

  local output
  output=$(clean_vm_cache "$test_dir" 2>&1)
  [[ "$output" == *"VM cache does not exist"* ]]
}

# ── remove_images_and_prune ─────────────────────────────────────────────────

@test "remove_images_and_prune removes images by hash then prunes" {
  local log
  log="$(mktemp)"
  podman() {
    printf 'podman %s\n' "$*" >>"$log"
    if [[ "$1" == "images" ]]; then
      # podman reports bare repo names, no localhost/ prefix
      printf 'raw-img|sha256:deadbeef\nchunked-img|sha256:cafebabe\n'
    fi
  }
  export -f podman

  remove_images_and_prune podman localhost/raw-img localhost/chunked-img
  grep -q 'podman rmi --force sha256:deadbeef' "$log"
  grep -q 'podman rmi --force sha256:cafebabe' "$log"
  grep -q 'podman image prune --force' "$log"
}

# ── resolve_variant ─────────────────────────────────────────────────────────

setup_variant_json() {
  local test_dir
  test_dir="$(mktemp -d)"
  cat >"$test_dir/variants.json" <<'EOF'
{
  "variants": [
    {
      "name": "testing",
      "base_image": "ghcr.io/ublue-os/bazzite:stable",
      "build_script": "build.sh"
    },
    {
      "name": "disabled-variant",
      "base_image": "ghcr.io/ublue-os/bazzite:stable",
      "disabled": true
    }
  ]
}
EOF
  echo "$test_dir"
}

@test "resolve_variant rejects unknown variant" {
  local test_dir
  test_dir="$(setup_variant_json)"

  local output
  output=$(resolve_variant "nonexistent" "$test_dir/variants.json" "bazzite-nix" 2>&1) && return 1
  [[ "$output" == *"ERROR: Unknown or disabled variant"* ]]
}

@test "resolve_variant rejects disabled variant" {
  local test_dir
  test_dir="$(setup_variant_json)"

  local output
  output=$(resolve_variant "disabled-variant" "$test_dir/variants.json" "bazzite-nix" 2>&1) && return 1
  [[ "$output" == *"ERROR: Unknown or disabled variant"* ]]
}

# Stub the upstream tag probe: every ref asked about resolves to a real tag.
stub_upstream_probe() {
  curl() {
    printf '%s\n' '{"sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}'
  }
}

@test "resolve_variant returns one record" {
  local test_dir
  test_dir="$(setup_variant_json)"

  stub_upstream_probe

  # Mock skopeo to return a version label (upstream spells it {major}.{date}.{build})
  skopeo() {
    echo '{"Labels":{"org.opencontainers.image.version":"44.20261012.1"}}'
  }
  export -f skopeo

  local output
  output=$(resolve_variant "testing" "$test_dir/variants.json" "bazzite-nix")
  jq -e . >/dev/null <<<"$output"
  [[ "$(jq -r .target_image <<<"$output")" == "localhost/bazzite-nix" ]]
  [[ "$(jq -r .variant <<<"$output")" == "testing" ]]
  [[ "$(jq -r .base_image <<<"$output")" == "ghcr.io/ublue-os/bazzite:stable" ]]
  [[ "$(jq -r .parent_version <<<"$output")" == "44.20261012.1" ]]
  [[ "$(jq -r .collision_detected <<<"$output")" == "false" ]]
}

@test "resolve_variant bumps canonical on version collision (force_build)" {
  local test_dir
  test_dir="$(setup_variant_json)"

  stub_upstream_probe

  # Mock skopeo: the bumped tag is free, everything else exists
  skopeo() {
    case "$*" in
    *"testing-44.20261012.2"*) return 1 ;;
    *) echo '{"Labels":{"org.opencontainers.image.version":"44.20261012.1"}}' ;;
    esac
  }
  export -f skopeo

  local output
  output=$(resolve_variant "testing" "$test_dir/variants.json" "bazzite-nix" "1" "ghcr.io/test-owner")
  jq -e . >/dev/null <<<"$output"
  [[ "$(jq -r .canonical_tag <<<"$output")" == "44.20261012.2" ]]
  [[ "$(jq -r .collision_detected <<<"$output")" == "true" ]]
  # The collision bump moves the tag name, not the upstream version the labels carry.
  [[ "$(jq -r .parent_version <<<"$output")" == "44.20261012.1" ]]
}

@test "resolve_variant drops {sha256} tags (digest is resolved at push time, not from upstream)" {
  local test_dir
  test_dir="$(mktemp -d)"
  cat >"$test_dir/variants.json" <<'EOF'
{
  "variants": [
    {
      "name": "stable",
      "base_image": "ghcr.io/ublue-os/bazzite:stable",
      "tags": {
        "versioned": ["{canonical}", "{branch}", "{sha256}"]
      }
    }
  ]
}
EOF

  stub_upstream_probe

  # Mock skopeo: upstream has a digest — resolve_variant must NOT use it for tags
  skopeo() {
    echo '{"Labels":{"org.opencontainers.image.version":"44.20261012.1"},"Digest":"sha256:fbd9a04deadbeef"}'
  }
  export -f skopeo

  local output
  output=$(resolve_variant "stable" "$test_dir/variants.json" "bazzite-nix")
  jq -e . >/dev/null <<<"$output"
  [[ "$(jq -r .tags <<<"$output")" == "44.20261012.1,stable" ]]
  run ! [[ "$output" == *"fbd9a04deadbeef"* ]]
}

@test "resolve_variant handles image:tag spec" {
  local test_dir
  test_dir="$(setup_variant_json)"

  # Mock skopeo
  skopeo() {
    echo '{"Labels":{"org.opencontainers.image.version":"2.0.0"}}'
  }
  export -f skopeo

  local output
  output=$(resolve_variant "ghcr.io/ublue-os/bazzite:testing" "$test_dir/variants.json" "bazzite-nix")
  jq -e . >/dev/null <<<"$output"
  [[ "$(jq -r .base_image <<<"$output")" == "ghcr.io/ublue-os/bazzite:testing" ]]
  [[ "$(jq -r .tag <<<"$output")" == "testing" ]]
  # A spec has no upstream git probe: its parent version is the base image label.
  [[ "$(jq -r .parent_version <<<"$output")" == "2.0.0" ]]
  # No registry collision check either, but the field must still be present:
  # every reader of the record reads it unguarded.
  [[ "$(jq -r .collision_detected <<<"$output")" == "false" ]]
  [[ "$(jq -r .upstream_tag <<<"$output")" == "" ]]
}

@test "resolve_variant stdout is one record line, so no caller evals it" {
  local test_dir
  test_dir="$(setup_variant_json)"

  stub_upstream_probe

  skopeo() {
    echo '{"Labels":{"org.opencontainers.image.version":"44.20261012.1"}}'
  }
  export -f skopeo

  local output
  output=$(resolve_variant "testing" "$test_dir/variants.json" "bazzite-nix")
  [[ "$(wc -l <<<"$output")" -eq 1 ]]
  jq -e . >/dev/null <<<"$output"
}

# ── build_bib ───────────────────────────────────────────────────────────────────────

@test "build_bib skips when disk file exists (qcow2)" {
  local test_dir
  test_dir="$(mktemp -d)"
  touch "$test_dir/disk.qcow2"

  sudo() { "$@"; }
  export -f sudo

  local output
  output=$(build_bib "/tmp/oci-layout" "latest" "qcow2" "config.toml" "$test_dir" "quay.io/centos-bootc/bootc-image-builder:latest" 2>&1)
  [[ "$output" == *"Disk image already exists"* ]]
}

@test "build_bib skips when disk file exists (raw)" {
  local test_dir
  test_dir="$(mktemp -d)"
  touch "$test_dir/disk.raw"

  sudo() { "$@"; }
  export -f sudo

  local output
  output=$(build_bib "/tmp/oci-layout" "latest" "raw" "config.toml" "$test_dir" "quay.io/centos-bootc/bootc-image-builder:latest" 2>&1)
  [[ "$output" == *"Disk image already exists"* ]]
}

# ── variant_chunked_layout / export_and_build_bib ───────────────────────────

@test "variant_chunked_layout finds the pipeline layout, empty when absent" {
  local base
  base="$(mktemp -d)"
  mkdir -p "$base/testing/chunked"
  touch "$base/testing/chunked/index.json"

  [[ "$(OCI_OUTPUT_DIR="$base" variant_chunked_layout "testing")" == "$base/testing/chunked" ]]
  [ -z "$(OCI_OUTPUT_DIR="$base" variant_chunked_layout "missing")" ]
}

@test "export_and_build_bib streams image into rootful storage and feeds build_bib" {
  local out log
  out="$(mktemp -d)"
  log="$out/calls"
  sudo() {
    echo "sudo $*" >>"$log"
    "$@"
  }
  export -f sudo
  podman() { echo "podman $*" >>"$log"; }
  export -f podman
  build_bib() { echo "build_bib $*" >>"$log"; }
  export -f build_bib

  export_and_build_bib "localhost/raw-img" "testing" "qcow2" "image.toml" "$out" "bib:latest"
  grep -q '^podman save localhost/raw-img$' "$log"
  grep -q '^sudo podman tag localhost/raw-img localhost/chunked-img:testing$' "$log"
  grep -q "^build_bib localhost/chunked-img:testing testing qcow2 image.toml $out bib:latest$" "$log"
}

# ── check_variants ──────────────────────────────────────────────────────────

@test "check_variants requires repo_organization parameter" {
  run check_variants 0 "" "bazzite-nix" ".github/variants.json"
  [ "$status" -ne 0 ]
}

# ── aggregate_variants ──────────────────────────────────────────────────────

@test "aggregate_variants filters needs_build and writes GITHUB_OUTPUT" {
  local test_dir gh_out
  test_dir="$(mktemp -d)"
  gh_out="$test_dir/gh_output"
  touch "$gh_out"

  export ARTIFACTS_DIR="$test_dir/artifacts"
  mkdir -p "$ARTIFACTS_DIR"
  cat >"$ARTIFACTS_DIR/variants_results.json" <<'EOF'
[
  {"variant":"stable","needs_build":false},
  {"variant":"testing","needs_build":true,"canonical_tag":"1.2.3"}
]
EOF

  GITHUB_OUTPUT="$gh_out" aggregate_variants "ghcr.io/owner" "bazzite-nix" >/dev/null

  grep -q '^variants_to_build=\[{"variant":"testing","canonical_tag":"1.2.3"}\]$' "$gh_out"
  grep -q '^any_builds_needed=true$' "$gh_out"
}

@test "aggregate_variants reports no builds for empty result" {
  local test_dir gh_out
  test_dir="$(mktemp -d)"
  gh_out="$test_dir/gh_output"
  touch "$gh_out"

  export ARTIFACTS_DIR="$test_dir/artifacts"
  mkdir -p "$ARTIFACTS_DIR"
  echo '[]' >"$ARTIFACTS_DIR/variants_results.json"

  GITHUB_OUTPUT="$gh_out" aggregate_variants "ghcr.io/owner" "bazzite-nix" "$test_dir/summary" >/dev/null

  grep -q '^variants_to_build=\[\]$' "$gh_out"
  grep -q '^any_builds_needed=false$' "$gh_out"
  [ -f "$test_dir/summary" ]
}

# ── variant_record / release_variant ────────────────────────────────────────

@test "variant_record rejects unknown variant" {
  local test_dir
  test_dir="$(setup_variant_json)"

  GH_TOKEN=x run variant_record "nope" "$test_dir/variants.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found in"* ]]
  [[ "$output" == *"Available:"* ]]
}

@test "release_variant rejects disabled variant" {
  local test_dir record
  test_dir="$(setup_variant_json)"
  record=$(variant_record "disabled-variant" "$test_dir/variants.json")

  GH_TOKEN=x run release_variant "$record" '{"allow_disabled": false}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"is disabled in variants.json"* ]]
}

# ── print_build_summary / echo_build_assignments ────────────────────────────

@test "print_build_summary and echo_build_assignments emit the build refs" {
  local out record
  record='{"variant":"stable","canonical_tag":"1.0.0","tags":"stable","kernel_version":"6.6.0","manifest_packages":"42","source_ref":"containers-storage:localhost/chunked-img:stable","full_build_digest":"sha256:abc","build_digest":"abc"}'
  out=$(print_build_summary "Test complete" "$record" 2>&1)
  [[ "$out" == *"=== Test complete ==="* ]]
  [[ "$out" == *"Variant      : stable"* ]]
  [[ "$out" == *"Short digest : abc"* ]]

  out=$(echo_build_assignments "$record")
  [[ "$out" == *"KERNEL_VERSION=6.6.0"* ]]
  [[ "$out" == *"BUILD_DIGEST=abc"* ]]
}

# ── build_variant_pipeline (the one build sequence) ───────────────────────

# Mock the build-helpers functions so the sequence's branch logic can be
# tested without real containers. Records relabel/rechunk calls to a calls file.
build_core_mocks() {
  local calls="$1"
  extract_image_info() {
    echo "KERNEL_VERSION=6.6.0"
    echo "MANIFEST_PACKAGES=42"
  }
  assemble_labels() { :; }
  relabel_image() { echo "REL:$3" >>"$calls"; }
  rechunk_image() { echo "RECHUNK:$1:$2" >>"$calls"; }
  extract_final_ref() {
    echo "SOURCE_REF=containers-storage:localhost/$2:$1"
    echo "FULL_BUILD_DIGEST=sha256:abc"
    echo "BUILD_DIGEST=abc"
  }
}

build_core_record='{"variant":"stable","version_label":"44.1","repo_owner":"owner","repo_name":"repo"}'

@test "build_variant_pipeline relabels raw-img directly when rechunk disabled" {
  local calls out
  calls="$(mktemp)"
  export ARTIFACTS_DIR="$(mktemp -d)"
  build_core_mocks "$calls"
  out=$(build_variant_pipeline "$build_core_record" '{"build":"none"}')
  [[ "$(jq -r .kernel_version <<<"$out")" == "6.6.0" ]]
  [[ "$(jq -r .source_ref <<<"$out")" == "containers-storage:localhost/raw-img:stable" ]]
  grep -q "REL:raw-img" "$calls"
  run ! grep -q "RECHUNK:" "$calls"
}

@test "build_variant_pipeline rechunks with labels via chunkah when rechunk enabled (force)" {
  local calls out
  calls="$(mktemp)"
  export ARTIFACTS_DIR="$(mktemp -d)"
  build_core_mocks "$calls"
  out=$(build_variant_pipeline "$build_core_record" '{"rechunk":1,"force_rebuild":1,"build":"none"}')
  [[ "$(jq -r .source_ref <<<"$out")" == "containers-storage:localhost/chunked-img:stable" ]]
  grep -q "RECHUNK:stable:$ARTIFACTS_DIR/stable/labels.txt" "$calls"
  run ! grep -q "REL:" "$calls"
}

@test "build_variant_pipeline skips relabel & rechunk when chunked image already exists" {
  local calls out
  calls="$(mktemp)"
  export ARTIFACTS_DIR="$(mktemp -d)"
  build_core_mocks "$calls"
  sudo() { return 0; }
  buildah() { return 0; } # pretend localhost/chunked-img:stable exists
  out=$(build_variant_pipeline "$build_core_record" '{"rechunk":1,"build":"none"}')
  [[ "$(jq -r .source_ref <<<"$out")" == "containers-storage:localhost/chunked-img:stable" ]]
  run ! grep -q "RECHUNK:" "$calls"
  run ! grep -q "REL:" "$calls"
}

@test "build_variant_pipeline fails naming the missing record field" {
  local err
  err="$(mktemp)"
  build_variant_pipeline '{"variant":"stable","repo_owner":"owner","repo_name":"repo"}' 2>"$err" || true
  grep -q "missing required field" "$err"
}

# build_variant_ci captures this stdout and hands it to GitHub's $GITHUB_OUTPUT,
# which reads one key=value line; a chatty build callee must not reach stdout.
@test "build_variant_pipeline stdout stays one record line when the build is chatty" {
  local calls out
  calls="$(mktemp)"
  export ARTIFACTS_DIR="$(mktemp -d)"
  build_core_mocks "$calls"
  build_image() { echo "STEP 1/2: FROM base"; }
  out=$(build_variant_pipeline "$build_core_record" '{"build":"always"}')
  [[ "$(wc -l <<<"$out")" -eq 1 ]]
  jq -e . >/dev/null <<<"$out"
}

@test "build_variant_pipeline returns the caller's record fields with the build fields" {
  local calls out
  calls="$(mktemp)"
  export ARTIFACTS_DIR="$(mktemp -d)"
  build_core_mocks "$calls"
  out=$(build_variant_pipeline "$build_core_record" '{"build":"none"}')
  [[ "$(jq -r .variant <<<"$out")" == "stable" ]]
  [[ "$(jq -r .version_label <<<"$out")" == "44.1" ]]
  [[ "$(jq -r .repo_name <<<"$out")" == "repo" ]]
}

# ── run_variant (the shared engine behind run_rechunk / run_relabel / run_pipeline) ──
# run_variant's job is the entry checks plus the options record, so the mocks
# record what build_variant_pipeline was handed and skip real containers.
run_variant_mocks() {
  local calls="$1"
  resolve_variant() {
    echo '{"variant":"stable"}'
  }
  buildah() { return 0; } # pretend every working image exists
  preview_tags() { :; }
  resolved_variant_record_json() { echo '{}'; }
  build_variant_pipeline() {
    echo "OPTIONS=$2" >>"$calls"
    echo '{"source_ref":"containers-storage:localhost/raw-img:stable"}'
  }
  print_build_summary() { :; }
  echo_build_assignments() { :; }
}

@test "run_variant hands each mode its own options record" {
  local calls
  calls="$(mktemp)"
  export ARTIFACTS_DIR="$(mktemp -d)"
  run_variant_mocks "$calls"
  run_variant rechunk stable '{"image_name":"repo","repo_organization":"owner"}' >/dev/null
  grep -q 'OPTIONS={"rechunk":1,"force_rebuild":1,"build":"none"}' "$calls"
  run_variant relabel stable '{"image_name":"repo","repo_organization":"owner","image_name_ref":"chunked-img"}' >/dev/null
  grep -q 'OPTIONS={"build":"none","rechunk":0,"image_name_ref":"chunked-img","extract_ref":"localhost/chunked-img:stable"}' "$calls"
  run_variant pipeline stable '{"image_name":"repo","repo_organization":"owner","rechunk":"1"}' >/dev/null
  grep -q 'OPTIONS={"rechunk":"1","force_rebuild":"1","build":"skip"}' "$calls"
}

@test "run_variant rejects an unknown mode and a missing working image" {
  local err
  err="$(mktemp)"
  run_variant_mocks "$(mktemp)"
  run_variant destroy stable '{"image_name":"repo","repo_organization":"owner"}' 2>"$err" || true
  grep -q 'mode must be rechunk, relabel, or pipeline' "$err"
  buildah() { return 1; } # no working image exists for this variant
  run_variant relabel stable '{"image_name":"repo","repo_organization":"owner"}' 2>"$err" || true
  grep -q 'neither localhost/chunked-img:stable nor localhost/raw-img:stable exists' "$err"
}

@test "run_fields builds the record the variant entry points read" {
  local fields
  fields=$(run_fields image_name=repo image_desc='Customized Bazzite image' repo_organization=owner)
  [[ "$(jq -r .image_desc <<<"$fields")" == "Customized Bazzite image" ]]
  [[ "$(jq -r .repo_organization <<<"$fields")" == "owner" ]]
  [[ "$(jq -r .image_desc <<<"$(run_fields image_desc=a=b)")" == "a=b" ]]
  [[ "$(run_fields)" == "{}" ]]
}

# ── pushed_variants ───────────────────────────────────────────────

@test "pushed_variants lists enabled variants that have a versioned tag" {
  local test_dir out
  test_dir="$(setup_variant_json)"
  find_latest_versioned_tag() { return 0; }
  export -f find_latest_versioned_tag
  out=$(pushed_variants "$test_dir/variants.json")
  [[ "$out" == "testing" ]]
}

@test "pushed_variants is empty when no variant has a versioned tag" {
  local test_dir out
  test_dir="$(setup_variant_json)"
  find_latest_versioned_tag() { return 1; }
  export -f find_latest_versioned_tag
  out=$(pushed_variants "$test_dir/variants.json")
  [[ -z "$out" ]]
}

# ── resolve_release_variants ────────────────────────────────────────────────

@test "resolve_release_variants returns every pushed variant when blank" {
  local test_dir out
  test_dir="$(setup_variant_json)"
  find_latest_versioned_tag() { [[ "$2" == "testing" ]]; }
  export -f find_latest_versioned_tag
  out=$(resolve_release_variants "" "$test_dir/variants.json")
  [[ "$out" == "testing" ]]
}

@test "resolve_release_variants drops variants the registry has not seen" {
  local test_dir out
  test_dir="$(setup_variant_json)"
  find_latest_versioned_tag() { [[ "$2" == "testing" ]]; }
  export -f find_latest_versioned_tag
  out=$(resolve_release_variants "testing,missing" "$test_dir/variants.json")
  [[ "$out" == "testing" ]]
}

@test "resolve_release_variants warns about variants never pushed" {
  local test_dir out err
  test_dir="$(setup_variant_json)"
  find_latest_versioned_tag() { return 1; }
  export -f find_latest_versioned_tag
  err="$test_dir/err"
  out=$(resolve_release_variants "testing" "$test_dir/variants.json" 2>"$err")
  [[ -z "$out" ]]
  grep -q "never pushed to the registry" "$err"
}

@test "release_matrix_json prints an empty selection as []" {
  local test_dir out
  test_dir="$(setup_variant_json)"
  find_latest_versioned_tag() { return 1; }
  export -f find_latest_versioned_tag
  out=$(release_matrix_json "" "$test_dir/variants.json")
  [[ "$out" == "[]" ]]
}

@test "release_matrix_json prints pushed variants as a JSON array" {
  local test_dir out
  test_dir="$(setup_variant_json)"
  find_latest_versioned_tag() { [[ "$2" == "testing" ]]; }
  export -f find_latest_versioned_tag
  out=$(release_matrix_json "" "$test_dir/variants.json")
  [[ "$out" == '["testing"]' ]]
}

# ── release_variant (missing-tag gate & dry run) ────────────────────────────

# Mock changelog.py: emit a canned TITLE/TAG and touch the notes file.
release_variant_mocks() {
  local fake_bin="$1"
  cat >"$fake_bin/python3" <<'EOF'
#!/usr/bin/env bash
cat > "$3" <<'OUT'
TITLE="Testing (F44)"
TAG="testing-44.1"
OUT
touch "$4"
EOF
  chmod +x "$fake_bin/python3"
}

@test "release_variant skips when version tag already has a release" {
  local test_dir fake_bin
  test_dir="$(mktemp -d)"
  fake_bin="$test_dir/bin"
  mkdir -p "$fake_bin"
  release_variant_mocks "$fake_bin"
  cat >"$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "release" && "$2" == "view" ]] && exit 0
exit 1
EOF
  chmod +x "$fake_bin/gh"

  cd "$test_dir"
  local out
  out=$(PATH="$fake_bin:$PATH" GITHUB_REPOSITORY="owner/repo" release_variant '{"variant": "testing", "disabled": false}' "$(jq -cn --arg variants_config "$BATS_TEST_DIRNAME/../.github/variants.json" '{variants_config: $variants_config}')" 2>&1) || true
  [[ "$out" == *"already exists"* ]]
}

@test "release_variant dry run prints WOULD CREATE for a missing release" {
  local test_dir fake_bin
  test_dir="$(mktemp -d)"
  fake_bin="$test_dir/bin"
  mkdir -p "$fake_bin"
  release_variant_mocks "$fake_bin"
  cat >"$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "release" && "$2" == "view" ]] && exit 1
exit 1
EOF
  chmod +x "$fake_bin/gh"

  cd "$test_dir"
  local out
  out=$(PATH="$fake_bin:$PATH" GITHUB_REPOSITORY="owner/repo" release_variant '{"variant": "testing", "disabled": false}' "$(jq -cn --arg variants_config "$BATS_TEST_DIRNAME/../.github/variants.json" '{variants_config: $variants_config, dry_run: 1}')" 2>&1) || true
  [[ "$out" == *"WOULD CREATE release: testing-44.1"* ]]
  [[ "$out" == *"dry run"* ]]
}

# ── CI entry points (build_variant_ci, push_variant) ────────────────────────

# The CI steps reach these through the ci-pipeline and push recipes, so the
# recipe's quoting of the JSON arguments is part of the same contract. Check
# what just would run, without touching containers or the registry.
@test "ci-pipeline recipe passes its JSON arguments as single words" {
  local record out
  record='{"variant":"stable","image_desc":"Customized Bazzite image with Nix mount support"}'
  out=$(just --justfile "$BATS_TEST_DIRNAME/../Justfile" --dry-run ci-pipeline "$record" '{"rechunk":1}' 2>&1)
  grep -qF "build_variant_ci '$record' '{\"rechunk\":1}'" <<<"$out"
}

@test "push recipe passes its JSON arguments as single words" {
  local record out
  record='{"variant":"stable","image_desc":"Customized Bazzite image with Nix mount support"}'
  out=$(just --justfile "$BATS_TEST_DIRNAME/../Justfile" --dry-run push "$record" '{"registry":"ghcr.io/owner"}' 2>&1)
  grep -qF "push_variant '$record' '{\"registry\":\"ghcr.io/owner\"}'" <<<"$out"
}

@test "build_variant_ci passes its record and options through intact" {
  local captured gh
  captured="$(mktemp)"
  gh="$(mktemp)"
  build_variant_pipeline() {
    printf 'options=%s\n' "$2" >"$captured"
    echo '{"source_ref":"containers-storage:localhost/raw-img:stable"}'
  }
  export GITHUB_OUTPUT="$gh"
  build_variant_ci '{"variant":"stable","image_desc":"Customized Bazzite image with Nix mount support"}' '{"rechunk":1}'
  grep -q '^options={"rechunk":1,"build":"always"}$' "$captured"
  grep -q '^record={"source_ref"' "$gh"
}

# Mock the push units so the CI entry point's gates and reporting run without
# skopeo, cosign, or the registry. mkdir is shimmed: push_variant writes its
# authfile into a hardcoded /tmp path, which no test should touch.
push_variant_mocks() {
  mkdir() { :; }
  run_with_retry() { :; }
  push_image_with_tags() {
    printf 'remote_digest=sha256:abc\nremote_digest_ref=%s@sha256:abc\n' "$3"
  }
  sign_and_verify_image() { echo "status=success"; }
}

@test "push_variant reports the remote digest and signs" {
  local gh
  gh="$(mktemp)"
  push_variant_mocks
  export GITHUB_ACTOR=actor GITHUB_TOKEN=token SIGNING_SECRET=secret GITHUB_OUTPUT="$gh"
  push_variant '{"source_ref":"containers-storage:localhost/chunked-img:stable","tags":"stable-44.1,stable","variant":"stable","parent_version":"44.1","image_desc":"Customized Bazzite image with Nix mount support"}' '{"registry":"ghcr.io/owner","repo":"repo","date":"2026-10-16T02:44:40Z"}'
  grep -q '^remote_digest=sha256:abc$' "$gh"
  grep -q '^status=success$' "$gh"
}

@test "push_variant fails naming the missing registry and repo" {
  local err
  err="$(mktemp)"
  push_variant_mocks
  push_variant '{"source_ref":"x","tags":"t"}' '{}' 2>"$err" || true
  grep -q 'registry and repo are required push fields' "$err"
}

# ── cleanup_packages ────────────────────────────────────────────────────────

cleanup_variant_json() {
  local test_dir
  test_dir="$(mktemp -d)"
  cat >"$test_dir/variants.json" <<'EOF'
{
  "variants": [
    { "name": "stable", "base_image": "ghcr.io/ublue-os/bazzite:stable" },
    { "name": "testing", "base_image": "ghcr.io/ublue-os/bazzite:testing", "suffix": "-testing" },
    { "name": "gpu", "base_image": "ghcr.io/ublue-os/bazzite:stable", "suffix": "-gpu", "cleanup": false },
    { "name": "deck", "base_image": "ghcr.io/ublue-os/bazzite:stable", "suffix": "-deck", "disabled": true }
  ]
}
EOF
  echo "$test_dir"
}

@test "cleanup_packages takes the default set from config policy" {
  local test_dir
  test_dir="$(cleanup_variant_json)"
  run cleanup_packages "owner/Bazzite-NIX" "$test_dir/variants.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'bazzite-nix\nbazzite-nix-testing')" ]
}

@test "cleanup_packages honours a named package even when config opts it out" {
  local test_dir
  test_dir="$(cleanup_variant_json)"
  run cleanup_packages "owner/Bazzite-NIX" "$test_dir/variants.json" " bazzite-nix-GPU ,bazzite-nix-deck "
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'bazzite-nix-deck\nbazzite-nix-gpu')" ]
}

@test "cleanup_packages prints nothing for a filter that matches no package" {
  local test_dir
  test_dir="$(cleanup_variant_json)"
  run cleanup_packages "owner/Bazzite-NIX" "$test_dir/variants.json" "nothing"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "cleanup addresses only packages the variant records name" {
  local test_dir
  test_dir="$(cleanup_variant_json)"
  local expected
  expected="$(jq -r --arg base bazzite-nix '
      [ .variants[] | select(.disabled != true and .cleanup != false) | ($base + (.suffix // "")) ] | unique | .[]
    ' "$test_dir/variants.json")"
  [[ "$(cleanup_packages "owner/Bazzite-NIX" "$test_dir/variants.json")" == "$expected" ]]
}

# ── Justfile entrypoints: one dispatcher, every recipe one call ─────────────
# The dispatcher is what makes the Justfile's recipe bodies single lines (DESIGN.md §3:
# "entrypoint files are small on purpose"). Asserted over the real Justfile so a recipe
# cannot quietly regain a per-recipe preamble or a shell block.

@test "dispatcher runs the named helper with its arguments" {
  run "${BATS_TEST_DIRNAME}/just-helpers.sh" disk_file_name qcow2
  [ "$status" -eq 0 ]
  [ "$output" = "disk.qcow2" ]
}

@test "dispatcher fails naming an entrypoint that does not exist" {
  run -127 "${BATS_TEST_DIRNAME}/just-helpers.sh" no_such_entrypoint_zz
  [[ "$output" == *"no_such_entrypoint_zz"* ]]
}

@test "no Justfile recipe carries a bash preamble and the file stays fmt-clean" {
  local justfile="${BATS_TEST_DIRNAME}/../Justfile"
  [[ "$(grep -c '#!/usr/bin/env bash' "$justfile")" -eq 0 ]]
  ! grep -q 'source "{{ just_helpers }}"' "$justfile"
  run just --unstable --fmt --check -f "$justfile"
  [ "$status" -eq 0 ]
}

@test "helper recipes delegate to the dispatcher, they do not inline shell" {
  local justfile="${BATS_TEST_DIRNAME}/../Justfile"
  for recipe in lint format clean clean-vm check-variants list-variants build rootful-load; do
    run just --justfile "$justfile" --dry-run "$recipe"
    [[ "$output" == *"just-helpers.sh"* ]]
  done
}

@test "entry_variant sends each mode to run_variant and rejects the rest" {
  local called
  called="$(mktemp)"
  run_variant() { printf '%s\n' "$1" >>"$called"; }
  entry_variant rechunk testing image_name=bazzite-nix
  entry_variant relabel testing image_name=bazzite-nix
  entry_variant pipeline testing image_name=bazzite-nix
  run entry_variant bogus testing
  [ "$status" -ne 0 ]
  [[ "$output" == *"mode must be"* ]]
  run cat "$called"
  [ "$output" = "$(printf 'rechunk\nrelabel\npipeline')" ]
}

@test "rootful_load resolves the variant and streams it into rootful storage" {
  local got
  got="$(mktemp)"
  resolve_variant() { printf '%s\n' "stable" >&2; echo '{"variant":"stable","tag":"t"}'; }
  podman() {
    printf '%s\n' "$*" >>"$got"
    [ "$1" = "load" ] || printf 'payload\n'
  }
  sudo() { podman "${@:2}"; }
  pv() { cat; }
  rootful_load testing cfg.json bazzite-nix
  [ "$(cat "$got")" = "$(printf 'save localhost/chunked-img:stable\nload')" ]
}

@test "the OCI layout root is a real path, never a template" {
  local root
  root="$(bash -c "source '$BATS_TEST_DIRNAME/just-helpers.bash' && oci_output_root")"
  [[ "$root" == *"/oci" ]]
  [[ "$root" != *"{{"* ]]
}

@test "recipe parameter defaults never interpolate (they are literals)" {
  local justfile="${BATS_TEST_DIRNAME}/../Justfile"
  ! grep -qE '[$][a-z_]+="[^"]*\{\{' "$justfile"
}

@test "entry_vm_build rejects a type that has no disk format" {
  run entry_vm_build iso testing
  [ "$status" -ne 0 ]
  [[ "$output" == *"VM type must be qcow2 or raw"* ]]
}
