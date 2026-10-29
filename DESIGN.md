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

### 2.2 Justfile (31 recipes)

| Group           | Recipe:line -> function                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Just            | `check:24` check_just_files; `fix:31` fix_just_files                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Utility         | `default:19` just --list; `clean:38` clean_oci_layout + remove_images_and_prune; `cleaner:46` clean_artifacts + remove_images_and_prune; `clean-vm:59` clean_vm_cache; `lint:66` lint_scripts; `format:74` format_scripts; `test:82` bats + pytest; `list-variants:240` list_available_variants                                                                                                                                                                                        |
| Build container | `build:95` run_build; `rebuild:104` build 1; `rechunk:112` run_rechunk; `rootful-load:127` resolve_variant + podman save/load; `relabel:137` run_variant relabel; `pipeline:154` run_variant pipeline; `pipeline-rechunk:170` run_variant pipeline 1; `build-all:181` check_variants + build_all_variants; `release-preview:198` release_preview; `ci-pipeline:210` build_variant_ci; `push:219` push_variant; `release:229` release_variant; `check-variants:250` check_variants; `demo-changelog:260` changelog.py `--pair`; `tags-preview:270` preview_tags |
| VM              | `build-qcow2:279` build_vm_image; `build-raw:290` build_vm_image; `rebuild-qcow2:299` build-qcow2 1; `rebuild-raw:304` build-raw 1; `run-vm-qcow2:311` run_variant_vm; `run-vm-raw:322` run_variant_vm                                                                                                                                                                                                                                                                                    |                                                                                                                                                                                                                                                                                 |

Shell flags are set once at `Justfile:2`. 25 of the 31 recipes carry the
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
| `scripts/changelog.py`              | `target output changelog --package --variants-config [--pretty --handwritten --pair PREV CURR]`; `--package` (`:668`) and `--variants-config` (`:673`) required; `--pair` (`:660`) names the release window with two published tags instead of letting each image's newest canonical tag win, and a pair no image carries exits non-zero (`:691`); reads `IMAGE_PREFIX` for the registry half (`:15`); the current release comes from each image's newest canonical tag (`release_ref` `:179`); a variant whose newest version tag is its only one gets a first-release body with no diff tables; writes the two files where the caller pointed |
| `scripts/release-preview.py`        | `image_ref [--prev]`; reads a local image with podman, a registry ref with skopeo                                                                                                                                                                          |
| `*.bats`, `tests/test_changelog.py` | run by `just test`                                                                                                                                                                                                                                         |

## 3. Function map

`scripts/just-helpers.bash` - umbrella. Declares `JUST_HELPERS_BUILD` (`:29`),
`JUST_HELPERS_PUSH` (`:32`), guards and exports `ARTIFACTS_DIR` (`:38-43`),
sources the two check parts (`:46`, `:48`), build, push, then the five
`just-helpers-*` parts in a loop (`:55-57`).

