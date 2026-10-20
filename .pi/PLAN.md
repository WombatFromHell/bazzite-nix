# PLAN.md — multi-step simplification of the helper / workflow surface

Gate file. Update **only at task boundaries** (a slice is done = every suite green + committed).
Facts live in `RESEARCH.md` (see `RESEARCH.md §2` for the evidence behind every line here).
Rule applied throughout: **ponytail** — laziest thing that works; if a slice cannot name the
lines it deletes, it is not a slice.

Invariant for every slice (the "green gate"):

```bash
just test            # Justfile:82 — runs all six suites (DESIGN.md §7)
just lint            # Justfile:66 — shellcheck; must stay clean
bash -n scripts/*.bash               # cheap parse check
scripts/check-variants.sh            # sanity run: prints a results table, exit 0/1 as today
git diff --stat HEAD                 # expected delta is recorded per slice
```

Never touch in the same commit as a protocol change: the "do not re-litigate" list
(`RESEARCH.md §3`). If a slice needs a helper to move because a caller stops existing,
**defer that slice** — dead-code rules in `DESIGN.md §3` do the deletion for free.

---

## G0 — approval gate (BLOCKED: awaiting explicit user approval)

Nothing below changes an existing file until this gate is cleared.
Decisions the user must take, one line each (all from `RESEARCH.md §2`):

| # | question | default if user says nothing |
|---|---|---|
| Q1 | May `resolve_variant` return a JSON record instead of `eval`-able assignments? | yes (aligns A onto B, the protocol the core already uses) |
| Q2 | Does `generate_release.yml` exist because of a *manual* release, a *scheduled* release, or purely as a mirror of the scheduled `build.yml` release job? | unknown → G6 blocked, G5 only shrinks the matrix job |
| Q3 | Is a shared `skopeo`/`podman`/`oras`/`curl`/`sudo` stub file acceptable under `tests/helpers/`? (new files, no existing file changed) | yes |
| Q4 | Should `build_files/` simplification be attempted at all (DESIGN.md declares it out of scope)? | no |

When cleared, mark G0 `APPROVED <date>` and start G1.

---

## Phase 1 — tests first, no production change

### G1 — test-helper extraction (Q3)

New files only; nothing existing is edited except the suites' `load` lines.

- [ ] `tests/helpers/mock-bin.bash` — `skopeo()`, `podman()`, `oras()`, `curl()`, `sudo()` stubs
      lifted out of `just-helpers.bats:84,143,304` + the 5 `skopeo()` redefinitions
      (155/175/211/227/249) and `push-helpers.bats:28,41`.
      The 5 skopeo overrides differ only by canned output → one `skopeo()` + a
      `skopeo_canned <file>` switch. **Target: 736 → ~500 lines for `just-helpers.bats`,
      400 → ~300 for `check-variants.bats` (17 inline heredoc stubs → 2 canned files).**
- [ ] `tests/helpers/variants-fixture.bash` — `setup_variant_json:101` + the inline JSON
      fixtures repeated in `check-variants.bats` (34 tests hand-write `variants.json`).
- [ ] `tests/helpers/assert-record.bash` — the `IFS=$'\037' read -r …` destructuring assertion
      boilerplate every record test repeats.
- [ ] python: lift `FakeGitHubTransport` / `FakeRegistryTransport` + the 2 manifest factories
      into `tests/changelog_helpers/` (or a `conftest.py` fixture) so the 20 `Test*` classes
      stop re-poking `monkey`/`sys.modules['urllib.request']`.
- [ ] red gate: each helper gets its own 2-line round-trip test before any suite uses it.
- [ ] green gate: all 97 bats + 196 pytest cases still pass, unchanged assertions.

Expected delta: **tests −250..−320 lines, 0 behaviour change.** Rollback = delete helper files
and restore suite bodies (`git revert`).

### G2 — instrumentation becomes a helper (no behaviour change)

- [ ] one `log_github <level> <message>` helper in the umbrella + a `LOG_PREFIX` the helpers
      already thread (`PUSH_LOG_PREFIX`/`VM_LOG_PREFIX`/`CI_LOG_PREFIX`, `DESIGN.md §6`
      decision on the single core + two prefixes).
- [ ] replaces 76 literal `::error::` / `::warning::` / `::group::` interpolations,
      25 of them in `check-variants.sh`, 21 in `push-helpers.bash`.
