# just-helpers-build.bash — build pipeline, CI parity, and build-all functions.
# Sourced by just-helpers.bash (no shebang/set — see umbrella).

# ── Build pipeline functions ────────────────────────────────────────────────

# Build a container image (stages to localhost/raw-img)
run_build() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local base_image_override="${4:-}"
  local force_rebuild="${5:-0}"
  local TARGET_IMAGE TAG BASE_IMAGE BUILD_SCRIPT VARIANT_NAME CANONICAL_TAG TAGS
  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name" "$force_rebuild")"
  [[ -n "$base_image_override" ]] && BASE_IMAGE="$base_image_override"
  build_image_or_skip "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "$force_rebuild"
}

# Human-readable build summary (reads the eval-assignment vars set by the caller)
print_build_summary() {
  local title="${1:?title required}"
  echo ""
  echo "=== ${title} ===" >&2
  echo "  Variant      : $VARIANT_NAME" >&2
  echo "  Version      : $CANONICAL_TAG" >&2
  echo "  Tags         : $TAGS" >&2
  echo "  Kernel       : $KERNEL_VERSION" >&2
  echo "  Manifest pkgs: $MANIFEST_PACKAGES" >&2
  echo "  Source ref   : $SOURCE_REF" >&2
  echo "  Full digest  : $FULL_BUILD_DIGEST" >&2
  echo "  Short digest : $BUILD_DIGEST" >&2
}

# Eval-able build refs (the stdout contract of build_variant_core / run_rechunk / run_relabel)
echo_build_assignments() {
  echo "KERNEL_VERSION=${KERNEL_VERSION}"
  echo "MANIFEST_PACKAGES=${MANIFEST_PACKAGES}"
  echo "SOURCE_REF=${SOURCE_REF}"
  echo "FULL_BUILD_DIGEST=${FULL_BUILD_DIGEST}"
  echo "BUILD_DIGEST=${BUILD_DIGEST}"
}

# Shared build-pipeline core: extract info → assemble labels → relabel →
# [rechunk] → extract final ref. The single implementation used by the local
# pipeline (run_pipeline), standalone rechunk (run_rechunk), and CI
# (build_variant_ci) so local runs exercise the same code as the workflow.
#
# Rechunk is opt-in (rechunk=0 default) and runs chunkah (which applies labels
# itself), so no relabel pass happens on the rechunk path.
#
# Usage: build_variant_core <variant> <date> <image_desc> <version_label> \
#                           <repo_owner> <repo_name> [force_rebuild] [rechunk]
# PRECONDITION: localhost/raw-img exists (built by the caller) and build-helpers.bash
# is sourced ($JUST_HELPERS_BUILD). Requires GITHUB_OUTPUT unset so extract_* emit
# uppercase vars for eval.
# Prints eval-able uppercase assignments (KERNEL_VERSION, MANIFEST_PACKAGES,
# SOURCE_REF, FULL_BUILD_DIGEST, BUILD_DIGEST). Call with: eval "$(build_variant_core ...)"
build_variant_core() {
  local variant="${1:?variant required}"
  local date="${2:?date required}"
  local image_desc="${3:?image_desc required}"
  local version_label="${4:?version_label required}"
  local repo_owner="${5:?repo_owner required}"
  local repo_name="${6:?repo_name required}"
  local force_rebuild="${7:-0}"
  local rechunk="${8:-0}"
  local manifest_file="/tmp/bazzite-nix-manifest.json"
  local labels_file="/tmp/bazzite-nix-labels.txt"
  local KERNEL_VERSION="" MANIFEST_PACKAGES="" SOURCE_REF="" FULL_BUILD_DIGEST="" BUILD_DIGEST=""
  local anchor_tag image_name_ref
  local _step_n=0
  _step() {
    _step_n=$((_step_n + 1))
    echo "=== Step ${_step_n}: $1 ===" >&2
  }

  unset GITHUB_OUTPUT
  _step "Extract image info (kernel + manifest)"
  eval "$(extract_image_info "$manifest_file")"

  # Anchor on the variant name so different variant pipelines never clobber
  # each other's working images (raw-img:<variant> / chunked-img:<variant>).
  anchor_tag="$variant"
  if [[ "$rechunk" == "1" ]]; then
    image_name_ref="chunked-img"
  else
    image_name_ref="raw-img"
  fi

  # Skip relabel & rechunk only when a prior rechunked image already exists
  # (raw-img always exists after the build phase, so it's always relabeled).
  if [[ "$rechunk" == "1" && "$force_rebuild" != "1" ]] && buildah images --format '{{.Name}}:{{.Tag}}' "localhost/chunked-img:${anchor_tag}" >/dev/null 2>&1; then
    _step "skipping relabel & rechunk: localhost/chunked-img:${anchor_tag} already exists"
  else
    _step "Assemble image labels"
    assemble_labels \
      "$date" "$image_desc" "$variant" "$version_label" \
      "$repo_owner" "$repo_name" "$KERNEL_VERSION" \
      "$manifest_file" "$labels_file"
    if [[ "$rechunk" == "1" ]]; then
      _step "Rechunk image (chunkah)"
      # chunkah applies the labels at chunk time (--label), so no separate
      # relabel pass is needed after rechunking.
      rechunk_image "$anchor_tag" "$labels_file"
    else
      _step "Relabel image (raw-img)"
      relabel_image "$labels_file" "$KERNEL_VERSION" "raw-img" "$anchor_tag"
    fi
  fi

  _step "Extract final image ref"
  eval "$(extract_final_ref "$anchor_tag" "$image_name_ref")"

  echo_build_assignments
}

