#!/usr/bin/env bash
# helpers.sh — shared functions for push, sign, verify, and the per-variant
# release entry points. Expects MAX_ATTEMPTS, RETRY_DELAY, GITHUB_ACTOR,
# GITHUB_TOKEN to be set in the calling environment.

set -euo pipefail

# ── error classification ────────────────────────────────────────────────────

is_transient_error() {
  local output="$1"
  grep -qiE \
    '502|503|504|429|connection reset|connection refused|EOF|i/o timeout|TLS|unexpected HTTP|context deadline|net/http' \
    <<<"$output"
}

# ── generic retry wrapper for arbitrary commands ────────────────────────────
# Usage: run_with_retry <label> [--stdin-data <data>] <cmd> [args...]
# Applies the same transient-error classification and exponential backoff.
# Command output is captured for classification and streamed to stderr.
#   --stdin-data <data>  Feed the string to the command's stdin (empty otherwise).

run_with_retry() {
  local label="$1"
  shift

  local stdin_data=""
  if [[ "${1:-}" == "--stdin-data" ]]; then
    stdin_data="$2"
    shift 2
  fi

  local cmd=("$@")

  local attempt output exit_code tmpfile stdin_file
  for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    echo "  ${label} (attempt ${attempt}/${MAX_ATTEMPTS})" >&2

    tmpfile=$(mktemp)
    stdin_file=$(mktemp)
    printf '%s' "$stdin_data" >"$stdin_file"
    set +e
    "${cmd[@]}" <"$stdin_file" 2>&1 | tee "$tmpfile" >&2
    exit_code=${PIPESTATUS[0]}
    set -e

    if [[ $exit_code -eq 0 ]]; then
      rm -f "$tmpfile" "$stdin_file"
      return 0
    fi

    output=$(<"$tmpfile")
    rm -f "$tmpfile" "$stdin_file"

    echo "  ✗ exited ${exit_code}: $(echo "$output" | tail -3)" >&2

    if is_transient_error "$output"; then
      if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
        echo "::error::All ${MAX_ATTEMPTS} attempts failed for: ${label}" >&2
        return 1
      fi
      local delay=$((RETRY_DELAY * attempt))
      echo "::warning::Transient error on attempt ${attempt}. Retrying in ${delay}s…" >&2
      sleep "$delay"
    else
      echo "::error::Permanent error — not retrying: ${label}" >&2
      echo "::error::Output: ${output}" >&2
      return 1
    fi
  done
}

# ── push image and additional tags ──────────────────────────────────────────
# Usage: push_image_with_tags <source_ref> <tags_csv> <base_img> <authfile>
# Writes to stderr (logs/groups); prints to stdout for $GITHUB_OUTPUT:
#   remote_digest=<digest>
#   remote_digest_ref=<ref>

