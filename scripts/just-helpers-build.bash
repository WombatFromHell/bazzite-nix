# just-helpers-build.bash — build pipeline, CI parity, and build-all functions.
# Sourced by just-helpers.bash (no shebang/set — see umbrella).

# The release description every build labels with, unless a caller overrides it.
DEFAULT_IMAGE_DESC="Customized Bazzite image with Nix mount support and other sugar"

# The five fields a build adds to its variant record: lowercase in the record,
# uppercase in the shell. One list feeds the reader and the writer.
BUILD_FIELDS=(kernel_version manifest_packages source_ref full_build_digest build_digest)

# ── Build pipeline functions ────────────────────────────────────────────────

# Build a container image (stages to localhost/raw-img)
run_build() {
  local variant_or_spec="${1:?variant_or_spec required}"
  local variants_config="${2:-.github/variants.json}"
  local image_name="${3:?image_name required}"
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

# Eval-able build refs (the stdout contract of run_rechunk / run_relabel)
echo_build_assignments() {
  local field name
  echo "VARIANT_NAME=${VARIANT_NAME}"
  for field in "${BUILD_FIELDS[@]}"; do
    name="${field^^}"
    echo "$name=${!name}"
  done
}

# Compose the pipeline record from the assignments resolve_variant exported.
# Usage: resolved_variant_record_json <repo_owner> <repo_name> [image_desc]
resolved_variant_record_json() {
  local repo_owner="${1:?repo_owner required}"
  local repo_name="${2:?repo_name required}"
  local image_desc="${3:-$DEFAULT_IMAGE_DESC}"
  jq -cn \
    --arg variant "$VARIANT_NAME" \
    --arg base_image "$BASE_IMAGE" \
    --arg build_script "$BUILD_SCRIPT" \
    --arg canonical_tag "$CANONICAL_TAG" \
    --arg version_label "$CANONICAL_TAG" \
    --arg tags "$TAGS" \
    --arg collision_detected "$COLLISION_DETECTED" \
    --arg repo_owner "$repo_owner" \
    --arg repo_name "$repo_name" \
    --arg image_desc "$image_desc" \
    '{
      variant: $variant,
      base_image: $base_image,
      build_script: $build_script,
      canonical_tag: $canonical_tag,
      version_label: $version_label,
      tags: $tags,
      collision_detected: ($collision_detected == "true"),
      repo_owner: $repo_owner,
      repo_name: $repo_name,
      image_desc: $image_desc
    }'
}

# Load a returned record's build fields into the vars print_build_summary reads.
# Usage: apply_build_record <record_json>
apply_build_record() {
  local record_json="${1:?record_json required}"
  local field
  for field in "${BUILD_FIELDS[@]}"; do
    printf -v "${field^^}" '%s' "$(jq -r --arg f "$field" '.[$f] // ""' <<<"$record_json")"
  done
}

_step() {
  _step_n=$((_step_n + 1))
  echo "=== Step ${_step_n}: $1 ===" >&2
}

# Build the run-fields record the variant entry points read, from key=value
# pairs, so a just recipe only lists the fields it actually passes.
# Usage: run_fields [key=value...]
run_fields() {
  jq -cn 'reduce ($ARGS.positional[]) as $p ({}; ($p | split("=")) as $parts | . + {($parts[0]): ($parts[1:] | join("="))})' --args "$@"
}