# Relabel and rechunk raw-img to containers-storage with bootc chunking
# Prints eval-able uppercase assignments (KERNEL_VERSION, MANIFEST_PACKAGES,
# SOURCE_REF, FULL_BUILD_DIGEST, BUILD_DIGEST); the human summary goes to
# stderr. Call with: eval "$(run_rechunk ...)"
run_rechunk() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local image_desc="${4:-Customized Bazzite image with Nix mount support and other sugar}"
  local repo_organization="${5:?repo_organization required}"
  local force_build="${6:-0}"
  local quiet="${7:-0}"
  local TAG="" VARIANT_NAME="" CANONICAL_TAG="" TAGS=""
  local KERNEL_VERSION="" MANIFEST_PACKAGES="" SOURCE_REF="" FULL_BUILD_DIGEST="" BUILD_DIGEST=""

  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name" "$force_build")"

  if ! buildah images --format '{{.Name}}' raw-img >/dev/null 2>&1; then
    echo "ERROR: Base image 'localhost/raw-img' not found. Run build step first." >&2
    return 1
  fi

  # force=1 so this always rechunks (never takes the skip-if-chunked-exists path)
  eval "$(build_variant_core "$VARIANT_NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$image_desc" "$CANONICAL_TAG" "$repo_organization" "$image_name" "1" "1")"

  # Human summary goes to stderr; stdout carries the eval-able assignments so
  # run_pipeline can capture them (mirrors build_variant_core's contract).
  [[ "$quiet" != "1" ]] && print_build_summary "Rechunk complete"
  echo_build_assignments
}