push_image_with_tags() {
  local source_ref="$1" tags_csv="$2" base_img="$3" authfile="$4"

  local -a TAGS_ARR
  IFS=',' read -r -a TAGS_ARR <<<"$tags_csv"

  echo "::group::Push primary tag (${TAGS_ARR[0]})" >&2
  echo "Source ref : ${source_ref}" >&2
  echo "Target     : docker://${base_img}:${TAGS_ARR[0]}" >&2
  # podman push reads rootless containers-storage directly; the prefix strip
  # handles chunked-img/raw-img source refs alike. --digestfile keeps the digest
  # podman computed for the uploaded manifest, so no second registry round trip
  # and no window where another retag could move the primary tag.
  local digestfile
  digestfile=$(mktemp)
  run_with_retry "podman push docker://${base_img}:${TAGS_ARR[0]}" \
    podman push --authfile "$authfile" --digestfile "$digestfile" \
    "${source_ref#containers-storage:}" \
    "docker://${base_img}:${TAGS_ARR[0]}"

  local remote_digest
  remote_digest=$(<"$digestfile")
  rm -f "$digestfile"
  [[ -z "$remote_digest" ]] &&
    {
      echo "::error::podman push returned empty digest" >&2
      return 1
    }

  local short_digest="${remote_digest#sha256:}"
  local remote_digest_ref="${base_img}@${remote_digest}"
  echo "Digest     : ${remote_digest}" >&2
  echo "Digest ref : ${remote_digest_ref}" >&2
  echo "::endgroup::" >&2

  echo "::group::Apply additional tags" >&2
  local tag extra_tags
  extra_tags=("${TAGS_ARR[@]:1}")
  # {sha256} may already be in the tag list — don't tag the digest twice
  if ! printf '%s\n' "${TAGS_ARR[@]}" | grep -qx "$short_digest"; then
    extra_tags+=("$short_digest")
  fi
  for tag in "${extra_tags[@]}"; do
    echo "  → ${base_img}:${tag}" >&2
  done
  # One oras call for all tags: a manifest PUT per tag, applied concurrently,
  # so no blob existence checks and one auth handshake instead of one per tag.
  if ((${#extra_tags[@]} > 0)); then
    run_with_retry "oras tag ${remote_digest_ref} → ${extra_tags[*]}" \
      oras tag \
      --registry-config "$authfile" \
      "$remote_digest_ref" \
      "${extra_tags[@]}"
  fi
  echo "::endgroup::" >&2

  echo "remote_digest=${remote_digest}"
  echo "remote_digest_ref=${remote_digest_ref}"
}

# ── sign, verify, and inspect image ─────────────────────────────────────────
# Usage: sign_and_verify_image <record_json>
# Record fields: digest_ref, authfile (required); cosign_pub, variant, tags,
#                date, parent_version, base_img (optional, used in the summary).
# Reads GITHUB_ACTOR, GITHUB_TOKEN, SIGNING_SECRET from the environment.
# Writes to stderr (logs/groups) and $GITHUB_STEP_SUMMARY; prints to stdout:
#   status=success

sign_and_verify_image() {
  local record_json="${1:?record_json required}"

  local digest_ref cosign_pub authfile variant_name tags date parent_version base_img
  IFS=$'\037' read -r digest_ref cosign_pub authfile variant_name tags date parent_version base_img < <(
    jq -r '[.digest_ref, (.cosign_pub // "cosign.pub"), .authfile, (.variant // ""), (.tags // ""), (.date // ""), (.parent_version // ""), (.base_img // "")] | join("\u001f")' <<<"$record_json"
  )
  if [[ -z "$digest_ref" || -z "$authfile" ]]; then
    echo "::error::digest_ref and authfile are required sign fields" >&2
    return 1
  fi

  echo "::group::Sign image" >&2
  run_with_retry "cosign sign ${digest_ref}" \
    cosign sign -y \
    --key env://SIGNING_SECRET \
    --new-bundle-format=false \
    --use-signing-config=false \
    --registry-referrers-mode=legacy \
    --registry-username "${GITHUB_ACTOR}" \
    --registry-password "${GITHUB_TOKEN}" \
    "${digest_ref}"
  echo "::endgroup::" >&2

  echo "::group::Verify image" >&2
  run_with_retry "cosign verify ${digest_ref}" \
    cosign verify \
    --key "$cosign_pub" \
    "${digest_ref}"
  echo "::endgroup::" >&2

  echo "::group::Inspect layer sizes" >&2
  local total_mb
  total_mb=$(oras manifest fetch \
    --registry-config "${authfile}" \
    "${digest_ref}" |
    jq '([.layers[].size] | add) / 1024 / 1024 | round')
  echo "Total compressed size: ${total_mb} MB" >&2
  echo "::endgroup::" >&2

  local remote_digest="${digest_ref#*@sha256:}"
  local step_summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

  {
    echo "## ${variant_name}"
    echo ""
    echo "| Field | Value |"
    echo "| ----- | ----- |"
    echo "| **Image**             | \`${base_img}\` |"
    echo "| **Digest**            | \`${remote_digest}\` |"
    echo "| **Tags**              | \`${tags}\` |"
    echo "| **Parent version**    | \`${parent_version}\` |"
    echo "| **Built**             | \`${date}\` |"
    echo "| **Image size**        | \`${total_mb} MB\` |"
    echo "| **Signed & verified** | ✅ |"
  } >>"$step_summary"

  echo "status=success"
}

# ── local parity: push and release one variant ──────────────────────────────
# The local just recipes (push, release) drive these; build.yml drives its own
# steps, so the two files meet only through the records below.

# Push, sign, and verify a built image (mirrors old push-reusable action).
# Usage: push_variant <record_json> [options_json]
# Record fields read: source_ref, tags, suffix, variant, parent_version (the
# pipeline returned them). Options record: {"registry":..,"repo":..,"date":..,
# "cosign_pub":..} are the run fields the caller already has.
# Env required: GITHUB_ACTOR, GITHUB_TOKEN, SIGNING_SECRET.
# Writes to $GITHUB_OUTPUT (remote_digest, remote_digest_ref, status) when set.
push_variant() {
  local record_json="${1:?record_json required}"
  local options_json="${2:-}"

  local source_ref tags_csv suffix
  local registry repo date cosign_pub
  IFS=$'\037' read -r source_ref tags_csv suffix < <(jq -r '[.source_ref, .tags, (.suffix // "")] | join("\u001f")' <<<"$record_json")
  IFS=$'\037' read -r registry repo date cosign_pub < <(jq -r '[(.registry // ""), (.repo // ""), (.date // ""), (.cosign_pub // "cosign.pub")] | join("\u001f")' <<<"$options_json")
  if [[ -z "$registry" || -z "$repo" ]]; then
    echo "::error::registry and repo are required push fields" >&2
    return 1
  fi

  : "${GITHUB_ACTOR:?GITHUB_ACTOR required}"
  : "${GITHUB_TOKEN:?GITHUB_TOKEN required}"
  if [[ -z "${SIGNING_SECRET:-}" ]]; then
    echo "::error::SIGNING_SECRET required for cosign signing" >&2
    return 1
  fi

  local authfile="/tmp/skopeo-auth/auth.json"
  local base_img="${registry}/${repo}${suffix}"
  local push_output sign_json sign_output remote_digest_ref

  export MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
  export RETRY_DELAY="${RETRY_DELAY:-15}"

  mkdir -p /tmp/skopeo-auth
  run_with_retry "podman login ghcr.io" \
    --stdin-data "${GITHUB_TOKEN}" \
    podman login ghcr.io \
    --username "${GITHUB_ACTOR}" \
    --password-stdin \
    --authfile "$authfile"

  push_output="$(push_image_with_tags "$source_ref" "$tags_csv" "$base_img" "$authfile")"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf '%s\n' "$push_output" >>"$GITHUB_OUTPUT"
  eval "$push_output"

  sign_json="$(jq -cn \
    --arg digest_ref "$remote_digest_ref" --arg authfile "$authfile" --arg base_img "$base_img" \
    --arg tags "$tags_csv" --arg date "$date" --arg cosign_pub "$cosign_pub" \
    '. + {digest_ref: $digest_ref, authfile: $authfile, base_img: $base_img, cosign_pub: $cosign_pub, tags: $tags, date: $date}' \
    <<<"$record_json")"
  sign_output="$(sign_and_verify_image "$sign_json")"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf '%s\n' "$sign_output" >>"$GITHUB_OUTPUT"
  eval "$sign_output"
}

# Generate a GitHub release for a variant (mirrors old release-reusable action).
# Usage: release_variant <record_json> [options_json]
# Record fields read: variant, disabled (the caller resolved the record with
# variant_record). Options: {"handwritten":..,"variants_config":..,
# "allow_disabled":..,"registry":..,"repo":..,"dry_run":0|1}
# Auth: ambient gh session (gh auth login) or GH_TOKEN/GITHUB_TOKEN.
# Only publishes a release when the computed version tag isn't already released.
# dry_run=1 previews (WOULD CREATE / SKIP) without publishing anything.
# Requires a git checkout with recent history.
# Writes the changelog and its TITLE/TAG file under $ARTIFACTS_DIR/<variant>/.
# Writes to $GITHUB_OUTPUT (title, tag) when set.
release_variant() {
  local record_json="${1:?record_json required}"
  local options_json="${2:-}"

  local variant disabled
  IFS=$'\037' read -r variant disabled < <(jq -r '[.variant, (.disabled // false)] | join("\u001f")' <<<"$record_json")
  if [[ -z "$variant" ]]; then
    echo "::error::record has no variant field" >&2
    return 1
  fi

  local handwritten variants_config allow_disabled registry repo dry_run
  IFS=$'\037' read -r handwritten variants_config allow_disabled registry repo dry_run < <(jq -r '[(.handwritten // ""), (.variants_config // ".github/variants.json"), (.allow_disabled // "false"), (.registry // ""), (.repo // ""), (.dry_run // "0")] | join("\u001f")' <<<"$options_json")

  local owner
  owner="$(registry_owner)"
  registry="${registry:-$(registry_url "$owner")}"
  registry="${registry,,}"
  repo="${repo:-$(package_repo)}"

  if [[ "$allow_disabled" != "true" && "$disabled" == "true" ]]; then
    echo "::error::Variant '${variant}' is disabled in variants.json" >&2
    return 1
  fi

  local target
  target="${variant##*/}"
  [[ "$target" == "main" ]] && target="stable"

  export IMAGE_PREFIX="${registry}/${repo}"
  [[ -z "${GITHUB_REPOSITORY:-}" ]] && export GITHUB_REPOSITORY="${owner}/${repo}"

  local artifact_dir="$ARTIFACTS_DIR/$variant"
  mkdir -p "$artifact_dir"

  python3 scripts/changelog.py "$target" "$artifact_dir/output.env" "$artifact_dir/changelog.md" \
    --workdir . --handwritten "$handwritten" --variants-config "$variants_config" --package "$repo"

  # shellcheck disable=SC1091
  source "$artifact_dir/output.env"

  # TITLE and TAG are assigned by the sourced output.env (written by changelog.py)
  # shellcheck disable=SC2153
  local gh_args=(-t "$TITLE" --notes-file "$artifact_dir/changelog.md")
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
    echo "  Notes   : $artifact_dir/changelog.md"
    echo "  (dry run — nothing published)"
    return 0
  fi

  gh release create "$TAG" --repo "$GITHUB_REPOSITORY" "${gh_args[@]}"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "title=${TITLE}" >>"$GITHUB_OUTPUT"
    echo "tag=${TAG}" >>"$GITHUB_OUTPUT"
  fi
}