- [ ] red/green: the `::` output must stay byte-identical for `build.yml` consumers
      (nothing reads them today — `RESEARCH.md §1` — so this is a formatting-identity test,
      not a parsing one).

Expected delta: **−30..−45 lines.** If it does not reach that, skip G2 (ponytail: not worth a
new indirection for 20 lines).

---

## Phase 2 — protocol (the two P0 levers)

### G3 — kill protocol A (the `eval` channel)

Order matters: `resolve_variant` first, because everything else copies it.

- [ ] `resolve_variant` prints **one JSON record** (`variant`, `base_image`,
      `parent_version`, `upstream_tag`, `upstream_version`, `tag_family`,
      `canonical_version`, `collision_detected`, `tags`) — the `variant_record` shape it
      already returns at `check-variants-tags.bash:150` is 90 % of it.
- [ ] callers switch to record access: `build_variant:169` + `run_build:244`
      (`just-helpers-build.bash`, 2 of the 4 `eval` uses), `check_build_needed:260`,
      `extract_image_info`, `extract_final_ref`, `Justfile:47,184,254`.
- [ ] delete `run_fields:100`, `BUILD_FIELDS:25`, `echo_build_assignments:42`,
      `apply_build_record:84`; keep `resolved_variant_record_json:53` **only if**
      a caller still needs globals — otherwise delete it too.
- [ ] **red first:** rewrite the 3 `just-helpers.bats` resolve tests + the
      "stdout stays eval-safe" test (`just-helpers.bats:142/152` `stub_upstream_probe`)
      against the record contract before the implementation exists.
- [ ] green: 47 `just-helpers` + 31 `check-variants` tests, `just build` sanity run.

Expected delta: **−120..−160 lines**, and one protocol gone from the tree
(10 `eval "$()"` → 0). Highest-risk slice; rollback = `git revert` the whole slice,
because `check-variants.sh` is untouched here.

### G4 — one resolution driver (the big P0)

- [ ] `check-variants.sh` per-variant loop calls `resolve_variant` once
      (its own loop already does the same 7 calls — `RESEARCH.md §1` line map),
      then adds only what CI adds: `check_build_needed`, the results array, the `::` logging.
- [ ] the hand-listed 10-field `result=$(jq -n --arg …)` at `check-variants.sh:176` becomes
      a `+` merge of the resolver record + the CI fields → the resolver record **is** the
      artifact shape, so `.github/variants.json` `_schema.output_fields` gets updated in the
      same commit (it is already stale for `digest`/`prev_ref` — `RESEARCH.md §1`).
- [ ] delete `check-variants.sh:112-163` (the inlined resolution) and
      `scripts/just-helpers-variants.bash:46-47`'s private `upstream_tag=`/`upstream_version=`
      globals once `variant_record` carries them.
- [ ] red: `check-variants.bats` gains 2 tests asserting the two drivers agree
      (same fixture → identical `canonical_tag`/`tags`) — that agreement is the bug the
      duplication exists to hide (`DESIGN.md §6` decision 10).
- [ ] green: 31 `check-variants` tests + a real `scripts/check-variants.sh` run against the
      `ublue-os/bazzite` namespace.

Expected delta: **−120..−150 lines.** Rollback = restore `check-variants.sh` body.

### G5 — workflow shrink (independent of G3/G4)

- [ ] `cleanup.yml:31-51` (21 lines of `jq`/`grep`/`sed`/`/tmp`) → one helper call
      (`cleanup_packages [filter]` printing package names; `enabled_variant_names` +
      `package_repo` already own the namespace rules).
- [ ] collapse `cleanup.yml`'s two branches into one filter argument.
- [ ] `aggregate_variants:73` and `preview_tags:81` already exist in `build.yml` — confirm
      `cleanup.yml`'s package identity uses the same derivation, then assert it in a test.
- [ ] if G0/Q2 says the manual release mirrors the scheduled one: fold
      `generate_release.yml` into a `build.yml` job (delete the file, −60 lines).
      Otherwise leave it alone and record that in `DESIGN.md §6` decision 7.

Expected delta: **−35..−60 lines** (workflow files: 344 → ~290).

---

## Phase 3 — entrypoint and pair collapse (cheap, mechanical)