# Relabel an existing image without rebuilding or rechunking, for iterating on
# the relabel flow. Auto-detects the image to relabel: chunked-img when one
# exists for the variant (rechunk path), else raw-img (non-rechunk path). Pass
# an explicit image name (raw-img | chunked-img) to force the target.
# Usage: run_relabel <variant_or_spec> <variants_config> <image_name> <image_desc> \
#                     <repo_organization> [image_name_ref]
# PRECONDITION: the target image exists and build-helpers.bash is sourced
# ($JUST_HELPERS_BUILD). Requires GITHUB_OUTPUT unset so extract_* emit
# uppercase vars for eval.
# Prints eval-able uppercase assignments (KERNEL_VERSION, MANIFEST_PACKAGES,
# SOURCE_REF, FULL_BUILD_DIGEST, BUILD_DIGEST). Call with: eval "$(run_relabel ...)"
run_relabel() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local image_desc="${4:-Customized Bazzite image with Nix mount support and other sugar}"
  local repo_organization="${5:?repo_organization required}"
  local image_name_ref="${6:-}"
  local quiet="${7:-0}"
  local TAG="" VARIANT_NAME="" CANONICAL_TAG="" TAGS=""
  local KERNEL_VERSION="" MANIFEST_PACKAGES="" SOURCE_REF="" FULL_BUILD_DIGEST="" BUILD_DIGEST=""
  local anchor_tag manifest_file labels_file

  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name")"

  # Anchor on the variant name so different variant pipelines never clobber
  # each other's working images (raw-img:<variant> / chunked-img:<variant>).
  anchor_tag="$VARIANT_NAME"
  if [[ -z "$image_name_ref" ]]; then
    if buildah images --format '{{.Name}}:{{.Tag}}' "localhost/chunked-img:${VARIANT_NAME}" >/dev/null 2>&1; then
      image_name_ref="chunked-img"
    elif buildah images --format '{{.Name}}:{{.Tag}}' "localhost/raw-img:${VARIANT_NAME}" >/dev/null 2>&1; then
      image_name_ref="raw-img"
    else
      echo "ERROR: neither localhost/chunked-img:${VARIANT_NAME} nor localhost/raw-img:${VARIANT_NAME} exists; run 'just pipeline' first" >&2
      return 1
    fi
  fi

  echo "=== Relabel existing localhost/${image_name_ref}:${anchor_tag} ===" >&2

  manifest_file="/tmp/bazzite-nix-manifest.json"
  labels_file="/tmp/bazzite-nix-labels.txt"
  unset GITHUB_OUTPUT
  eval "$(extract_image_info "$manifest_file" "localhost/${image_name_ref}:${anchor_tag}")"
  assemble_labels \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$image_desc" "$VARIANT_NAME" "$CANONICAL_TAG" \
    "$repo_organization" "$image_name" "$KERNEL_VERSION" \
    "$manifest_file" "$labels_file"
  relabel_image "$labels_file" "$KERNEL_VERSION" "$image_name_ref" "$anchor_tag"
  eval "$(extract_final_ref "$anchor_tag" "$image_name_ref")"

  # Human summary goes to stderr; stdout carries the eval-able assignments so
  # run_pipeline can capture them (mirrors build_variant_core's contract).
  [[ "$quiet" != "1" ]] && print_build_summary "Relabel complete"
  echo_build_assignments
}

