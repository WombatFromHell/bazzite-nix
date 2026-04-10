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

@test "clean_artifacts creates _build marker file" {
    local test_dir
    test_dir="$(mktemp -d)"
    cd "$test_dir"
    clean_artifacts
    [ -f "_build" ]
}

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

# ── build_bib and build_bib_oci ─────────────────────────────────────────────

@test "build_bib skips when disk file exists" {
    local test_dir
    test_dir="$(mktemp -d)"
    touch "$test_dir/disk.qcow2"

    local output
    output=$(build_bib "localhost/test" "latest" "qcow2" "config.toml" "$test_dir" "quay.io/centos-bootc/bootc-image-builder:latest" 2>&1)
    [[ "$output" == *"Disk image already exists"* ]]
}

@test "build_bib_oci skips when disk file exists" {
    local test_dir
    test_dir="$(mktemp -d)"
    touch "$test_dir/disk.raw"

    local output
    output=$(build_bib_oci "oci:/test:latest" "latest" "raw" "config.toml" "$test_dir" "localhost/rechunked" "quay.io/centos-bootc/bootc-image-builder:latest" 2>&1)
    [[ "$output" == *"Disk image already exists"* ]]
}

# ── check_variants ──────────────────────────────────────────────────────────

@test "check_variants requires repo_organization parameter" {
    run check_variants 0 "" "bazzite-nix" ".github/variants.json"
    [ "$status" -ne 0 ]
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
