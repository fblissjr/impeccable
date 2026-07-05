#!/usr/bin/env bash
#
# sync-upstream.sh — merge upstream (pbakaus/impeccable) into this personal fork
# and deterministically re-apply the two fork overrides documented in CLAUDE.md:
#
#   1. plugin/hooks/hooks.json is deleted (no marketplace PostToolUse hook).
#   2. plugin/skills/impeccable/SKILL.md references bundled scripts as
#      ${CLAUDE_SKILL_DIR}/scripts/... (never .claude/skills/impeccable/scripts/...).
#
# It NEVER pushes and NEVER runs the build (running scripts/build.js would
# regenerate plugin/ and revert both overrides). If the merge produces a
# conflict other than the known hooks.json one, it stops and hands off to you.
#
# Usage:
#   scripts/sync-upstream.sh              # fetch, merge, re-apply overrides, commit
#   scripts/sync-upstream.sh --no-commit  # leave the resolved merge staged for review
#
set -euo pipefail

UPSTREAM_URL="git@github.com:pbakaus/impeccable.git"
UPSTREAM_REF="upstream/main"
SKILL="plugin/skills/impeccable/SKILL.md"
HOOKS="plugin/hooks/hooks.json"

DO_COMMIT=1
[ "${1:-}" = "--no-commit" ] && DO_COMMIT=0

cd "$(git rev-parse --show-toplevel)"

# --- preconditions ---------------------------------------------------------
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree is dirty. Commit or stash first." >&2
  exit 1
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "adding upstream remote -> $UPSTREAM_URL"
  git remote add upstream "$UPSTREAM_URL"
fi

git fetch upstream

if [ -z "$(git rev-list "HEAD..$UPSTREAM_REF")" ]; then
  echo "already up to date with $UPSTREAM_REF; nothing to merge."
  exit 0
fi

echo "merging $UPSTREAM_REF ($(git rev-list --count "HEAD..$UPSTREAM_REF") new commit(s))..."

BEFORE="$(git rev-parse HEAD)"

# --- merge (tolerate the expected conflict) --------------------------------
set +e
git merge --no-ff --no-commit "$UPSTREAM_REF" >/dev/null 2>&1
set -e

# --- re-apply overrides unconditionally (idempotent / self-healing) --------
# Override 1: keep hooks.json deleted, whether it conflicted or merged clean.
git rm -f --ignore-unmatch "$HOOKS" >/dev/null 2>&1 || true
rm -f "$HOOKS"

# Override 2: normalize every project-relative script path back to the token.
if [ -f "$SKILL" ]; then
  perl -0pi -e 's{\.claude/skills/impeccable/scripts/}{\${CLAUDE_SKILL_DIR}/scripts/}g' "$SKILL"
  git add "$SKILL"
fi

# --- bail if anything OTHER than the known override remains unmerged --------
REMAINING="$(git diff --name-only --diff-filter=U)"
if [ -n "$REMAINING" ]; then
  echo "" >&2
  echo "Unresolved conflicts beyond the known fork overrides — resolve these by hand:" >&2
  echo "$REMAINING" | sed 's/^/  /' >&2
  echo "" >&2
  echo "Then: git add <files> && git commit   (the overrides are already re-applied)" >&2
  exit 2
fi

# --- verify the overrides actually took ------------------------------------
FAIL=0
if [ -f "$HOOKS" ]; then
  echo "verify FAILED: $HOOKS still exists" >&2; FAIL=1
fi
if grep -q '\.claude/skills/impeccable/scripts/' "$SKILL" 2>/dev/null; then
  echo "verify FAILED: $SKILL still has project-relative script paths" >&2; FAIL=1
fi
[ "$FAIL" -eq 1 ] && exit 3

# --- sync deps if the merge moved package.json / bun.lock ------------------
# (compare the merged tree against the pre-merge HEAD; covers both commit and
# --no-commit modes since it diffs against a SHA, not the index.)
if [ -n "$(git diff --name-only "$BEFORE" -- package.json bun.lock)" ]; then
  echo "package.json/bun.lock changed upstream; running bun install..."
  bun install
fi

# --- finish ----------------------------------------------------------------
if [ "$DO_COMMIT" -eq 0 ]; then
  echo "merge resolved and overrides re-applied; staged but NOT committed (--no-commit)."
  echo "review with: git diff --cached --stat"
  exit 0
fi

git commit --no-edit -m "Merge $UPSTREAM_REF into personal fork" -m \
"Re-applied fork overrides: deleted $HOOKS, kept \${CLAUDE_SKILL_DIR}/scripts paths in SKILL.md." \
  >/dev/null

echo ""
echo "Done. Merged $UPSTREAM_REF and re-applied both overrides."
echo "NOT pushed. Review, then: git push origin main"