# Run the full build pipeline for a single variant:
#   build → extract image info → assemble labels → [relabel] → [rechunk] → extract final ref
# Rechunk is disabled by default; pass rechunk=1 to enable.
run_pipeline() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:-bazzite-nix}"
  local image_desc="${4:-Customized Bazzite image with Nix mount support and other sugar}"
  local repo_organization="${5:?repo_organization required}"
  local base_image_override="${6:-}"
  local force_rebuild="${7:-0}"
  local rechunk="${8:-0}"
  # shellcheck disable=SC2034
  local TARGET_IMAGE="" TAG="" BASE_IMAGE="" BUILD_SCRIPT="" VARIANT_NAME="" CANONICAL_TAG="" TAGS=""
  local KERNEL_VERSION="" MANIFEST_PACKAGES="" SOURCE_REF="" FULL_BUILD_DIGEST="" BUILD_DIGEST=""

  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name" "$force_rebuild")"
  [[ -n "$base_image_override" ]] && BASE_IMAGE="$base_image_override"

  # Preview which alias tags this build will generate (mirrors the workflow's Preview step)
  preview_tags "$variant_or_spec" "$variants_config" "$image_name" "$repo_organization"

  # Phase 1: Build container image (skip if exists and not forcing)
  echo "=== Step 1: Build container image ==="
  build_image_or_skip "$BASE_IMAGE" "$BUILD_SCRIPT" "$CANONICAL_TAG" "$VARIANT_NAME" "$force_rebuild"

  # Phases 2-4: extract → assemble labels → [relabel] → [rechunk] → final ref (shared core).
  # Rechunk routes through run_rechunk (always rechunks, labels applied by chunkah);
  # relabel routes through run_relabel (always relabels) so the pipeline shares the
  # standalone entry points; the skip-if-chunked-exists guard remains for CI.
  # build_variant_core emits [n/N] step logs for each phase.
  local core_output
  if [[ "$rechunk" == "1" ]]; then
    core_output="$(run_rechunk "$variant_or_spec" "$variants_config" "$image_name" "$image_desc" "$repo_organization" "$force_rebuild" "1")" || return $?
  else
    core_output="$(run_relabel "$variant_or_spec" "$variants_config" "$image_name" "$image_desc" "$repo_organization" "raw-img" "1")" || return $?
  fi
  eval "$core_output"

  print_build_summary "Pipeline complete"
}

# ── CI parity (mirrors the old build-reusable / push-reusable / release-reusable actions) ──

# Build a single variant from pre-resolved values (the CI matrix), mirroring the
# old build-reusable action. No re-resolution — preserves matrix collision handling.
# Usage: build_variant_ci <variant> <base_image> <build_script> <canonical_tag> \
#                         <date> <image_desc> <parent_version> [repo_owner] [repo_name] [rechunk]
# rechunk=1 enables chunkah chunking (build.yml passes 1).
# Writes to $GITHUB_OUTPUT (source_ref, full_build_digest, build_digest, kernel_version,
# manifest_packages) when set.
build_variant_ci() {
  local variant="${1:?variant required}"
  local base_image="${2:?base_image required}"
  local build_script="${3:-build.sh}"
  local canonical_tag="${4:?canonical_tag required}"
  local date="${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  local image_desc="${6:-}"
  local parent_version="${7:-}"
  local repo_owner="${8:-}"
  local repo_name="${9:-}"
  local rechunk="${10:-0}"

  local KERNEL_VERSION="" MANIFEST_PACKAGES="" SOURCE_REF="" FULL_BUILD_DIGEST="" BUILD_DIGEST=""
  local gh_output="${GITHUB_OUTPUT:-}"

  echo "=== Step 1: Build container image ==="
  build_image "$base_image" "$build_script" "$canonical_tag" "$variant" "./Containerfile" "$variant"

  # build_variant_core unsets GITHUB_OUTPUT so extract_* emit uppercase vars we can eval
  eval "$(build_variant_core "$variant" "$date" "$image_desc" "$parent_version" "$repo_owner" "$repo_name" "0" "$rechunk")"

  if [[ -n "$gh_output" ]]; then
    {
      echo "source_ref=${SOURCE_REF}"
      echo "full_build_digest=${FULL_BUILD_DIGEST}"
      echo "build_digest=${BUILD_DIGEST}"
      echo "kernel_version=${KERNEL_VERSION}"
      echo "manifest_packages=${MANIFEST_PACKAGES}"
    } >>"$gh_output"
  fi
}