### G6 — `Justfile` recipe pairs + preamble

- [ ] `build-qcow2`/`build-raw` (11 lines each, differ by one literal) →
      `build type qcow2` / `build type raw` calling one recipe.
- [ ] `run-vm-qcow2`/`run-vm-raw` (byte-identical bodies) → same.
- [ ] `rechunk`/`relabel` (r=0.82) and `fix`/`format` (r=0.86) → parameterised pair
      **only if** the parameter is genuinely the only difference; `DESIGN.md §6` keeps
      `relabel` separate for a reason (the `--derived-image`/`-relabeled` distinction is
      load-bearing) — check before merging, and skip if the parameter is not alone.
- [ ] preamble: keep `#!/usr/bin/env bash`+`source` in 25 recipes → 25 one-line delegations
      to a new `scripts/just-helpers.sh` dispatcher (`DESIGN.md §3` "entrypoint files are
      small on purpose: three lines each; a new entrypoint is an addition, not a change"
      — this slice makes that addition real).
- [ ] move the 5 inline `jq -cn --arg` option builders (25 `--arg`) into the helpers that
      already default every field.

Expected delta: **−50..−80 lines**, 329 → ~255. Rollback per recipe pair.

### G7 — the rest of the small cuts (only after G3–G6 are green)

- [ ] markdown table renderer: 3 copies (`preview_tags`, `generate_step_summary:123`,
      `sign_and_verify_image:147`) → one helper; `generate_step_summary` drops its
      per-field-per-row `jq` (5 × N subprocesses) in the process.
- [ ] retry policy: `read_registry_json:75` + `run_with_retry:23` → one policy,
      two thin wrappers (`run_with_retry` keeps the error classifier,
      `read_registry_json` keeps only the JSON-validity rule).
- [ ] `just-helpers.bash:32` `JUST_HELPERS_PUSH` (sourced, never read) → delete.
- [ ] `build_vm_image` / `run_vm` / `run_variant_vm` share the cache-dir + record skeleton
      (~40 lines each) → one `vm_record` + one `vm_cache_dir` helper;
      the `sudo`/`cache_dir` churn (`just-helpers-vm.bash`, 31 refs) collapses with it.
- [ ] `tests/helpers` follow-on: the 3 mock-record builders
      (`build_core_mocks`, `run_variant_mocks`, `release_variant_mocks`, `push_variant_mocks`)
      become `tests/helpers/mock-records.bash`.

Expected delta: **−150..−200 lines.**

---

## Phase 4 — close-out

- [ ] `DESIGN.md` stays current **per green commit**: §6 holds 13 decisions across 95 lines
      (update it for the protocol changes in G3/G4; do not add a decision per paragraph),
      §7's per-suite test counts, and the §2/§3 line counts (they drift with every slice).
- [ ] re-measure `RESEARCH.md §0` (the census table) and record the new totals.
- [ ] §8 open items after the phases: 1 (external `GITHUB_OUTPUT` readers), 2
      (`variants_results.json` handoff), 3 (`/tmp` count 3 → 2 after G5),
      4 (cache-dir default still carries the package literal — untouched by these phases).
- [ ] `RESEARCH.md §4` open items: re-verify 1 (channel C readers), 2 (artifact files),
      3 (`/tmp` count goes 3 → 2 after G5).
- [ ] stop when the census hits ~7,200 lines total; do not chase cosmetics past P2
      (`RESEARCH.md §5` honesty note).

## Deferred / deliberately not done

- `build_files/` near-dupes (P3, `DESIGN.md` out of scope) — G8, only on explicit user request.
- `changelog.py` ↔ `release-preview.py` renderer unification: measured **0 shared lines**;
  they are independent features. Merging them would change user-facing output formats
  (`DESIGN.md §6` decision "GitHub's rendering collapses `\n\n` to `\n`"). Defer, do not invent.
- `test_changelog.py`'s 196 cases: `DESIGN.md §7` names the forced tag-pair case that pins
  one release window — the coverage is the point, shrink only its infrastructure (G1).
- `DESIGN.md`'s own line count: currently 280 lines / 27 decisions, "decision 3 grew into a
  25-line block, and a decision per paragraph is the wrong shape" (`DESIGN.md §8` open item 4)
  — fold only when G3/G4 land, since those decisions change.