| File                           | Functions                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `check-variants-registry.bash` | `registry_url:19` owner -> `ghcr.io/<owner>`; `registry_owner:26` CI owner or Justfile default; `package_repo:34` lowercase repo name; `variant_record:45` the one variant lookup, fails listing enabled names; `variant_names:59`; `enabled_variant_names:63`; `read_registry_json:75` the one retry loop; `inspect_image_with_retry:99`; `image_exists:108`; `get_parent_version:118`; `version_of_tag:133`; `find_latest_versioned_tag:150`; `upstream_repo:181`; `resolve_upstream_tag:199` upstream identity by exact-name probe; `upstream_version_candidates:239` build-counter walk; `version_check:261`; `check_build_needed:286` |
| `check-variants-tags.bash`     | `extract_image_metadata:9`; `compute_canonical_tag:32` our version = upstream's +1, walked past tags we published; `tag_needs_digest:96`; `generate_tags:106` `{canonical} {branch} {major} {sha256}`; `resolve_variant:164`                                                                                                                                                                                                                              |
| `build-helpers.bash`           | `CACHE_DIR:9`; `image_ref:19` the one spelling of a local ref; `image_digest:26`; `image_tag:32`; `sudo_cache:39`; `build_image:49`; `build_image_or_skip:67`; `extract_image_info:89`; `assemble_labels:136`; `relabel_image:174`; `rechunk_image:218`; `extract_final_ref:306`                                                                                                                                          |
| `push-helpers.bash`            | `is_transient_error:10`; `run_with_retry:23`; `push_image_with_tags:79`; `sign_and_verify_image:147`; `push_variant:218`; `release_variant:278`                                                                                                                                                                                                                                                                          |
| `just-helpers-build.bash`      | `run_build:14`; `print_build_summary:29`; `echo_build_assignments:50`; `resolved_variant_record_json:61`; `_step:71`; `run_fields:79`; `build_variant_pipeline:97` the one sequence; `run_variant:228` rechunk/relabel/pipeline modes (thin `run_rechunk:314`, `run_relabel:318`, `run_pipeline:322`); `build_variant_ci:335`; `build_all_variants:352`    |
| `just-helpers-variants.bash`   | `preview_tags:8`; `check_variants:53`; `aggregate_variants:84`; `generate_step_summary:123`; `pushed_variants:175`; `resolve_release_variants:193`; `release_matrix_json:212`; `release_preview:229`                                                                                                                                                                                                                      |
| `just-helpers-clean.bash`      | `clean_artifacts:7`; `remove_images_and_prune:21`; `clean_oci_layout:57`; `clean_vm_cache:66`                                                                                                                                                                                                                                                                                                                             |
| `just-helpers-tooling.bash`    | `check_just_files:9`; `fix_just_files:21`; `lint_scripts:33`; `format_scripts:41`; `list_available_variants:50`                                                                                                                                                                                                                                                                                                           |
| `just-helpers-vm.bash`         | `disk_file_name:10`; `ensure_vm_images:21`; `_build_bib:30`; `build_bib:104`; `variant_chunked_layout:151`; `export_and_build_bib:163`; `build_vm_image:186`; `run_vm:233`; `run_variant_vm:337`                                                                                                                                                                                                    |

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
| 5   | `GITHUB_OUTPUT` keys                                                        | refs step (`registry`, `repo`, `date`); `aggregate_variants` (`variants_to_build`, `any_builds_needed`); `cleanup_packages` (`packages`); `build_variant_ci` (`record`); `push_variant` (push and sign output); `release_variant` (`title`, `tag`) | only the first three are read: job outputs, and `build.yml:133` reads `record` to feed the Push step |
| 6   | `GITHUB_STEP_SUMMARY` markdown                                              | `generate_step_summary`, `preview_tags`, `sign_and_verify_image`                                                                                                                                                  | the rendered run page                                                                                |
| 7   | env into `check-variants.sh`                                                | `build.yml:65-72`, or `check_variants:53` locally                                                                                                                                                                 | the script                                                                                           |
| 8   | env into `changelog.py`                                                     | `release_variant` exports `IMAGE_PREFIX` (`<registry>/<package>`) and `GITHUB_REPOSITORY`                                                                                                                         | `registry_prefix()` `changelog.py:14`                                                                |
| 9   | job name templates (`Build & Push <variant>`, `Generate Release <variant>`) | `build.yml:86`, `:160`                                                                                                                                                                                            | nothing; logs only                                                                                   |

## 5. Record shapes

