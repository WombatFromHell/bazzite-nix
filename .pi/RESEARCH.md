# RESEARCH.md — ponytail deep dive: helper / workflow / Justfile surface

Status: **complete pass 1** (investigation facts only — no files changed yet).
Scope read in full: `Justfile`, `.github/workflows/*.yml`, `scripts/*.bash|sh|py`,
`build_files/*.sh`, `DESIGN.md`, all five bats suites + `tests/test_changelog.py`.
Ground truth contract: `DESIGN.md` (sections 1–8). Pointers are `file:line`.

Resume protocol: this file is the fact base. `.pi/PLAN.md` is the gate/progress
file. Update PLAN.md at task boundaries only; keep facts here.

---

## 0. Verified census (measurement, not opinion)

`lines | fns | longest-fn | jq-calls | jq --arg | eval "$()" | IFS=$'\037' reads | GHA ::directives | code-only lines`

| file | lines | fns | maxfn | jq | --arg | eval | 037-read | `::` | code |
|---|---|---|---|---|---|---|---|---|---|
| Justfile | 329 | 31 recipes | — | 5 | **25** | 3 | 0 | 0 | 171 |
| .github/workflows/build.yml | 194 | — | — | 4 | 7 | 0 | 0 | 0 | 169 |
| .github/workflows/cleanup.yml | 82 | — | — | 3 | 2 | 0 | 0 | 1 | 69 |
| .github/workflows/generate_release.yml | 68 | — | — | 0 | 0 | 0 | 0 | 1 | 60 |
| scripts/just-helpers.bash (umbrella) | 58 | 0 | — | 0 | 0 | 0 | 0 | 1 | 17 |
| scripts/build-helpers.bash | 332 | 11 | 88 (`rechunk_image`) | 3 | 0 | 0 | 0 | 8 | 211 |
| scripts/push-helpers.bash | 352 | 6 | 75 (`push_image_with_tags`) | 7 | 6 | 0 | **5** | **21** | 241 |
| scripts/check-variants-registry.bash | 350 | 18 | 41 | 12 | 1 | 0 | 0 | 8 | 206 |
| scripts/check-variants-tags.bash | 281 | 5 | **123 (`resolve_variant`)** | 11 | 1 | 1 | 0 | 5 | 195 |
| scripts/check-variants.sh | 241 | 0 | — | 10 | 9 | 0 | 0 | **25** | 147 |
| scripts/just-helpers-build.bash | 408 | 13 | **133 (`build_variant_pipeline`)** | 17 | **24** | **4** | 3 | 1 | 290 |
| scripts/just-helpers-vm.bash | 365 | 9 | 104 (`run_vm`) | 5 | 6 | 1 | 4 | 0 | 257 |
| scripts/just-helpers-variants.bash | 256 | 8 | 52 | 14 | 0 | 1 | 0 | 3 | 191 |
| scripts/just-helpers-clean.bash | 79 | 4 | 36 | 0 | 0 | 0 | 0 | 0 | 53 |
| scripts/just-helpers-tooling.bash | 56 | 5 | 12 | 1 | 0 | 0 | 0 | 0 | 39 |
| scripts/changelog.py | 794 | 27 defs | 112 (`generate_changelog`) | — | — | — | — | 2 | 628 |
| scripts/release-preview.py | 126 | 3 defs | 22 | — | — | — | — | 0 | 100 |
| build_files/* (10 files) | 464 | 2 | — | 3 | 0 | 0 | 0 | 0 | 258 |

**Impl totals: 4,793 lines / 3,302 code lines / 94 `jq` invocations / 81 `--arg` / 10 `eval "$()"` / 12 US-separated-record destructures / 76 GHA log directives.**

Test totals: bats 1,600 lines (97 `@test` cases), `tests/test_changelog.py` 1,914 lines (~135 test defs, 20 `Test*` classes, 196 per DESIGN.md §7).

---

## 1. Helper usage — who calls what (reachability)

DESIGN.md §3 "Reachability: clean, tooling, vm appear in no workflow" — confirmed by grep:
workflows call only `just-helpers.bash` (source) + these 9 names.

| caller | helpers it actually touches |
|---|---|
| `build.yml` | `registry_url:55`, `package_repo:56`, `bash scripts/check-variants.sh:72`, `aggregate_variants:73`, `preview_tags:81`, `just ci-pipeline:117`, `just push:140` |
| `generate_release.yml` | `release_matrix_json:35`, `just release:67` |
| `cleanup.yml` | **nothing from scripts/** — 21 lines of inline `jq`/`grep`/`sed` over `.github/variants.json` staged through `/tmp/*.txt` (`cleanup.yml:31-51`) |
| `Justfile` (25 of 31 recipes) | `source scripts/just-helpers.bash` then one function; 6 recipes delegate to another recipe |
| bats suites | source the *part* files, not the umbrella (`check-variants.bats:5` comment "Sources the part files directly (not the umbrella) — also proves the parts are composable") |

**Dead / stale surface found (verifiable):**
1. `.github/variants.json` `_schema.output_fields` documents `digest` and `prev_ref`;
   `check-variants.sh` emits neither (its `result=$(jq -n …)` has
   variant, base_image, build_script, suffix, parent_version, canonical_tag,
   upstream_tag, tags, collision_detected, needs_build), and DESIGN.md §6 closes
   with "Removed since the previous map, with no caller left: … the `digest` / `prev_ref` matrix fields".
   → ~18 lines of committed documentation describing fields that no longer exist.
2. `scripts/just-helpers-vm.bash`/`-variants.bash`/`-tooling.bash` each `source` their part file
   from the umbrella via a `readonly` name; `JUST_HELPERS_PUSH` (`just-helpers.bash:32`) is used
   only as the `source` target (`just-helpers.bash:52`) whereas `JUST_HELPERS_BUILD` is also read
   in a comment (`just-helpers-build.bash:117`). **Verified non-finding:** the umbrella is uniform
   (5 `readonly` + 5 `source`); do not "simplify" it — 17 code lines, all load-bearing.
3. `scripts/release-preview.py` shares **zero** non-blank lines with `scripts/changelog.py`
   (measured via difflib over 100 code lines) — it is a *second, independent* changelog renderer
   with its own `inspect()`/`render()`, tested by its own 4-test suite. Overlap with
   `changelog.py --pair` (`Justfile demo-changelog:260`) is a duplicate feature, not shared code.

Function-per-file inventory is already in DESIGN.md §3 and matches this pass
(83 shell+py functions counted); no drift found.

---

## 2. Complexity findings, ranked. Each is a *delete/replace*, with a named replacement.

### P0 — `scripts/check-variants.sh` re-implements `resolve_variant`

`check-variants.sh` (241 lines, **0 functions**) is a flat, env-var-driven driver whose
per-variant loop does exactly the sequence `resolve_variant`
(`check-variants-tags.bash:150`, 123 lines) already does:

```
check-variants.sh:112  inspect_image_with_retry "$base_image"
check-variants.sh:121  extract_image_metadata → label_version
check-variants.sh:124  version_of_tag
check-variants.sh:129  resolve_upstream_tag  → upstream_tag/upstream_version/tag_family
check-variants.sh:158  compute_canonical_tag → canonical + collision_detected
check-variants.sh:165  generate_tags → tags
check-variants.sh:170  check_build_needed → eval REASON
check-variants.sh:176  result=$(jq -n --arg variant … )      # 10 --arg, hand-listed

resolve_variant:187    get_parent_version  (same, different primitive)
resolve_variant:193    version_of_tag
resolve_variant:196    resolve_upstream_tag
resolve_variant:214    compute_canonical_tag
resolve_variant:238    generate_tags
resolve_variant:249    echo "TAGS=…"          # instead of returning them
```

Two drivers, one pipeline. The only real differences: `check_build_needed` decision + the
results array + `::` logging. **Lazy fix:** make `resolve_variant` return a JSON record
(`variant_record` already returns JSON), have `check-variants.sh` call it once per variant,
and delete the inlined resolution + the hand-listed `--arg` result builder.
Est. removable: **120–150 lines**, and it deletes the second copy of the upstream-identity
rule that DESIGN.md §6 decision 10 spent a paragraph justifying (a rule duplicated in two
places is a bug farm, not a documented design).

### P0 — Four value-passing protocols, three bridges between them

| # | channel | producers | consumers | evidence |
|---|---|---|---|---|
| A | `eval "$()"` prints `KEY="value"` assignments | `resolve_variant` (9 lines ×2 branches), `extract_image_info`, `extract_final_ref`, `check_build_needed`/`version_check` (REASON) | 10 `eval "$("` sites: `just-helpers-build.bash` ×4, `Justfile` ×3, `check-variants-tags/variants/vm` ×1 each | DESIGN.md §6 decision 2 concedes "the extractors print one shape, uppercase assignments for `eval`" |
| B | JSON record, destructured with `IFS=$'\037' read -r` | `build_variant_pipeline`, `push_variant`, `release_variant`, `build_vm_image`, `run_variant_vm` | 12 destructures + 13 `jq -r '[…] | join("\u001f")'` | push-helpers ×5, vm ×4, build ×3 |
| C | `GITHUB_OUTPUT` `key=value` | `build_variant_ci`, `push_variant`, `release_variant`, `aggregate_variants` | only 1 read inside the repo (`build.yml:133` reads `record`) — DESIGN.md §8 open item 1 |
| D | files under `ARTIFACTS_DIR` | `check-variants.sh:92`, `build_variant_pipeline:149-150`, `changelog.py` | `aggregate_variants`, `build_all_variants`, `release_variant` (`source output.env`) | DESIGN.md §8 open item 2 |

Channel A is the odd one out and it is *unsafe by construction*: the values are
image refs, tags and descriptions interpolated into a shell string. Protocol B already
exists, is used by the core, and is what `variants.json`/CI already speak.
**Bridge layer that exists only to cross A↔B** (`just-helpers-build.bash`, ~100 code lines):
`run_fields:100` (key=value→JSON), `resolved_variant_record_json:53` (globals→JSON, 11 `--arg`),
`apply_build_record:84` (JSON→globals via `printf -v`), `echo_build_assignments:42` (globals→shell),
`BUILD_FIELDS:25` (the list that feeds reader+writer), `print_build_summary:27` (reads globals).
**P0 fix:** one resolver shape — record in, record out — then A disappears and the bridge
shrinks by 4 of its 6 functions. Est. removable **120–150 lines** across
`check-variants-tags/registry`, `just-helpers-build`, `check-variants.sh`, `Justfile`.

### P1 — Justfile preamble + argument marshalling (25 recipes)

* 25 of 31 recipes carry the identical 2-line preamble (`#!/usr/bin/env bash` +
  `source "{{ just_helpers }}"`) = **50 lines**. `Justfile:2` already sets shell flags globally;
  DESIGN.md notes the preamble is needed because `just` 1.57.0 runs each recipe line in its own
  process. Cheapest cut that keeps functionality: one dispatcher entrypoint
  (`scripts/just-helpers.sh <fn> <args…>`) that sources the umbrella once → recipe bodies become
  **1 line**. Removes 25 `source` lines and the per-recipe shebang.
* Inline JSON option building in recipes: 5 recipes × `jq -cn --arg … '{…}'` = **25 `--arg`**
  on ~5 unreadable lines each (`build-qcow2:279`, `build-raw:290`, `run-vm-qcow2:311`,
  `run-vm-raw:322`, `release:229`). Options records belong in the helpers, which already
  default every one of those fields (`build_vm_image:197` defaults `bib_image`, `cache_dir`…).
* Byte-identical recipe pairs (difflib ≥0.80, measured):
  `build-qcow2` ↔ `build-raw` differ only by the literal `"qcow2"`/`"raw"` (11 lines each);
  `run-vm-qcow2` ↔ `run-vm-raw` are **identical except the `--arg type` literal**;
  `rechunk` ↔ `relabel` r=0.82; `fix` ↔ `format` r=0.86;
  `rebuild*`/`pipeline-rechunk` already delegate (proof the pattern is intended).
  → 4 pairs collapse to 2 parameterised recipes. Est. removable **~35 lines**.

### P1 — `generate_release.yml` duplicates `build.yml`'s release job

`generate_release.yml` (68 lines) = resolve-variants job + matrix + `checkout fetch-depth: 500`
+ `setup-just` + `just release <variant> <handwritten> <config> true`
(`generate_release.yml:35`, `:67`).
`build.yml` `generate_release` job = collect + matrix + same checkout + same setup-just +
same `just release` call (`build.yml:157`, `:195`), already gated on
`github.event.inputs.generate_release` (`build.yml:110-115` gate).
DESIGN.md §6 decision 7 explicitly defends keeping the *setup steps* separate ("would add a
file and an indirection layer to save six YAML lines") — but that argument is about the 3-line
steps, not about the whole job chain. YAGNI question to put to the user: does the
manual-release workflow need to exist at all, given `build.yml` can already be dispatched with
`generate_release=true` + `variants_override`? If no: **~45–60 lines deleted**, one workflow file
deleted, no behaviour lost for the scheduled path.

### P1 — `cleanup.yml` is the only workflow that ignores the helpers it already has

`cleanup.yml:31-51` (21 code lines) hand-derives package names
`[.variants[] | select(.disabled != true) | select(.cleanup != false) | ($base + (.suffix // "")) | ascii_downcase]`,
stages them through `/tmp/all_packages.txt` and `/tmp/packages.txt`, and re-implements
whitespace trimming in `sed`. `check-variants-registry.bash` already owns the namespace rules
(`registry_url:19`, `registry_owner:26`, `package_repo:34` — DESIGN.md §6 decision 6,
"One package identity") and `enabled_variant_names:63` already filters `disabled`.
`/tmp` staging is also DESIGN.md §8 open item 3 ("`/tmp` is still used in three places").
**Lazy fix:** one helper (`cleanup_packages [csv]` printing one package per line, the
`cleanup != false` filter being the only genuinely new bit) used by both `cleanup.yml` and
`pushed_variants` (`just-helpers-variants.bash:175` re-derives the same package identity with
`jq -r '.variants[] | select(.disabled != true) | [.name, .suffix // ""] | @tsv'`).

### P2 — Three markdown-table renderers, three retry loops

Markdown table (`| Variant | Target Image | Tags |`) is emitted by **three** places that each
rebuild the columns from the same record:
`preview_tags:8` (`just-helpers-variants.bash`), `generate_step_summary:123` (52 lines,
its own per-variant `jq` loop: 5 `jq -r` calls *per variant*), and
`sign_and_verify_image:147` (`push-helpers.bash`, the "Field | Value" table).
`generate_step_summary` is the worst of the three: it re-parses one JSON array into a bash
`while` loop with one `jq` process per field per row (5 × N subprocesses for N variants)
and duplicates `preview_tags`' header literal.

Retry loops with three different budgets/semantics:
`read_registry_json:75` (`MAX_RETRIES=3`, `RETRY_DELAY=10`, validates JSON),
`run_with_retry:23` (`MAX_ATTEMPTS=3`, `RETRY_DELAY=15`, classifies transient errors,
spawns 2 `mktemp` per attempt, `set +e` toggle),
`build_files/extras.sh:dnf5_retry` (3 attempts, cache-clean between).
The first two are one policy with two spellings (`run_with_retry` is the general one;
`read_registry_json` adds only the JSON-validity rule). `run_with_retry`'s stdin/stdout
`mktemp` dance exists to feed `podman login --password-stdin` and stream output while
classifying — that is 2 temp files + a `set +e`/`set -e` pair per attempt, replaceable with
one `commandgroup` + `<<<` redirect.

### P2 — Test infrastructure carries the bloat

| suite | lines | @test | shared mock scaffolding |
|---|---|---|---|
| `scripts/just-helpers.bats` | 736 | 47 | 7 shell helpers: `setup:8`, `setup_variant_json:101`, `stub_upstream_probe:142`, `build_core_mocks:413`, `run_variant_mocks:501`, `release_variant_mocks:623`, `push_variant_mocks:711`; **5 separate `skopeo()` redefinitions** (155/175/211/227/249), `podman:84`, `curl:143`, `sudo:304`; **36 `mktemp`** |
| `scripts/check-variants.bats` | 400 | 31 | 1 `skopeo` heredoc stub in `setup:11`; **17 `cat >` heredoc stubs** inline |
| `tests/build-helpers.bats` | 233 | 9 | `setup:7`, 8 `mktemp` |
| `scripts/release-preview.bats` | 114 | 4 | 4 heredoc stubs, no `load` |
| `scripts/push-helpers.bats` | 117 | 6 | `podman:28`, `oras:41` stubs, 5 `mktemp` |
| `tests/test_changelog.py` | 1,914 | 196 | 20 `Test*` classes; only 2 factories (`make_manifest_with_packages:64`, `make_manifest_with_tags:69`); transport mocks live *inside* the suite (`FakeGitHubTransport`, `FakeRegistryTransport`) |

The user asked for exactly this: mocks/factories/instrumentation broken out into
test-specific helper files. bats already supports `load` (used at
`check-variants.bats:14-15`), so `skopeo`/`podman`/`oras`/`curl`/`sudo` stubs + the
variant-JSON fixture builder become `tests/helpers/*.bash`, dropping 5 skopeo redefinitions
and 17 inline heredocs. Est. removable **200–250** test lines, with no coverage loss,
and it makes the `check-variants.bats:5` claim ("proves the parts are composable") visible
rather than asserted.
Instrumentation note: 76 `::` GHA directives live inside helpers that also run locally
(25 of them in `check-variants.sh`, 21 in `push-helpers.bash`); they are inert locally, so
they stay — but they must be a *helper function*, not a literal, once `check-variants.sh`
merges into `resolve_variant` (P0).

### P3 — `build_files/` (secondary; DESIGN.md marks it out of scope)

Measured near-duplicates: `build.sh` ↔ `build-cachyos.sh` r=0.93, ↔ `build-upstream.sh` r=0.88
(10–11 lines each, 3 files); `cachyos-kernel.sh` ↔ `upstream-kernel.sh` differ **only** in the
dnf5 repo/package list (28–29 lines each). `build.sh`, `build-cachyos.sh`, `build-upstream.sh`
are each selected by a `build_script` field in `variants.json` — same file, one argument.
Est. removable **~45 lines** across 5 files → 2. Not touched in phase 1 (out of DESIGN.md scope,
and they run inside the image build where shellcheck/CI do not see them).

---

## 3. What NOT to simplify (already-defended decisions — do not re-litigate)

DESIGN.md §6 already accepts these; a ponytail pass that "cleans" them is a regression:
- decision 1 + `check-variants.sh:51` clearing `ARTIFACTS_DIR` at run start (a stale artifact
  reads as success — this guard is load-bearing).
- decision 2: CI/local are separate entrypoints over one core; no core function reads `GITHUB_OUTPUT`.
- decision 3: `--digestfile` instead of a second registry round trip; one `oras tag` call per push;
  cosign `--registry-referrers-mode=legacy` (deletion-safe referrers).
- decision 7: the two release jobs keep their own setup steps (only the 6 YAML lines).
- decision 9: entrypoints name the record; quoted JSON on `just push`/`just release` is accepted cost.
- decision 10: upstream identity by exact-name probe, not paging `/tags` (40+ tags/day evidence).
- `COLLISION_BUMP_WALK=5` (`check-variants-tags.bash:6`), `UPSTREAM_BUILD_WALK=5`
  (`check-variants-registry.bash:12`), `--max-layers 256` (`build-helpers.bash:279`),
  the two `ponytail:` comments already in tree (`build-helpers.bash` cosign-optional rechunk,
  `check-variants-tags.bash` default tag list mirrors unstable).

## 4. Open items carried from DESIGN.md §8 (still true after this pass)

1. Only `build.yml:133` reads a `GITHUB_OUTPUT` key inside the repo (DESIGN.md §8 item 1 asks
   whether anything outside the repo reads these keys) → channel C may be shrinkable to job-local
   variables once the `build_push` job stops needing a hand-off.
2. `variants_results.json` is a file, not a return value (blocks P0's clean shape).
3. `/tmp`: `cleanup.yml:38-51`, `/tmp/skopeo-auth` (`push-helpers.bash:245` — note: fixed path,
   world-readable dir, written by whatever ran the suite), buildah `--prune /tmp/`.
4. Cache-dir default still carries the package literal (`build-helpers.bash:9`, `Justfile:9`).

## 5. Net size estimate

| area | now | realistic after | note |
|---|---|---|---|
| `Justfile` | 329 | ~250 | preamble + pair collapse + record marshalling |
| `check-variants.sh` + `check-variants-tags.bash` | 522 | ~330 | P0 single driver |
| `just-helpers-build.bash` | 408 | ~320 | bridge layer shrinks |
| `just-helpers-vm/variants/push-helpers` | 973 | ~800 | VM pairs, retry loop, table renderer |
| workflows | 344 | ~260 | cleanup.yml helper, release-workflow question |
| tests | 3,514 | ~3,200 | shared mock helpers, no coverage loss |
| **total** | **8,307** | **~7,200** | **~1.1k lines (13%)** — the "dramatic" cut is concentrated in the two P0 duplications, not in cosmetics |

Honesty note: the two P0 items are where the real removal is. Everything below P1 is
20–60 lines each; anyone promising a 40% cut is reaching for the wrong lever.