# The one build sequence: extract info → assemble labels → relabel →
# [rechunk] → extract final ref. Every caller hands it the variant record, so a
# new variants.json field needs no change here or at any call site.
#
# Usage: build_variant_pipeline <record_json> [options_json]
# Options record: {"build":"always|skip|none","rechunk":0|1,"force_rebuild":0|1,
#                  "image_name_ref":"raw-img|chunked-img","extract_ref":"<image ref>"}
# Record fields read: variant, version_label, repo_owner, repo_name (required),
#                     date, image_desc, base_image, build_script, canonical_tag.
# PRECONDITION: localhost/raw-img exists (built by the caller) and build-helpers.bash
# is sourced ($JUST_HELPERS_BUILD).
# Prints the input record with source_ref, full_build_digest, build_digest,
# kernel_version, and manifest_packages added.
build_variant_pipeline() {
  local record_json="${1:?record_json required}"
  local options_json="${2:-}"
  [[ -n "$options_json" ]] || options_json='{}'

  local fields
  if ! fields=$(jq -r '
      . as $record
      | (["variant","version_label","repo_owner","repo_name"]
          | map(select(($record[.] // "") == ""))) as $missing
      | if ($missing | length) > 0
        then "MISSING:" + ($missing | join(" "))
        else [$record.variant, $record.version_label, $record.repo_owner, $record.repo_name,
              ($record.date // ""), ($record.image_desc // ""),
              ($record.base_image // ""), ($record.build_script // ""), ($record.canonical_tag // "")] | join("\u001f")
        end
    ' <<<"$record_json"); then
    echo "ERROR: variant record is not valid JSON" >&2
    return 1
  fi
  if [[ "$fields" == MISSING:* ]]; then
    echo "ERROR: variant record missing required field(s): ${fields#MISSING:}" >&2
    return 1
  fi

  local variant version_label repo_owner repo_name date image_desc base_image build_script canonical_tag
  IFS=$'\037' read -r variant version_label repo_owner repo_name date image_desc base_image build_script canonical_tag <<<"$fields"
  [[ -n "$date" ]] || date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ -n "$image_desc" ]] || image_desc="$DEFAULT_IMAGE_DESC"
  local rechunk force_rebuild build image_name_ref extract_ref
  IFS=$'\037' read -r rechunk force_rebuild build image_name_ref extract_ref < <(jq -r '[(.rechunk // "0"), (.force_rebuild // "0"), (.build // "skip"), (.image_name_ref // ""), (.extract_ref // "")] | join("\u001f")' <<<"$options_json")
  mkdir -p "$ARTIFACTS_DIR/$variant"
  local manifest_file="$ARTIFACTS_DIR/$variant/manifest.json"
  local labels_file="$ARTIFACTS_DIR/$variant/labels.txt"
  local VARIANT_NAME="$variant"
  local KERNEL_VERSION="" MANIFEST_PACKAGES="" SOURCE_REF="" FULL_BUILD_DIGEST="" BUILD_DIGEST=""
  local anchor_tag revision
  local _step_n=0

  # Anchor on the variant name so different variant pipelines never clobber
  # each other's working images (raw-img:<variant> / chunked-img:<variant>).
  anchor_tag="$variant"

  # This function's stdout is the record alone: build_variant_ci captures it
  # into $GITHUB_OUTPUT, which reads one key=value line. buildah build prints
  # its STEP lines and the new digest on stdout, so the build step is sent to
  # stderr here, not inside build_image, so just build still shows progress.
  case "$build" in
  always)
    _step "Build container image"
    build_image "$base_image" "$build_script" "$canonical_tag" "$variant" "./Containerfile" "$variant" 1>&2
    ;;
  skip)
    _step "Build container image (skip if present)"
    build_image_or_skip "$base_image" "$build_script" "$canonical_tag" "$variant" "$force_rebuild" 1>&2
    ;;
  none) ;;
  *)
    echo "ERROR: unknown build mode: $build" >&2
    return 1
    ;;
  esac

  if [[ -z "$image_name_ref" ]]; then
    if [[ "$rechunk" == "1" ]]; then
      image_name_ref="chunked-img"
    else
      image_name_ref="raw-img"
    fi
  fi
  [[ -n "$extract_ref" ]] || extract_ref="$(image_ref raw-img)"

  _step "Extract image info (kernel + manifest)"
  eval "$(extract_image_info "$manifest_file" "$extract_ref")"

  # Skip relabel & rechunk only when a prior rechunked image already exists
  # (raw-img always exists after the build phase, so it's always relabeled).
  if [[ "$rechunk" == "1" && "$force_rebuild" != "1" ]] && buildah images --format '{{.Name}}:{{.Tag}}' "$(image_ref chunked-img "$anchor_tag")" >/dev/null 2>&1; then
    _step "skipping relabel & rechunk: $(image_ref chunked-img "$anchor_tag") already exists"
  else
    _step "Assemble image labels"
    # Preserve the base image's revision label (inherited by raw-img) before
    # relabel wipes every label.
    revision=$(podman inspect "$extract_ref" 2>/dev/null | jq -r '.[0].Labels["org.opencontainers.image.revision"] // ""' 2>/dev/null || true)
    assemble_labels \
      "$date" "$image_desc" "$variant" "$version_label" \
      "$repo_owner" "$repo_name" "$KERNEL_VERSION" \
      "$manifest_file" "$labels_file" "$revision"
    if [[ "$rechunk" == "1" ]]; then
      _step "Rechunk image (chunkah)"
      # chunkah applies the labels at chunk time (--label), so no separate
      # relabel pass is needed after rechunking.
      rechunk_image "$anchor_tag" "$labels_file" "$variant"
    else
      _step "Relabel image (raw-img)"
      relabel_image "$labels_file" "$KERNEL_VERSION" "$image_name_ref" "$anchor_tag"
    fi
  fi

  _step "Extract final image ref"
  eval "$(extract_final_ref "$anchor_tag" "$image_name_ref")"

  jq -c \
    --arg source_ref "$SOURCE_REF" \
    --arg full_build_digest "$FULL_BUILD_DIGEST" \
    --arg build_digest "$BUILD_DIGEST" \
    --arg kernel_version "$KERNEL_VERSION" \
    --arg manifest_packages "$MANIFEST_PACKAGES" \
    '. + {
      source_ref: $source_ref,
      full_build_digest: $full_build_digest,
      build_digest: $build_digest,
      kernel_version: $kernel_version,
      manifest_packages: $manifest_packages
    }' \
    <<<"$record_json"
}

# One variant entry point behind the three just recipes. It resolves the variant,
# makes sure its working image exists, runs build_variant_pipeline, then prints
# the human summary (stderr) and the eval-able assignments (stdout). Only the
# options record and the entry checks differ per mode:
#   rechunk  builds nothing and always rechunks raw-img
#   relabel  re-applies labels to an existing image (chunked-img, else raw-img)
#   pipeline builds, then rechunks only when rechunk:1 is passed
# Usage: run_variant <rechunk|relabel|pipeline> <variant_or_spec> [run_fields_json]
# Run fields: {"variants_config":..,"image_name":..,"image_desc":..,
#              "repo_organization":..,"image_name_ref":raw-img|chunked-img,
#              "base_image_override":..,"force_rebuild":0|1,"rechunk":0|1,
#              "quiet":0|1}
# Prints eval-able uppercase assignments (KERNEL_VERSION, MANIFEST_PACKAGES,
# SOURCE_REF, FULL_BUILD_DIGEST, BUILD_DIGEST) for rechunk and relabel.
run_variant() {
  local mode="${1:?mode required}"
  local variant_or_spec="${2:?variant_or_spec required}"
  local run_fields="${3:-}"

  local variants_config image_name image_desc repo_organization image_name_ref base_image_override force_rebuild rechunk quiet
  IFS=$'\037' read -r variants_config image_name image_desc repo_organization image_name_ref base_image_override force_rebuild rechunk quiet < <(jq -r '[(.variants_config // ".github/variants.json"), (.image_name // ""), (.image_desc // ""), (.repo_organization // ""), (.image_name_ref // ""), (.base_image_override // ""), (.force_rebuild // "0"), (.rechunk // "0"), (.quiet // "0")] | join("\u001f")' <<<"$run_fields")
  case "$mode" in
  rechunk | relabel | pipeline) ;;
  *)
    echo "ERROR: mode must be rechunk, relabel, or pipeline" >&2
    return 1
    ;;
  esac
  if [[ -z "$image_name" || -z "$repo_organization" ]]; then
    echo "ERROR: image_name and repo_organization are required run fields" >&2
    return 1
  fi
  [[ -n "$image_desc" ]] || image_desc="$DEFAULT_IMAGE_DESC"

  # shellcheck disable=SC2034
  local TARGET_IMAGE="" TAG="" BASE_IMAGE="" BUILD_SCRIPT="" VARIANT_NAME="" CANONICAL_TAG="" TAGS=""
  local KERNEL_VERSION="" MANIFEST_PACKAGES="" SOURCE_REF="" FULL_BUILD_DIGEST="" BUILD_DIGEST=""
  local anchor_tag options_json record_json built

  eval "$(resolve_variant "$variant_or_spec" "$variants_config" "$image_name" "$force_rebuild")"
  [[ -n "$base_image_override" ]] && BASE_IMAGE="$base_image_override"

  # Anchor on the variant name so different variant pipelines never clobber
  # each other's working images (raw-img:<variant> / chunked-img:<variant>).
  anchor_tag="$VARIANT_NAME"

  if [[ "$mode" == "rechunk" ]] && ! buildah images --format '{{.Name}}' raw-img >/dev/null 2>&1; then
    echo "ERROR: Base image '$(image_ref raw-img)' not found. Run build step first." >&2
    return 1
  fi

  if [[ "$mode" == "relabel" && -z "$image_name_ref" ]]; then
    if buildah images --format '{{.Name}}:{{.Tag}}' "$(image_ref chunked-img "$VARIANT_NAME")" >/dev/null 2>&1; then
      image_name_ref="chunked-img"
    elif buildah images --format '{{.Name}}:{{.Tag}}' "$(image_ref raw-img "$VARIANT_NAME")" >/dev/null 2>&1; then
      image_name_ref="raw-img"
    else
      echo "ERROR: neither $(image_ref chunked-img "$VARIANT_NAME") nor $(image_ref raw-img "$VARIANT_NAME") exists; run 'just pipeline' first" >&2
      return 1
    fi
  fi
  if [[ "$mode" == "relabel" ]]; then
    echo "=== Relabel existing $(image_ref "$image_name_ref" "$anchor_tag") ===" >&2
  fi
  if [[ "$mode" == "pipeline" ]]; then
    # Preview which alias tags this build will generate (mirrors the workflow's Preview step)
    preview_tags "$variant_or_spec" "$variants_config" "$image_name" "$repo_organization"
  fi

  case "$mode" in
  rechunk)
    # Always rechunks, so never take the skip-if-chunked-exists path.
    options_json='{"rechunk":1,"force_rebuild":1,"build":"none"}'
    ;;
  relabel)
    options_json=$(jq -cn --arg image_name_ref "$image_name_ref" \
      --arg extract_ref "$(image_ref "$image_name_ref" "$anchor_tag")" \
      '{build: "none", rechunk: 0, image_name_ref: $image_name_ref, extract_ref: $extract_ref}')
    ;;
  pipeline)
    if [[ "$rechunk" == "1" ]]; then
      force_rebuild="1"
    fi
    options_json=$(jq -cn --arg rechunk "$rechunk" --arg force_rebuild "$force_rebuild" '{rechunk: $rechunk, force_rebuild: $force_rebuild, build: "skip"}')
    ;;
  esac

  record_json=$(resolved_variant_record_json "$repo_organization" "$image_name" "$image_desc")
  built=$(build_variant_pipeline "$record_json" "$options_json") || return $?
  apply_build_record "$built"

  if [[ "$quiet" != "1" ]]; then
    print_build_summary "${mode^} complete"
  fi
  if [[ "$mode" != "pipeline" ]]; then
    echo_build_assignments
  fi
}