```text
variants.json entry   {name, base_image, suffix?, latest?, disabled?, cleanup?,
                       tags?, tags_default?, build_script?}   default build_script: build.sh
variant_record()      adds {variant: .name, disabled: (.disabled // false)}
resolve_variant     prints exactly one record line to stdout:
                    {variant, tag, target_image, suffix, base_image, build_script,
                     latest, canonical_tag, version_tag, upstream_tag,
                     upstream_version, tag_family, tags,
                     collision_detected}   (variant == tag for an explicit image:tag spec)
                    version_tag = {branch}-{canonical}, upstream's version verbatim,
                    unless our registry already holds that tag — then it carries a
                    minor version (decision 12)
resolved_variant_record_json adds {repo_owner, repo_name, image_desc,
                    version_label: .version_tag // .canonical_tag}
vm record             is the resolve_variant record; no wrapper
CI matrix entry       the resolve_variant record plus needs_build, which aggregate_variants
                      deletes, so the entry is that record verbatim: build.yml reads
                      variant (and the whole record at build.yml:133); the rest — tag,
                      tag_family, upstream_version, latest, target_image — travel with
                      it                                                     (decision 14)
build.yml adds        {date, image_desc, repo_owner, repo_name,
                       version_label: .version_tag}             build.yml:110-117
pipeline requires     variant, version_label, repo_owner, repo_name
pipeline reads        date, image_desc, base_image, build_script, upstream_tag
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
   print one shape, uppercase assignments for `eval`. Nothing resolves through
   `eval` any more: `resolve_variant` prints one record line, an entrypoint turns
   the few fields it needs into shell names with one `IFS` read, and the record
   itself is what the printers (`print_build_summary`, `echo_build_assignments`) and
   the pipeline consume. Cost paid: two `jq` reads per build instead of one `eval`.
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
   layer to save six YAML lines. `generate_release.yml` stays a separate file for
   the same reason: it is the manual entrypoint (dispatch with hand-written notes),
   the scheduled release is `build.yml`'s gated job, and folding one into the other
   would trade two readable triggers for a condition on `github.event_name`.
8. The build step belongs to the pipeline. Options carry `build`: `always`
   (CI), `skip` (default, local), `none` (relabel/rechunk entrypoints that reuse
   an existing image). Before this, the difference lived in which caller you read.
9. Every entrypoint names the record. `push_variant`, `release_variant`,
   `build_vm_image`, `run_variant_vm` take `<record_json> [options_json]`; the
   Justfile composes the record with `resolve_variant` (whose record is the VM
   record) plus one `jq`. Cost accepted: `just push` and `just release` take quoted JSON.

10. Upstream identity comes from upstream's git tags, not from the base image's
    version label. The label moves ahead of the tag: probed 2026-10-19, `bazzite:testing`
    held `45.20261019.4` while upstream's newest `testing` tag was `testing-45.20261019.3`,
    and `bazzite:stable` is labelled `44.20261012.1`, which upstream tags bare, while its
    testing and unstable builds carry a branch prefix. So the label version is probed against
    both name families (`{branch}-{version}`, then `{version}`), each walked down its build
    counter up to `UPSTREAM_BUILD_WALK` names. What the search did not find is split by how
    far it walked: probed 2026-10-20, `bazzite:testing` was labelled `testing-45.20261020.1`
    minutes after upstream pushed that build, `/commits/testing-45.20261020.1` answered 404
    (200 twenty minutes later), and the bare `45.20261020.1` answers 422 because a testing
    build is only ever named with the branch prefix — so counter `.1` has no lower name to
    try, every name in both families was probed, and the honest answer is that upstream
    published before tagging: return 2, skip that variant, never borrow a previous day's
    version (the label we would carry, `org.opencontainers.image.parent-version` of
    decision 12, would then name a release this image is not cut from). A search cut short
    at `UPSTREAM_BUILD_WALK` names, or a probe upstream refused with a rate limit, means
    nothing was answered: return 1, the check job fails. Paging the `/tags` list stays
    rejected on the same evidence: unstable pushes 40+ tags a day, so 500 tags never reached
    the stable branch. Cost: one probe per variant, two for an untagged day-first build,
    up to ten only when the walk runs out of budget.

11. `verify-upstream` compares versions, not tag names. Our published tags always
    carry the branch prefix (`{variant}-{version}`), upstream names its stable line
    bare, so the two name families are the same release under different names. The
    check therefore asks whether the version our newest tag carries is the version
    upstream's resolved tag names; a name-only comparison would fail on every stable
    release. The tag-name rule is enforced separately over the whole tag list, which
    also reports the bare `{version}` names published before decision 10 as legacy.

12. `org.opencontainers.image.version` is our own version (`version_tag`), spelled
    `{branch}-{version}`. The version is upstream's verbatim — `stable-44.20261026` for
    upstream's bare `44.20261026` — and gains a minor version only when
    `{branch}-{version}` is already in our registry, which is what a `force_build`
    re-run of the same upstream release hits (`stable-44.20261026.1`). The upstream
    identity lives in its own label, `org.opencontainers.image.parent-version`
    (`build-helpers.bash:168`), spelled the way upstream spells it, so the two labels
    never confuse the release we were cut from with the version we published. Reading
    our own previous release against upstream needs the parent label: without it the
    reader can only re-probe the naming family from `org.opencontainers.image.version`,
    which is what happens for releases published before this change (that reader also
    still recognises the earlier `org.opencontainers.image.upstream-version` spelling).

13. A variant's current release is read from its newest canonical tag (`release_ref`
    `changelog.py:179`, feeding `get_manifests:196`), and the moving `{variant}` tag is
    only the fallback for images that publish no canonical name. The moving tag is an
    alias we do not always have: `ghcr.io/wombatfromhell/bazzite-nix` carries
    `unstable-45.20261015.6` and `unstable-45.20261017.2` but no `unstable`, which made
    the reader stop before printing a diff. Canonical names are also how the previous
    release is addressed, and `version_sort_key:174` orders names by their number runs,
    so build `.10` follows `.9` instead of sorting before `.6`.

14. One resolution driver. `check-variants.sh` asks `resolve_variant` for a variant's
    identity — label version, upstream probe families, canonical tag, collision bump,
    tag list — instead of walking them itself, so the rule in decision 10 is written
    once and the check job cannot drift from the Justfile on which release a variant
    is cut from. The driver keeps only what it owns: which variants to consider (the
    override list, `disabled`), whether a build is needed (`check_build_needed`), and
    the artifact record. `resolve_variant` returns 2 for "this variant has no version to
    build against right now" — every tag within `COLLISION_BUMP_WALK` bumps is taken, or
    upstream has not tagged the labelled build yet (decision 10) — which the check job
    answers by skipping that variant with a `::warning::`, since one busy variant must not
    fail the whole check, while other callers fail outright. The
    guard that a base-image label must name a release version (`VERSIONED_TAG_PATTERN`,
    so a moving label like `latest` names nothing) lives in the resolver, not per driver.
    Cost: the check job sources `build-helpers.bash` for `image_ref`, the one spelling
    of a local image reference, keeping the record's `target_image` honest there.

15. The cleanup job asks the helpers for package names. `cleanup_packages` derives the
    GHCR package names to clean — repository name plus variant suffix, lowercased through
    `package_repo`, the same rule `check-variants.sh` uses — from `.github/variants.json`
    policy (`disabled`, `cleanup: false`), and filters an explicit comma list. The YAML had
    re-derived the rule with a second `jq` and a `grep`/`sed` over `/tmp` files, so the
    cleanup job could address a package the build job never published; it now calls the
    helper it already sources. Naming a package explicitly overrides `cleanup: false`, which
    matches how `VARIANTS_OVERRIDE` overrides `disabled`: naming one is an instruction.

16. The log directives have one spelling. `fail` and `warn` in `scripts/log-helpers.bash` emit
    `::error::` / `::warning::` on stderr and flatten newlines, so 33 call sites cannot drift and
    upstream text cannot silently stop being a directive. This is **not** a size win (measured +41
    lines); it is a drift win, kept because a misspelled directive renders as prose — the same
    silent-failure class `DESIGN.md §8` keeps open. The boundary is deliberate: `::group::`,
    `::endgroup::`, `::notice::` and `::debug::` stay spelled where they are used, because they
    are log scaffolding (open/close, progress), not problem reporting, and helper-izing them buys
    no anti-drift. Diagnostics belong on stderr, so the moved sites changed stream; no test
    expectation changed because the suites capture combined output.

Removed since the previous map, with no caller left: `sudo_refresh`,
`find_prev_ref`, `collect_successful_builds`, `recent_successful_builds`,
`build_variant_core`, `skopeo_copy_with_retry`, and the `digest` / `prev_ref`
matrix fields.

## 7. Tests

| Suite                          | Tests        | Exercises                                                            |
| ------------------------------ | ------------ | -------------------------------------------------------------------- |
| `scripts/just-helpers.bats`    | 61           | resolve (upstream probe stubbed, stdout is one record, the version label is our own tag), cleanup package identity, aggregate, release selection, pipeline and entrypoint mocks |
| `scripts/check-variants.bats`  | 38           | the two check libraries, upstream identity probes (both naming families, the untagged-build skip, the walk budget), the bump-on-collision canonical and the registry walk past our own tags, and `check-variants.sh` driven end to end over PATH stubs, against `resolve_variant` for the same fixture |
| `scripts/release-preview.bats` | 4            | `release-preview.py`                                                 |
| `tests/build-helpers.bats`     | 11           | `build-helpers.bash`, including the labels a published image carries (own `version`, `parent-version`) |
| `scripts/push-helpers.bats`    | 6            | digest from push, one tag call, retry plumbing                       |
| `tests/log-helpers.bats`       | 4            | one spelling for the `::error::` / `::warning::` directives, newline-flattened, and the grep invariant that no driver spells one |
| `tests/test_changelog.py`      | 196 (pytest) | `changelog.py`, including a forced tag pair naming one release window |

`just test` (`Justfile:82`) runs all six suites and the pytest file.

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
