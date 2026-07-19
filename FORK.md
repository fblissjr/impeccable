# Fork notes (`fblissjr/impeccable`)

Personal fork of `pbakaus/impeccable`. It carries intentional deviations from upstream; do not "fix" or rebuild them away. `CLAUDE.md` keeps the short operative rules at the top; this file is the full story — what each deviation is, why it exists, how it survives upstream merges, and what was learned along the way.

## Deviations 1 and 2: `plugin/` overrides (not reproducible by the build)

`plugin/` is generated from `skill/` by `scripts/build.js`, but this fork applies two overrides directly in `plugin/` (not in the source, so no build can reproduce them):

1. `plugin/hooks/hooks.json` is **deleted**, so a marketplace `/plugin install` never registers the PostToolUse detector hook. On-demand `/impeccable audit` is unaffected.
2. `plugin/skills/impeccable/SKILL.md` references bundled scripts as `${CLAUDE_SKILL_DIR}/scripts/...` (not `.claude/skills/impeccable/scripts/...`), so they resolve from a marketplace install.

### Which builds are safe

- **Safe:** `bun run build` and `bun run build:skills` — both pass `--skip-root-sync` to `scripts/build.js`, which skips the root-harness and `plugin/` sync entirely. Verified: running `build:skills` leaves both overrides intact.
- **Destructive to the overrides:** `bun run build:release`, `bun run rebuild:release`, or running `scripts/build.js` directly without `--skip-root-sync`. These regenerate `plugin/` (recreating `hooks.json` and the project-relative script paths) and revert both overrides.

If the overrides ever get reverted (by a release build or a merge of upstream's regenerated provider output), re-apply: delete `plugin/hooks/hooks.json` and re-point the SKILL.md script paths to `${CLAUDE_SKILL_DIR}/scripts`.

## Syncing upstream

Run `scripts/sync-upstream.sh`. It adds the `upstream` remote if missing, fetches, merges `upstream/main`, re-applies both `plugin/` overrides deterministically, and runs `bun install` when the merge changes `package.json`/`bun.lock`. It does not build and does not push. If the merge hits a conflict other than the known `hooks.json` one, it stops and hands off for manual resolution.

Before committing, the sync verifies both overrides via `scripts/check-fork-overrides.mjs` (run it standalone any time: `bun scripts/check-fork-overrides.mjs`). It is a *positive* invariant check: it asserts `hooks.json` is absent and that **every** `scripts/` path in the plugin `SKILL.md` is rooted at `${CLAUDE_SKILL_DIR}/`. If upstream restructures those paths into a form the blanket rewrite does not catch, the check fails loudly and names the offending line — that is the signal to update the rewrite rule in `sync-upstream.sh`.

## Deviation 3: keep-going test runner

Upstream's `scripts/run-tests.mjs` exits at the first failing test file. On this fork that would truncate every `bun run test` at the expected permanent failure (below) and silently skip the remaining suites. The fork patches the runner to run everything, print a `N failing command(s)` summary at the end, and exit non-zero only then. The suites module is injectable via the `RUN_TESTS_SUITES_MODULE` env var so `tests/run-tests-keep-going.test.mjs` (registered in the core suite) can exercise the behavior with fixture suites.

Unlike the `plugin/` overrides, this is a normal tracked source edit: upstream merges surface it as an ordinary conflict in `scripts/run-tests.mjs`. Resolve by keeping the fork's behavior — the failure-collection loop is the part that matters; the injection seam exists only for the test and can be re-shaped if upstream restructures the runner.

## Deviation 4: CI generated-output sync excludes `plugin/`

`.github/workflows/sync-generated-output.yml` runs `bun run build:release` on pushes to `main` and commits regenerated provider output back. On this fork its `GENERATED_PATHS` list deliberately omits `plugin` (see the PERSONAL FORK comment in the workflow): letting CI commit `plugin/` would clobber deviations 1 and 2 on every source push. `plugin/` is managed by `scripts/sync-upstream.sh` here, not CI. On upstream merges that touch this workflow, keep the omission.

Relatedly, upstream's **Versioning** and **Releases** sections in `CLAUDE.md` instruct running `bun run build:release` as a release step. Those workflows apply upstream (`pbakaus/impeccable`), where releases are actually cut — not on this fork. Here the never-run rule wins.

## Test baseline: exactly 1 failure = clean

`tests/hook-build.test.mjs` → "packages the Claude design hook in the plugin via plugin-root paths" asserts `plugin/hooks/hooks.json` exists — but deviation 1 deletes that file, and regenerating it would revert the override. So this one test is permanently red here and cannot pass without breaking the fork. A clean `bun run test` ends with:

```
1 failing command(s):
  failed: node --test tests/hook-build.test.mjs
```

Treat the count as the signal: **1 failure = clean, 2+ failures = a real regression to investigate.** `check-fork-overrides.mjs` is the fork's authoritative gate; this upstream test is not.

If a future upstream merge takes the failure count to **0**, upstream renamed or removed that test — the baseline shifted, so update this note (new expected count, or delete it) rather than assuming the suite silently improved.

## Environment gotchas (lessons learned)

- **`bun run` silently substitutes itself for `node`** when no real node binary is visible on PATH: it prepends a temp `bun-node-*` shim dir, which child processes inherit. Symptom in this repo: the `node --test` half of `bun run test` crashes with "Cannot use describe outside of the test runner. Run \"bun test\"". The fix is environmental — make a real node visible to non-interactive shells (lazy-loading version managers only define `node` in interactive sessions). Any `bun run` script that shells out to `node` is exposed to the same substitution.
- **Nested `node --test` runs need a scrubbed env.** The node test runner exports `NODE_TEST_CONTEXT`; if a test spawns a process that itself runs `node --test`, the grandchildren inherit it, report over IPC, and exit 0 even on failure. `tests/run-tests-keep-going.test.mjs` deletes the var before spawning for exactly this reason.

## Telemetry

The daily version-check ping in `context.mjs` is off when `IMPECCABLE_NO_UPDATE_CHECK=1` is set (add `export IMPECCABLE_NO_UPDATE_CHECK=1` to your shell rc).