# Push, sign, and verify a built image (mirrors old push-reusable action).
# Usage: push_variant <source_ref> <tags_csv> <registry> <repo> <suffix> \
#                     <variant_name> <date> <parent_version> [cosign_pub]
# Env required: GITHUB_ACTOR, GITHUB_TOKEN, SIGNING_SECRET.
# Writes to $GITHUB_OUTPUT (remote_digest, remote_digest_ref, status) when set.
push_variant() {
  local source_ref="${1:?source_ref required}"
  local tags_csv="${2:?tags_csv required}"
  local registry="${3:?registry required}"
  local repo="${4:?repo required}"
  local suffix="${5:-}"
  local variant_name="${6:?variant_name required}"
  local date="${7:-}"
  local parent_version="${8:-}"
  local cosign_pub="${9:-cosign.pub}"

  : "${GITHUB_ACTOR:?GITHUB_ACTOR required}"
  : "${GITHUB_TOKEN:?GITHUB_TOKEN required}"
  if [[ -z "${SIGNING_SECRET:-}" ]]; then
    echo "::error::SIGNING_SECRET required for cosign signing" >&2
    return 1
  fi

  local authfile="/tmp/skopeo-auth/auth.json"
  local base_img="${registry}/${repo}${suffix}"
  local push_output sign_output remote_digest_ref

  export MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
  export RETRY_DELAY="${RETRY_DELAY:-15}"

  mkdir -p /tmp/skopeo-auth
  run_with_retry "skopeo login ghcr.io" \
    --stdin-data "${GITHUB_TOKEN}" \
    skopeo login ghcr.io \
    --username "${GITHUB_ACTOR}" \
    --password-stdin \
    --authfile "$authfile"

  push_output="$(push_image_with_tags "$source_ref" "$tags_csv" "$base_img")"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf '%s\n' "$push_output" >>"$GITHUB_OUTPUT"
  eval "$push_output"

  sign_output="$(sign_and_verify_image "$remote_digest_ref" "$cosign_pub" "$authfile" \
    "$GITHUB_ACTOR" "$GITHUB_TOKEN" "${GITHUB_STEP_SUMMARY:-}" \
    "$variant_name" "$tags_csv" "$date" "$parent_version" "$registry" "$repo" "$suffix")"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf '%s\n' "$sign_output" >>"$GITHUB_OUTPUT"
  eval "$sign_output"
}

# Generate a GitHub release for a variant (mirrors old release-reusable action).
# Usage: release_variant <variant> [handwritten] [variants_config] [allow_disabled] [registry] [repo] [dry_run]
# Auth: ambient gh session (gh auth login) or GH_TOKEN/GITHUB_TOKEN.
# Only publishes a release when the computed version tag isn't already released.
# dry_run=1 previews (WOULD CREATE / SKIP) without publishing anything.
# Requires a git checkout with recent history.
# Writes to $GITHUB_OUTPUT (title, tag) when set.
release_variant() {
  local variant="${1:?variant required}"
  local handwritten="${2:-}"
  local variants_config="${3:-.github/variants.json}"
  local allow_disabled="${4:-false}"
  local registry="${5:-}"
  local repo="${6:-}"
  local dry_run="${7:-0}"

  local owner found disabled target gh_repo
  owner="${GITHUB_REPOSITORY_OWNER:-${repo_organization:-}}"
  registry="${registry:-ghcr.io/${owner}}"
  registry="${registry,,}"
  gh_repo="${GITHUB_REPOSITORY:-}"
  repo="${repo:-${gh_repo#*/}}"
  repo="${repo,,}"

  found=$(jq -r --arg v "$variant" '.variants[] | select(.name == $v) | .name' "$variants_config")
  if [[ -z "$found" ]]; then
    echo "::error::Variant '${variant}' not found in variants.json. Available: $(jq -r '.variants[].name' "$variants_config" | paste -sd ', ' -)" >&2
    return 1
  fi
  if [[ "$allow_disabled" != "true" ]]; then
    disabled=$(jq -r --arg v "$variant" '.variants[] | select(.name == $v) | .disabled // false' "$variants_config")
    if [[ "$disabled" == "true" ]]; then
      echo "::error::Variant '${variant}' is disabled in variants.json" >&2
      return 1
    fi
  fi

  target="${variant##*/}"
  [[ "$target" == "main" ]] && target="stable"

  export IMAGE_PREFIX="${registry}/${repo}"
  [[ -z "${GITHUB_REPOSITORY:-}" ]] && export GITHUB_REPOSITORY="${owner}/${repo}"

  python3 scripts/changelog.py "$target" ./output.env ./changelog.md \
    --workdir . --handwritten "$handwritten" --variants-config "$variants_config"

  # shellcheck disable=SC1091
  source ./output.env

  # TITLE and TAG are assigned by the sourced output.env (written by changelog.py)
  # shellcheck disable=SC2153
  local gh_args=(-t "$TITLE" --notes-file ./changelog.md)
  if [[ "$target" == "stable" ]]; then
    gh_args+=(--latest)
  else
    gh_args+=(--prerelease)
  fi

  # Only publish a release for a version tag that isn't already documented.
  # changelog.py computes TAG as the newest version tag; gh release view tells
  # us whether that version already has a release (same gate for all variants).
  if gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    echo "::notice::Release for $TAG already exists — skipping" >&2
    return 0
  fi

  if [[ "$dry_run" == "1" ]]; then
    echo "WOULD CREATE release: $TAG"
    echo "  Title   : $TITLE"
    echo "  Latest  : $([[ "$target" == "stable" ]] && echo true || echo false)"
    echo "  Notes   : ./changelog.md"
    echo "  (dry run — nothing published)"
    return 0
  fi

  gh release create "$TAG" --repo "$GITHUB_REPOSITORY" "${gh_args[@]}"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "title=${TITLE}" >>"$GITHUB_OUTPUT"
    echo "tag=${TAG}" >>"$GITHUB_OUTPUT"
  fi
}

