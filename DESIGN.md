# DESIGN.md - CI, script, and Justfile layers

Current state, not a proposal. Scope: `.github/workflows/*`, `scripts/*`,
`Justfile`, `.github/variants.json`. Out of scope: `Containerfile`,
`build_files/*`, `flake.nix`, `iso.toml`, `image.toml` (the image-build layer
below this one). `docs/adr/` is superseded by section 6; this file stands alone.
Pointers are `file:line` as the tree stands.

## Contents

1. [Layers](#1-layers)
2. [Entry points](#2-entry-points)
3. [Function map](#3-function-map)
4. [Data channels](#4-data-channels)
5. [Record shapes](#5-record-shapes)
6. [Decisions](#6-decisions)
7. [Tests](#7-tests)
8. [Open](#8-open)

---

## 1. Layers

```text
build.yml   cleanup.yml   generate_release.yml          Justfile (30 recipes)
      \          |          /                                 |
       scripts/just-helpers.bash  <--------------------------+
                        |
   check-variants-registry.bash   registry probes, package identity
   check-variants-tags.bash       tag math, variant resolution
   build-helpers.bash             buildah stage
   push-helpers.bash              podman push, oras tag, cosign sign
   just-helpers-build.bash        the one pipeline, CI entrypoints
   just-helpers-variants.bash     aggregation, release selection
   just-helpers-{clean,tooling,vm}.bash   local only, unreachable from CI
```

Four facts hold the layers together.

- One currency. A JSON variant record travels the whole path. Every entrypoint
  is `<record_json> [options_json]`; nothing re-lists fields by position.
- One mode boundary. `build_variant_ci`, `push_variant`, `release_variant` own
  `GITHUB_OUTPUT`. The core never reads it.
- One artifact home. `ARTIFACTS_DIR` (`.artifacts`) declared once at
  `scripts/just-helpers.bash:38`, cleared at every run start by
  `scripts/check-variants.sh:51`.
- One package identity. The repository name is the package; the owner,
  lowercased, is the registry namespace.

## 2. Entry points

### 2.1 Workflows

| File                   | Triggers                                                                                | Job chain                                                                                                   |
| ---------------------- | --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `build.yml`            | cron `0 0 * * 0`;      dispatch `force_build`, `generate_release`, `variants_override` | `check_and_aggregate` -> `build_push` (matrix) -> `collect_release_variants` -> `generate_release` (matrix) |
| `cleanup.yml`          | cron `0 0 * * 0`;      dispatch `dry_run`, `package_filter`                             | `prepare` -> `cleanup-images` (matrix)                                                                      |
| `generate_release.yml` | dispatch `variants`, `handwritten`                                                      | `resolve-variants` -> `generate-release` (matrix)                                                           |

| Job                        | Calls                                                                                                                                                                        |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `check_and_aggregate`      | `registry_url` `build.yml:55`, `package_repo` `:56`; `bash scripts/check-variants.sh` `:72`; `aggregate_variants` `:73`; `preview_tags` `:81` (gated on `any_builds_needed`) |
| `build_push`               | `just ci-pipeline "$RECORD" '{"rechunk":1}'` `:117`; cosign-installer `:120`; oras `:123`; `just push "$RECORD" "$OPTIONS"` `:140`                                                        |
| `collect_release_variants` | `release_matrix_json <built csv> <config>` `:157`                                                                                                                            |
| `generate_release`         | `just release <variant> "" <config> true` `:195`                                                                                                                             |
| `prepare`                  | inline `jq` over `variants.json`, `BASE="${GITHUB_REPOSITORY#*/}"`, staged through `/tmp/all_packages.txt` and `/tmp/packages.txt` `cleanup.yml:31-51`                       |
| `cleanup-images`           | `dataaxiom/ghcr-cleanup-action@v1` `cleanup.yml:71`                                                                                                                          |
| `resolve-variants`         | `release_matrix_json <csv> <config>` `generate_release.yml:35`                                                                                                               |
| `generate-release`         | `just release <variant> <handwritten> <config> true` `generate_release.yml:67`                                                                                               |

Gates and permissions:

- `build_push` and `collect_release_variants` run only when `any_builds_needed`
  is true. `generate_release` runs when its matrix is non-empty and
  (`generate_release` input is true, or the run is scheduled).
- Top level: `contents: read`, `packages: write`. `build_push` repeats them.
  `generate_release` takes `contents: write` only.
- `cleanup.yml` `DRY_RUN` is a GitHub expression, not a shell value: scheduled
  runs delete, manual runs honour `dry_run`.
- Cleanup policy: `older-than: 3 months`, `keep-n-tagged: 78`,
  `delete-untagged/partial/orphaned: true`.
- Both release jobs use the same concurrency group (`generate-release-<variant>`,
  no `<ref>`: `github.ref` is empty on scheduled runs, so a ref-suffixed group
  split the scheduled and manual runs apart). They wait for each other
  (`cancel-in-progress: false`) instead of racing on the same release.

### 2.2 Justfile (30 recipes)

| Group           | Recipe:line -> function                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Just            | `check:24` check_just_files; `fix:31` fix_just_files                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Utility         | `default:19` just --list; `clean:38` clean_oci_layout + remove_images_and_prune; `cleaner:46` clean_artifacts + remove_images_and_prune; `clean-vm:59` clean_vm_cache; `lint:66` lint_scripts; `format:74` format_scripts; `test:82` bats + pytest; `list-variants:240` list_available_variants                                                                                                                                                                                        |
| Build container | `build:95` run_build; `rebuild:104` build 1; `rechunk:112` run_rechunk; `rootful-load:127` resolve_variant + podman save/load; `relabel:137` run_variant relabel; `pipeline:154` run_variant pipeline; `pipeline-rechunk:170` run_variant pipeline 1; `build-all:181` check_variants + build_all_variants; `release-preview:198` release_preview; `ci-pipeline:210` build_variant_ci; `push:219` push_variant; `release:229` release_variant; `check-variants:250` check_variants; `tags-preview:258` preview_tags |
| VM              | `build-qcow2:268` build_vm_image; `build-raw:279` build_vm_image; `rebuild-qcow2:288` build-qcow2 1; `rebuild-raw:293` build-raw 1; `run-vm-qcow2:300` run_variant_vm; `run-vm-raw:311` run_variant_vm                                                                                                                                                                                                                                                                                    |                                                                                                                                                                                                                                                                                 |

Shell flags are set once at `Justfile:2`. 24 of the 30 recipes carry the
`#!/usr/bin/env bash` + `source "{{ just_helpers }}"` preamble; the other 6
delegate to another recipe (`default`, `test`, `rebuild`, `pipeline-rechunk`,
`rebuild-qcow2`, `rebuild-raw`). The preamble is needed because this `just`
(1.57.0) runs each recipe line in its own process.

`ci-pipeline` and `push` take JSON on the command line. `release` still takes a
variant name; the Justfile turns it into a record with `variant_record`.

### 2.3 Script entrypoints

| File                                | Contract                                                                                                                                                                                                                                                   |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/check-variants.sh`         | env in: `REGISTRY`, `REPO`, `FORCE_BUILD`, `IMAGE_DESC`, `DATE`, `VARIANTS_CONFIG`, `VARIANTS_OVERRIDE`, `ARTIFACTS_DIR`. Out: `$ARTIFACTS_DIR/variants_results.json`. Clears that directory first (`:51`). Emits `::` log directives                      |
| `scripts/changelog.py`              | `target output changelog --package --variants-config [--pretty --workdir --handwritten]`; `--package` and `--variants-config` required (`:557`, `:562`); reads `IMAGE_PREFIX` for the registry half (`:15`); a variant whose newest version tag is its only one gets a first-release body with no diff tables; writes the two files where the caller pointed |
| `scripts/release-preview.py`        | `image_ref [--prev]`; reads a local image with podman, a registry ref with skopeo                                                                                                                                                                          |
| `*.bats`, `tests/test_changelog.py` | run by `just test`                                                                                                                                                                                                                                         |

## 3. Function map

`scripts/just-helpers.bash` - umbrella. Declares `JUST_HELPERS_BUILD` (`:29`),
`JUST_HELPERS_PUSH` (`:32`), guards and exports `ARTIFACTS_DIR` (`:38-43`),
sources the two check parts (`:46`, `:48`), build, push, then the five
`just-helpers-*` parts in a loop (`:55-57`).

| File                           | Functions                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `check-variants-registry.bash` | `registry_url:11` owner -> `ghcr.io/<owner>`; `registry_owner:18` CI owner or Justfile default; `package_repo:26` lowercase repo name; `variant_record:37` the one variant lookup, fails listing enabled names; `variant_names:51`; `enabled_variant_names:55`; `read_registry_json:67` the one retry loop; `inspect_image_with_retry:91`; `image_exists:100`; `get_parent_version:110`; `find_latest_versioned_tag:127`; `version_check:157`; `check_build_needed:181` |
| `check-variants-tags.bash`     | `extract_image_metadata:9`; `compute_canonical_tag:32` version-collision handling; `tag_needs_digest:96`; `generate_tags:106` `{canonical} {branch} {major} {sha256}`; `resolve_variant:150`                                                                                                                                                                                                                              |
| `build-helpers.bash`           | `CACHE_DIR:9`; `image_ref:19` the one spelling of a local ref; `image_digest:26`; `image_tag:32`; `sudo_cache:39`; `build_image:49`; `build_image_or_skip:67`; `extract_image_info:89`; `assemble_labels:136`; `relabel_image:174`; `rechunk_image:218`; `extract_final_ref:306`                                                                                                                                          |
| `push-helpers.bash`            | `is_transient_error:10`; `run_with_retry:23`; `push_image_with_tags:79`; `sign_and_verify_image:147`; `push_variant:218`; `release_variant:278`                                                                                                                                                                                                                                                                          |
| `just-helpers-build.bash`      | `run_build:14`; `print_build_summary:27`; `echo_build_assignments:42`; `resolved_variant_record_json:53` the CI matrix producer; `apply_build_record:84`; `_step:92`; `run_fields:100` the run-fields record; `build_variant_pipeline:117` the one sequence; `run_variant:249` rechunk/relabel/pipeline modes (thin `run_rechunk:338`, `run_relabel:342`, `run_pipeline:346`); `build_variant_ci:359`; `build_all_variants:376`    |
| `just-helpers-variants.bash`   | `preview_tags:8`; `check_variants:53`; `aggregate_variants:84`; `generate_step_summary:123`; `pushed_variants:175`; `resolve_release_variants:193`; `release_matrix_json:212`; `release_preview:229`                                                                                                                                                                                                                      |
| `just-helpers-clean.bash`      | `clean_artifacts:7`; `remove_images_and_prune:21`; `clean_oci_layout:57`; `clean_vm_cache:66`                                                                                                                                                                                                                                                                                                                             |
| `just-helpers-tooling.bash`    | `check_just_files:9`; `fix_just_files:21`; `lint_scripts:33`; `format_scripts:41`; `list_available_variants:50`                                                                                                                                                                                                                                                                                                           |
| `just-helpers-vm.bash`         | `disk_file_name:10`; `ensure_vm_images:21`; `_build_bib:30`; `build_bib:104`; `variant_chunked_layout:151`; `export_and_build_bib:163`; `vm_record_json:181`; `build_vm_image:197`; `run_vm:244`; `run_variant_vm:348`                                                                                                                                                                                                    |

Reachability: `clean`, `tooling`, and `vm` appear in no workflow. `just build`,
`just pipeline`, `just rechunk`, `just relabel`, `just build-all`, and
`just release-preview` are local mirrors of the CI path.

## 4. Data channels

| #   | Channel                                                                     | Producer                                                                                                                                                                                                          | Consumer                                                                                             |
| --- | --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| 1   | `.github/variants.json`                                                     | committed config                                                                                                                                                                                                  | every resolver, `cleanup.yml`, `changelog.py`                                                        |
| 2   | `$ARTIFACTS_DIR/variants_results.json`                                      | `check-variants.sh:92`                                                                                                                                                                                            | `aggregate_variants:88`, `build_all_variants:536`                                                    |
| 3   | `$ARTIFACTS_DIR/<variant>/{manifest.json,labels.txt}`                       | `build_variant_pipeline:149-150`                                                                                                                                                                                  | `assemble_labels`, `rechunk_image`, `relabel_image`                                                  |
| 4   | `$ARTIFACTS_DIR/<variant>/{output.env,changelog.md}`                        | `changelog.py` through `push-helpers.bash:317`                                                                                                                                                                      | `release_variant` (`source output.env`)                                                              |
| 5   | `GITHUB_OUTPUT` keys                                                        | refs step (`registry`, `repo`, `date`); `aggregate_variants` (`variants_to_build`, `any_builds_needed`); `build_variant_ci` (`record`); `push_variant` (push and sign output); `release_variant` (`title`, `tag`) | only the first three are read: job outputs, and `build.yml:133` reads `record` to feed the Push step |
| 6   | `GITHUB_STEP_SUMMARY` markdown                                              | `generate_step_summary`, `preview_tags`, `sign_and_verify_image`                                                                                                                                                  | the rendered run page                                                                                |
| 7   | env into `check-variants.sh`                                                | `build.yml:65-72`, or `check_variants:53` locally                                                                                                                                                                 | the script                                                                                           |
| 8   | env into `changelog.py`                                                     | `release_variant` exports `IMAGE_PREFIX` (`<registry>/<package>`) and `GITHUB_REPOSITORY`                                                                                                                         | `registry_prefix()` `changelog.py:14`                                                                |
| 9   | job name templates (`Build & Push <variant>`, `Generate Release <variant>`) | `build.yml:86`, `:160`                                                                                                                                                                                            | nothing; logs only                                                                                   |

## 5. Record shapes

```text
variants.json entry   {name, base_image, suffix?, latest?, disabled?, cleanup?,
                       tags?, tags_default?, build_script?}   default build_script: build.sh
variant_record()      adds {variant: .name, disabled: (.disabled // false)}
CI matrix entry       {variant, base_image, build_script, suffix, parent_version,
                       canonical_tag, tags, collision_detected}
                      (needs_build is emitted then deleted by aggregate_variants)
build.yml adds        {date, image_desc, repo_owner, repo_name,
                       version_label: .parent_version}          build.yml:110-117
pipeline requires     variant, version_label, repo_owner, repo_name
pipeline reads        date, image_desc, base_image, build_script, canonical_tag
pipeline returns      input + {source_ref, full_build_digest, build_digest,
                       kernel_version, manifest_packages}
options (pipeline)    {build: always|skip|none, rechunk, force_rebuild,
                       image_name_ref, extract_ref}             default build: skip
options (push)        {registry, repo, date, cosign_pub}
options (release)     {handwritten, variants_config, allow_disabled,
                       registry, repo, dry_run}
options (vm)          {type, output_dir, force_rebuild|force_pull, clean,
                       cache_dir, bib_image}
```

Enabled variants: `stable`, `testing`, `unstable`. Disabled: `nvidia-open`,
`deck`. `unstable` tracks `ghcr.io/ublue-os/bazzite:unstable-45`.

## 6. Decisions

1. Artifact directory. One directory per variant holds its matrix entry, build
   result, and changelog. Nothing goes to `/tmp` or the working tree. The rule
   that clears `ARTIFACTS_DIR` is part of this decision, not a later cleanup: a
   stale artifact otherwise reads as a success.
2. CI and local are separate entrypoints over one core. Each entrypoint sets the
   mode at its own boundary; no core function reads `GITHUB_OUTPUT` to decide
   what it is. The old lowercase/uppercase dual convention is gone: the extractors
   print one shape, uppercase assignments for `eval`.
3. The push path owns the registry writes; skopeo reads the registry and podman
   reads local storage; the cleanup action
   deletes. `podman push` already hashed the manifest it uploaded, so the digest is
   read back with `--digestfile` (`push-helpers.bash:95`, `:100`) instead of a
   second registry round trip that another retag could move. The extra tags are
   manifest re-pointers of that digest ref, applied by one `oras tag` call per push
   (`push-helpers.bash:128`), which PUTs one manifest per tag without re-uploading
   blobs; `oras manifest fetch` supplies the layer sizes cosign reports
   (`push-helpers.bash:180`). The GitHub packages API returns versions, not OCI tags,
   returns versions, not OCI tags, and our tags are what the resolvers need
   (`image_exists:100`, `find_latest_versioned_tag:127` in
   `check-variants-registry.bash`; `check-variants-tags.bash:60`, `:83`).
   Deletion must keep referrers intact: cosign signs with
   `--registry-referrers-mode=legacy` (`push-helpers.bash:165`). `gh` is used
   only for releases, run listing, and job listing.
4. The pipeline takes the variant record and returns it updated. Adding a
   variant field changes data, not call sites.
5. The release set comes from the registry. `pushed_variants` lists enabled
   variants that have a `{variant}-{version}` tag; `resolve_release_variants`
   intersects the request. Renaming a job template cannot skip a release.
   Behavior change: the scheduled release means "anything not released yet", not
   "built in this run". The tag lookup retries `MAX_RETRIES` times; a lookup
   still failing after that reads as nothing to release
   (`find_latest_versioned_tag:127`).
6. The package name is a required argument (`${3:?image_name required}`). The
   only literal in the repository is `Justfile:5`. `cleanup.yml` derives the base
   from the repository name; `changelog.py` takes `--package` and derives the
   registry half from `IMAGE_PREFIX`. Evidence for the namespace: `iso.toml:4`
   ships `ghcr.io/wombatfromhell/bazzite-nix` to users, and the owner is a User,
   not an Org, so owner-lowercase and repo-lowercase are different values.
   Left alone: the `bazzite-nix` literal in the cache-dir default
   (`build-helpers.bash:9`, `Justfile:9`).
7. The two release jobs keep their own setup steps. What is shared is the
   selection: `release_matrix_json` prints the matrix, each step is three lines.
   A shared-workflow file or a custom action would add a file and an indirection
   layer to save six YAML lines.
8. The build step belongs to the pipeline. Options carry `build`: `always`
   (CI), `skip` (default, local), `none` (relabel/rechunk entrypoints that reuse
   an existing image). Before this, the difference lived in which caller you read.
9. Every entrypoint names the record. `push_variant`, `release_variant`,
   `build_vm_image`, `run_variant_vm` take `<record_json> [options_json]`; the
   Justfile composes the record with `variant_record` or `vm_record_json` plus one
   `jq`. Cost accepted: `just push` and `just release` take quoted JSON.

Removed since the previous map, with no caller left: `sudo_refresh`,
`find_prev_ref`, `collect_successful_builds`, `recent_successful_builds`,
`build_variant_core`, `skopeo_copy_with_retry`, and the `digest` / `prev_ref`
matrix fields.

## 7. Tests

| Suite                          | Tests        | Exercises                                                            |
| ------------------------------ | ------------ | -------------------------------------------------------------------- |
| `scripts/just-helpers.bats`    | 36           | resolve, aggregate, release selection, pipeline and entrypoint mocks |
| `scripts/check-variants.bats`  | 11           | the two check libraries                                              |
| `scripts/release-preview.bats` | 4            | `release-preview.py`                                                 |
| `tests/build-helpers.bats`     | 8            | `build-helpers.bash`                                                 |
| `scripts/push-helpers.bats`    | 5            | digest from push, one tag call, retry plumbing                       |
| `tests/test_changelog.py`      | 173 (pytest) | `changelog.py`                                                       |

`just test` (`Justfile:82`) runs all six.

## 8. Open

1. Does anything outside this repository read the `GITHUB_OUTPUT` keys of these
   jobs? Inside the repo, only `build.yml:133` reads one (`record`).
2. `variants_results.json` is still a file on disk, not a return value. The
   location is named once; the handoff shape is not yet owned.
3. `/tmp` is still used in three places: `cleanup.yml:38-51` staging,
   `/tmp/skopeo-auth` (`push-helpers.bash:245`), and buildah
   `--prune /tmp/` (`build-helpers.bash:279`).
4. The cache-dir default still carries the package literal
   (`build-helpers.bash:9`, `Justfile:9`).
