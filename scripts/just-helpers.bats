#!/usr/bin/env bats
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

@test "clean_artifacts removes manifest and output files" {
    cd "$(mktemp -d)"
    touch previous.manifest.json changelog.md output.env
    mkdir -p output/
    clean_artifacts
    [ ! -f "previous.manifest.json" ]
    [ ! -f "changelog.md" ]
    [ ! -f "output.env" ]
    [ ! -d "output" ]
}

# ── clean_oci_layout ────────────────────────────────────────────────────────

@test "clean_oci_layout removes directory when index.json exists" {
    local test_dir
    test_dir="$(mktemp -d)"
    mkdir -p "$test_dir"
    touch "$test_dir/index.json"
    # Mock sudo to use regular rm
    sudo() { "$@"; }
    export -f sudo

    clean_oci_layout "$test_dir"
    [ ! -d "$test_dir" ]
}

@test "clean_oci_layout skips directory without index.json" {
    local test_dir
    test_dir="$(mktemp -d)"
    mkdir -p "$test_dir"
    # No index.json

    local output
    output=$(clean_oci_layout "$test_dir" 2>&1) || true
    [ -d "$test_dir" ]  # Directory should still exist
}

# ── clean_vm_cache ──────────────────────────────────────────────────────────

@test "clean_vm_cache removes existing cache directory" {
    local test_dir
    test_dir="$(mktemp -d)"
    mkdir -p "$test_dir"
    touch "$test_dir/disk.qcow2"
    sudo() { "$@"; }
    export -f sudo

    clean_vm_cache "$test_dir"
    [ ! -d "$test_dir" ]
}

@test "clean_vm_cache reports when cache does not exist" {
    local test_dir
    test_dir="$(mktemp -d)/nonexistent"

    local output
    output=$(clean_vm_cache "$test_dir" 2>&1)
    [[ "$output" == *"VM cache does not exist"* ]]
}

# ── resolve_variant ─────────────────────────────────────────────────────────

setup_variant_json() {
    local test_dir
    test_dir="$(mktemp -d)"
    cat > "$test_dir/variants.json" <<'EOF'
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

@test "resolve_variant outputs correct variable assignments" {
    local test_dir
    test_dir="$(setup_variant_json)"

    # Mock skopeo to return a version label
    skopeo() {
        echo '{"Labels":{"org.opencontainers.image.version":"1.0.0"}}'
    }
    export -f skopeo

    local output
    output=$(resolve_variant "testing" "$test_dir/variants.json" "bazzite-nix")
    [[ "$output" == *'TARGET_IMAGE="localhost/bazzite-nix"'* ]]
    [[ "$output" == *'VARIANT_NAME="testing"'* ]]
    [[ "$output" == *'BASE_IMAGE="ghcr.io/ublue-os/bazzite:stable"'* ]]
}

@test "resolve_variant bumps canonical on version collision (force_build)" {
    local test_dir
    test_dir="$(setup_variant_json)"

    # Mock skopeo: testing-1.0.1 is free, everything else exists
    skopeo() {
        case "$*" in
        *"testing-1.0.1"*) return 1 ;;
        *) echo '{"Labels":{"org.opencontainers.image.version":"1.0.0"}}' ;;
        esac
    }
    export -f skopeo

    local output
    output=$(resolve_variant "testing" "$test_dir/variants.json" "bazzite-nix" "1" "ghcr.io/test-owner")
    [[ "$output" == *'CANONICAL_TAG="1.0.1"'* ]]
    [[ "$output" == *'COLLISION_DETECTED="true"'* ]]
}

@test "resolve_variant drops {sha256} tags (digest is resolved at push time, not from upstream)" {
    local test_dir
    test_dir="$(mktemp -d)"
    cat > "$test_dir/variants.json" <<'EOF'
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

    # Mock skopeo: upstream has a digest — resolve_variant must NOT use it for tags
    skopeo() {
        echo '{"Labels":{"org.opencontainers.image.version":"1.0.0"},"Digest":"sha256:fbd9a04deadbeef"}'
    }
    export -f skopeo

    local output
    output=$(resolve_variant "stable" "$test_dir/variants.json" "bazzite-nix")
    [[ "$output" == *'TAGS="1.0.0,stable"'* ]]
    ! [[ "$output" == *"fbd9a04deadbeef"* ]]
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
    [[ "$output" == *'BASE_IMAGE="ghcr.io/ublue-os/bazzite:testing"'* ]]
    [[ "$output" == *'TAG="testing"'* ]]
}