# The three just-recipe entry points differ only in mode.
# Usage: run_rechunk <variant_or_spec> [run_fields_json]
# Usage: run_relabel <variant_or_spec> [run_fields_json]
# Usage: run_pipeline <variant_or_spec> [run_fields_json]
run_rechunk() {
  run_variant rechunk "$@"
}

run_relabel() {
  run_variant relabel "$@"
}

run_pipeline() {
  run_variant pipeline "$@"
}

# ── CI parity (mirrors the old build-reusable / push-reusable / release-reusable actions) ──

# Build a single variant from pre-resolved values (the CI matrix), mirroring the
# old build-reusable action. No re-resolution — preserves matrix collision handling.
# Usage: build_variant_ci <record_json> [options_json]
# The record comes from the CI matrix (see the schema in .pi/PLAN.md); its version_label
# is parent_version, the upstream version the labels carry. options_json carries
# {"rechunk":0|1} (build.yml passes 1).
# Writes record=<updated record> to $GITHUB_OUTPUT when set.
build_variant_ci() {
  local record_json="${1:?record_json required}"
  local options_json="${2:-}"
  local gh_output="${GITHUB_OUTPUT:-}"

  [[ -n "$options_json" ]] || options_json='{}'
  options_json=$(jq -cn --argjson options "$options_json" '$options + {build: "always"}')

  local built
  built=$(build_variant_pipeline "$record_json" "$options_json") || return $?

  if [[ -n "$gh_output" ]]; then
    echo "record=${built}" >>"$gh_output"
  fi
}

# Build all variants that need rebuilding (reads $ARTIFACTS_DIR/variants_results.json)
build_all_variants() {
  local repo_organization="${1:?repo_organization required}"
  local image_name="${2:?image_name required}"
  local image_desc="${3:-$DEFAULT_IMAGE_DESC}"
  local results_file variants count i record_json built

  results_file="$ARTIFACTS_DIR/variants_results.json"
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
    record_json=$(echo "$variants" | jq -c --arg repo_owner "$repo_organization" --arg repo_name "$image_name" --arg image_desc "$image_desc" \
      '.[$i] + {repo_owner: $repo_owner, repo_name: $repo_name, image_desc: $image_desc, version_label: .canonical_tag}')

    built=$(build_variant_pipeline "$record_json" '{"rechunk":1,"force_rebuild":0,"build":"skip"}') || return $?
    echo "Variant $(jq -r '.variant' <<<"$built") complete: $(jq -r '.source_ref' <<<"$built") ($(jq -r '.build_digest' <<<"$built"))"
  done
}
