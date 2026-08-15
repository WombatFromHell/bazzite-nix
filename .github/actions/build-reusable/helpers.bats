#!/usr/bin/env bats
# helpers.bats — Smoke tests for build-reusable/helpers.sh using mocked tooling.
#
# Run with: bats .github/actions/build-reusable/helpers.bats

setup() {
    source "$BATS_TEST_DIRNAME/helpers.sh"
}

# ── extract_image_info ──────────────────────────────────────────────────────

@test "extract_image_info reads kernel and manifest in one podman run" {
    unset GITHUB_OUTPUT

    # Mock sudo to exec through, and podman to serve both files at once.
    sudo() { "$@"; }
    export -f sudo
    podman() {
        cat <<'EOF'
6.19.8-400.fc41.x86_64
{"packages":{"kernel":"6.19.8"}}
EOF
    }
    export -f podman

    local output
    output=$(extract_image_info)
    echo "$output" | grep -q '^KERNEL_VERSION=6.19.8-400.fc41.x86_64$'
    echo "$output" | grep -q '^MANIFEST_PACKAGES=1$'
}

# ── relabel_image ───────────────────────────────────────────────────────────

@test "relabel_image clears and applies labels in one buildah session" {
    local labels_file log
    labels_file="$(mktemp)"
    log="$(mktemp)"
    printf '%s\n' \
        'org.opencontainers.image.version=44' \
        'ostree.rechunk.info={"packages":{"kernel":"6.19.8"}}' \
        >"$labels_file"

    # Mock buildah, logging each invocation (+ args) to a file so the
    # subshell's counters persist after the function returns.
    sudo() { "$@"; }
    export -f sudo
    buildah() {
        printf 'buildah %s\n' "$*" >>"$LOG"
        case "$1" in
        from) echo "container-123" ;;
        mount) echo "/tmp/relabel-mnt" ;;
        esac
    }
export -f buildah
    export LOG="$log"

    relabel_image "$labels_file" "6.19.8-400.fc41.x86_64"

    # Exactly one from/config/commit sequence
    [ "$(grep -c '^buildah from ' "$log")" -eq 1 ]
    [ "$(grep -c '^buildah commit ' "$log")" -eq 1 ]

    # One config call that clears labels (-) then applies the file labels
    # and the bootc/ostree labels/annotations.
    local config_args
    config_args=$(grep '^buildah config ' "$log")
    [ "$(echo "$config_args" | wc -l)" -eq 1 ]
    [ -n "$config_args" ]
    echo "$config_args" | grep -q -- "--label - "
    echo "$config_args" | grep -q 'org.opencontainers.image.version=44'
    echo "$config_args" | grep -q 'ostree.rechunk.info={"packages":{"kernel":"6.19.8"}}'
    echo "$config_args" | grep -q -- '--label ostree.bootc=true'
    echo "$config_args" | grep -q -- '--annotation ostree.linux=6.19.8-400.fc41.x86_64'
}

# ── extract_final_ref ───────────────────────────────────────────────────────

@test "extract_final_ref digs from single skopeo inspect" {
    unset GITHUB_OUTPUT

    sudo() { "$@"; }
    export -f sudo
    skopeo() {
        case "$1" in
        inspect) echo "sha256:abc123" ;;
        esac
    }
    export -f skopeo

    local output
    output=$(extract_final_ref)
    echo "$output" | grep -q '^SOURCE_REF=containers-storage:localhost/chunked-img$'
    echo "$output" | grep -q '^FULL_BUILD_DIGEST=sha256:abc123$'
    echo "$output" | grep -q '^BUILD_DIGEST=abc123$'
}