# ── build_bib (unified podman/oci) ───────────────────────────────────────────────

@test "build_bib podman skips when disk file exists" {
    local test_dir
    test_dir="$(mktemp -d)"
    touch "$test_dir/disk.qcow2"

    local output
    output=$(build_bib "podman" "localhost/test" "latest" "qcow2" "config.toml" "$test_dir" "quay.io/centos-bootc/bootc-image-builder:latest" 2>&1)
    [[ "$output" == *"Disk image already exists"* ]]
}

@test "build_bib oci skips when disk file exists" {
    local test_dir
    test_dir="$(mktemp -d)"
    touch "$test_dir/disk.raw"

    local output
    output=$(build_bib "oci" "oci:/test:latest" "latest" "raw" "config.toml" "$test_dir" "quay.io/centos-bootc/bootc-image-builder:latest" 2>&1)
    [[ "$output" == *"Disk image already exists"* ]]
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

    cat > /tmp/variants_results.json <<'EOF'
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

    echo '[]' > /tmp/variants_results.json

    GITHUB_OUTPUT="$gh_out" aggregate_variants "ghcr.io/owner" "bazzite-nix" "$test_dir/summary" >/dev/null

    grep -q '^variants_to_build=\[\]$' "$gh_out"
    grep -q '^any_builds_needed=false$' "$gh_out"
    [ -f "$test_dir/summary" ]
}

# ── release_variant ─────────────────────────────────────────────────────────

@test "release_variant rejects unknown variant" {
    local test_dir
    test_dir="$(setup_variant_json)"

    GH_TOKEN=x run release_variant "nope" "" "$test_dir/variants.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found in variants.json"* ]]
}

@test "release_variant rejects disabled variant" {
    local test_dir
    test_dir="$(setup_variant_json)"

    GH_TOKEN=x run release_variant "disabled-variant" "" "$test_dir/variants.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is disabled in variants.json"* ]]
}

# ── sudoif ──────────────────────────────────────────────────────────────────

@test "sudoif is defined and callable" {
    run bash -c "
        source '$PWD/scripts/just-helpers.bash'
        type sudoif | grep -q 'sudoif is a function'
    "
    [ "$status" -eq 0 ]
}

@test "sudoif exits when sudo is unavailable" {
    local test_dir
    test_dir="$(mktemp -d)"
    mkdir -p "$test_dir/bin"

    # Set PATH inside the subshell so bash itself is still resolvable
    run bash -c "
        PATH='$test_dir/bin'
        source '$PWD/scripts/just-helpers.bash'
        sudoif echo test
    "
    [ "$status" -eq 1 ]
}

# ── build_variant_core (shared build pipeline core) ─────────────────────────

# Mock the build-helpers functions so build_variant_core's branch logic can be
# tested without real containers. Records relabel/rechunk calls to a calls file.
build_core_mocks() {
    local calls="$1"
    extract_image_info() {
        echo "KERNEL_VERSION=6.6.0"
        echo "MANIFEST_PACKAGES=42"
    }
    assemble_labels() { :; }
    relabel_image() { echo "REL:$3" >>"$calls"; }
    rechunk_image() { echo "RECHUNK:$1" >>"$calls"; }
    extract_final_ref() {
        echo "SOURCE_REF=containers-storage:localhost/$2:$1"
        echo "FULL_BUILD_DIGEST=sha256:abc"
        echo "BUILD_DIGEST=abc"
    }
}

build_core_common="stable 2026-08-17T00:00:00Z desc 44.1 owner repo"

@test "build_variant_core relabels raw-img directly when rechunk disabled" {
    local calls
    calls="$(mktemp)"
    build_core_mocks "$calls"
    local SOURCE_REF KERNEL_VERSION
    eval "$(build_variant_core $build_core_common 0 0)"
    [ "$KERNEL_VERSION" = "6.6.0" ]
    [ "$SOURCE_REF" = "containers-storage:localhost/raw-img:stable" ]
    grep -q "REL:raw-img" "$calls"
    ! grep -q "RECHUNK:" "$calls"
}

