#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# helpers.bats — Smoke tests for build-reusable/helpers.sh using mocked tooling.
#
# Run with: bats tests/build-helpers.bats

setup() {
  source "$BATS_TEST_DIRNAME/../scripts/build-helpers.bash"
}

# ── sudo credential caching ─────────────────────────────────────────────────

@test "sudo_cache primes the credential cache" {
  local log
  log="$(mktemp)"
  sudo() {
    printf 'sudo %s\n' "$*" >>"$LOG"
    return 0
  }
  export -f sudo
  export LOG="$log"

  sudo_cache
  grep -q '^sudo -v$' "$log"
}

# ── build_image_or_skip ─────────────────────────────────────────────────────

@test "build_image_or_skip skips when raw-img exists, builds when missing" {
  local log
  log="$(mktemp)"
  sudo() { "$@"; }
  export -f sudo
  buildah() {
    printf 'buildah %s\n' "$*" >>"$LOG"
    [[ "${EXISTS:-1}" == "1" ]] && return 0 || return 1
  }
  export -f buildah
  build_image() { printf 'build_image %s\n' "$*" >>"$LOG"; }
  export -f build_image
  export LOG="$log"

  EXISTS=1 build_image_or_skip "base" "build.sh" "1.0.0" "testing"
  run ! grep -q '^build_image ' "$log"

  : >"$log"
  EXISTS=0 build_image_or_skip "base" "build.sh" "1.0.0" "testing"
  grep -q '^build_image ' "$log"
}

@test "build_image pins buildah timestamps to the fixed epoch" {
  local log
  log="$(mktemp)"
  buildah() {
    printf 'buildah %s\n' "$*" >>"$LOG"
  }
  export -f buildah
  export LOG="$log"

  build_image "base" "build.sh" "1.0.0" "testing" "Containerfile" "testing-1.0.0"
  grep -q -- '--source-date-epoch 0 --rewrite-timestamp' "$log"
}

# ── extract_image_info ──────────────────────────────────────────────────────

@test "extract_image_info reads kernel and manifest in one podman run" {
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

@test "extract_image_info prints the same assignments when GITHUB_OUTPUT is set" {
  GITHUB_OUTPUT="$(mktemp)"
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

@test "relabel_image clears inherited labels then applies them in one buildah session" {
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
    commit) echo "sha256:deadbeef" ;;
    esac
  }
  export -f buildah
  export LOG="$log"

  # buildah commit digests must not leak to stdout (the build sequence evals
  # this function's stdout, so a stray commit digest would be executed).
  run relabel_image "$labels_file" "6.19.8-400.fc41.x86_64"
  [ "$status" -eq 0 ]
  [[ "$output" != *"sha256:deadbeef"* ]]
  # progress echoes go to stderr
  echo "$output" | grep -q "Relabeling raw-img: clearing inherited labels, then applying 4 labels and annotations..."

  # One from/config/commit sequence: wipe inherited labels, then apply ours
  [ "$(grep -c '^buildah from ' "$log")" -eq 1 ]
  [ "$(grep -c '^buildah commit ' "$log")" -eq 1 ]

  # The first config call wipes all inherited labels
  grep -q -- 'buildah config --label - container-123' "$log"

  # Each file label plus bootc/ostree labels and annotations, one config call at a time.
  grep -q -- '--label org.opencontainers.image.version=44 --annotation org.opencontainers.image.version=44' "$log"
  grep -q -- '--label ostree.rechunk.info={"packages":{"kernel":"6.19.8"}} --annotation ostree.rechunk.info={"packages":{"kernel":"6.19.8"}}' "$log"
  grep -q -- '--label ostree.bootc=true --annotation ostree.bootc=true' "$log"
  grep -q -- '--label ostree.linux=6.19.8-400.fc41.x86_64 --annotation ostree.linux=6.19.8-400.fc41.x86_64' "$log"
}

# ── rechunk_image ───────────────────────────────────────────────────────────

@test "rechunk_image chunks raw-img with chunkah into an OCI layout and pulls it back" {
  local log
  log="$(mktemp)"

  sudo() { "$@"; }
  export -f sudo
  podman() {
    printf 'podman %s\n' "$*" >>"$LOG"
    case "$1" in
    pull)
      case "$2" in
      quay.io/coreos/chunkah:latest) echo "sha256:chunkah-image" ;;
      oci:*) echo "sha256:chunked-digest" ;;
      esac
      ;;
    image)
      echo "quay.io/coreos/chunkah@sha256:chunkah-ref"
      ;;
    esac
  }
  export -f podman
  cosign() {
    printf 'cosign %s\n' "$*" >>"$LOG"
    return 0
  }
  export -f cosign
  export LOG="$log"

  rechunk_image "stable"

  # chunkah is pulled and its signature verified
  grep -q 'podman pull quay.io/coreos/chunkah:latest' "$log"
  grep -q 'cosign verify' "$log"
  # raw-img config is inspected to carry Env/Cmd/bootc metadata over
  grep -q 'podman image inspect localhost/raw-img' "$log"
  # chunked output is an OCI layout under the per-variant OCI dir
  # (variant param defaults to "latest" when only tags are given)
  local layout_base="${OCI_OUTPUT_DIR:-${CACHE_DIR:-$HOME/.cache/bazzite-nix}/oci}/latest"
  local expected_layout="${layout_base}/chunked"
  grep -q -- '--output oci:/run/out/chunked' "$log"
  grep -q -- "--volume ${layout_base}:/run/out:Z" "$log"
  grep -q -- '--mount=type=image,src=localhost/raw-img,target=/chunkah' "$log"
  grep -q -- '--prune /sysroot/' "$log"
  # the manifest creation time and layer mtimes are pinned, matching finalize's clamp
  grep -q -- '--source-date-epoch 0' "$log"
  # stale OSTree/build labels are dropped
  grep -q -- '--label ostree.commit-' "$log"
  # pulled back from the per-variant layout and tagged as chunked-img, plus the anchor tag
  grep -q "podman pull oci:${expected_layout}" "$log"
  grep -q 'podman tag sha256:chunked-digest localhost/chunked-img' "$log"
  grep -q 'podman tag localhost/chunked-img localhost/chunked-img:stable' "$log"
}

# ── extract_final_ref ───────────────────────────────────────────────────────

@test "extract_final_ref digs from single podman image inspect" {
  sudo() { "$@"; }
  export -f sudo
  podman() {
    if [[ "$1" == "image" && "$2" == "inspect" ]]; then
      echo "sha256:abc123"
    fi
  }
  export -f podman

  local output
  output=$(extract_final_ref "latest")
  echo "$output" | grep -q '^SOURCE_REF=containers-storage:localhost/chunked-img:latest$'
  echo "$output" | grep -q '^FULL_BUILD_DIGEST=sha256:abc123$'
  echo "$output" | grep -q '^BUILD_DIGEST=abc123$'
}

@test "extract_final_ref prints the same assignments when GITHUB_OUTPUT is set" {
  GITHUB_OUTPUT="$(mktemp)"
  podman() {
    if [[ "$1" == "image" && "$2" == "inspect" ]]; then
      echo "sha256:abc123"
    fi
  }
  export -f podman
  local output
  output=$(extract_final_ref "latest")
  echo "$output" | grep -q '^SOURCE_REF=containers-storage:localhost/chunked-img:latest$'
  echo "$output" | grep -q '^FULL_BUILD_DIGEST=sha256:abc123$'
  echo "$output" | grep -q '^BUILD_DIGEST=abc123$'
}