# Build all variants that need rebuilding (reads /tmp/variants_results.json)
build_all_variants() {
  local repo_organization="${1:?repo_organization required}"
  local image_name="${2:-bazzite-nix}"
  local image_desc="${3:-Customized Bazzite image with Nix mount support and other sugar}"
  local results_file variants count i variant base_image build_script canonical_tag tags_csv
  local KERNEL_VERSION MANIFEST_PACKAGES SOURCE_REF FULL_BUILD_DIGEST BUILD_DIGEST

  results_file="/tmp/variants_results.json"
  if [[ ! -f "$results_file" ]]; then
    echo "::error::No variant check results found. Run check-variants first." >&2
    return 1
  fi

  variants=$(jq -c '[.[] | select(.needs_build == true)]' "$results_file")
  count=$(echo "$variants" | jq 'length')
  if [[ "$count" -eq 0 ]]; then
    echo "No variants need building"
    return 0
  fi

  echo "Building $count variant(s)..."
  for ((i = 0; i < count; i++)); do
    variant=$(echo "$variants" | jq -r ".[$i].variant")
    base_image=$(echo "$variants" | jq -r ".[$i].base_image")
    build_script=$(echo "$variants" | jq -r ".[$i].build_script // \"build.sh\"")
    canonical_tag=$(echo "$variants" | jq -r ".[$i].canonical_tag")
    tags_csv=$(echo "$variants" | jq -r ".[$i].tags")

    echo ""
    echo "========================================"
    echo "Building variant: $variant"
    echo "  Base image    : $base_image"
    echo "  Build script  : $build_script"
    echo "  Canonical tag : $canonical_tag"
    echo "  Tags          : $tags_csv"
    echo "========================================"

    # Build container image (skip if exists)
    build_image_or_skip "$base_image" "$build_script" "$canonical_tag" "$variant"

    # Shared core: extract → labels → rechunk → final ref (anchored skip-check
    # chunked-img:<variant> matches CI semantics).
    eval "$(build_variant_core "$variant" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$image_desc" "$canonical_tag" "$repo_organization" "$image_name" "0" "1")"
    echo "Variant $variant complete: $SOURCE_REF ($BUILD_DIGEST)"
  done
}