@test "build_variant_core rechunks then relabels the rechunked image when rechunk enabled (force)" {
    local calls
    calls="$(mktemp)"
    build_core_mocks "$calls"
    local SOURCE_REF
    eval "$(build_variant_core $build_core_common 1 1)"
    [ "$SOURCE_REF" = "containers-storage:localhost/chunked-img:stable" ]
    local rel_line rechunk_line
    rel_line=$(grep -n "REL:chunked-img" "$calls" | cut -d: -f1)
    rechunk_line=$(grep -n "RECHUNK:stable" "$calls" | cut -d: -f1)
    [ "$rechunk_line" -lt "$rel_line" ]
}

@test "build_variant_core skips relabel & rechunk when chunked image already exists" {
    local calls
    calls="$(mktemp)"
    build_core_mocks "$calls"
    sudo() { return 0; }
    run build_variant_core $build_core_common 0 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping relabel & rechunk"* ]]
    [[ "$output" == *"SOURCE_REF=containers-storage:localhost/chunked-img:stable"* ]]
    ! grep -q "RECHUNK:" "$calls"
    ! grep -q "REL:" "$calls"
}

# ── collect_successful_builds ───────────────────────────────────────────────

@test "collect_successful_builds extracts successful Build & Push variants" {
    local jobs out
    jobs='{"jobs":[{"name":"Check variants","conclusion":"success"},{"name":"Build & Push stable","conclusion":"success"},{"name":"Build & Push testing","conclusion":"failure"},{"name":"Build & Push unstable","conclusion":"success"}]}'
    out=$(collect_successful_builds "$jobs")
    [[ "$out" == '[{"variant":"stable"},{"variant":"unstable"}]' ]]
}

@test "collect_successful_builds returns empty array when none succeeded" {
    local jobs out
    jobs='{"jobs":[{"name":"Build & Push stable","conclusion":"failure"}]}'
    out=$(collect_successful_builds "$jobs")
    [[ "$out" == '[]' ]]
}

@test "collect_successful_builds writes GITHUB_OUTPUT" {
    local test_dir gh_out jobs
    test_dir="$(mktemp -d)"
    gh_out="$test_dir/gh_output"
    touch "$gh_out"
    jobs='{"jobs":[{"name":"Build & Push stable","conclusion":"success"}]}'
    GITHUB_OUTPUT="$gh_out" collect_successful_builds "$jobs" >/dev/null
    grep -q '^successful_variants=\[{"variant":"stable"}\]$' "$gh_out"
    grep -q '^any_successful=true$' "$gh_out"
}

# ── resolve_release_variants ────────────────────────────────────────────────

@test "resolve_release_variants returns all enabled variants when blank" {
    local test_dir out
    test_dir="$(setup_variant_json)"
    out=$(resolve_release_variants "" "$test_dir/variants.json")
    [[ "$out" == "testing" ]]
}

@test "resolve_release_variants intersects explicit input with recent successful builds" {
    local test_dir out
    test_dir="$(setup_variant_json)"
    recent_successful_builds() { printf 'stable\ntesting\n'; }
    export -f recent_successful_builds
    out=$(resolve_release_variants "testing,stable,nope" "$test_dir/variants.json")
    [[ "$out" == $'stable\ntesting' ]]
}

@test "resolve_release_variants warns and drops variants not recently built" {
    local test_dir out err
    test_dir="$(setup_variant_json)"
    recent_successful_builds() { printf 'testing\n'; }
    export -f recent_successful_builds
    err="$test_dir/err"
    out=$(resolve_release_variants "testing,stable" "$test_dir/variants.json" 2>"$err")
    [[ "$out" == "testing" ]]
    grep -q "no recent successful build" "$err"
}

# ── release_variant (missing-tag gate & dry run) ────────────────────────────

# Mock changelog.py: emit a canned TITLE/TAG and touch the notes file.
release_variant_mocks() {
    local fake_bin="$1"
    cat >"$fake_bin/python3" <<'EOF'
#!/usr/bin/env bash
cat > output.env <<'OUT'
TITLE="Testing (F44)"
TAG="testing-44.1"
OUT
touch changelog.md
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
    out=$(PATH="$fake_bin:$PATH" GITHUB_REPOSITORY="owner/repo" release_variant "testing" "" "$BATS_TEST_DIRNAME/../.github/variants.json" 2>&1) || true
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
    out=$(PATH="$fake_bin:$PATH" GITHUB_REPOSITORY="owner/repo" release_variant "testing" "" "$BATS_TEST_DIRNAME/../.github/variants.json" "" "" "" "1" 2>&1) || true
    [[ "$out" == *"WOULD CREATE release: testing-44.1"* ]]
    [[ "$out" == *"dry run"* ]]
}
