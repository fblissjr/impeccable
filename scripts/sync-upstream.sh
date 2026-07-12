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

# Override 2: the fork's plugin SKILL.md is upstream's SKILL.md plus exactly two
# deterministic transforms — (a) every bundled-script path rewritten to the
# ${CLAUDE_SKILL_DIR}/ token, and (b) one fork-authored "Bundled scripts live in ..."
# preamble paragraph. Resolving conflict markers in place is brittle (it breaks the
# moment upstream rewrites a step region), so instead reconstruct the file from
# upstream's content and re-derive both transforms. This is correct whether the
# merge conflicted or merged clean, and it never leaves markers behind.
SKILL_ANCHOR='You MUST do these steps before proceeding:'
if git cat-file -e "$UPSTREAM_REF:$SKILL" 2>/dev/null; then
  git show "$UPSTREAM_REF:$SKILL" > "$SKILL"

  # (a) path token — normalize the project-relative form to ${CLAUDE_SKILL_DIR}/.
  perl -0pi -e 's{\.claude/skills/impeccable/scripts/}{\${CLAUDE_SKILL_DIR}/scripts/}g' "$SKILL"

  # (b) preamble — insert after the Setup anchor line and its trailing blank, unless
  # it's already present. Quoted heredoc: the ${...} token and backticks stay literal.
  if ! grep -qF 'Bundled scripts live in' "$SKILL"; then
    PREAMBLE_FILE="$(mktemp)"
    cat > "$PREAMBLE_FILE" <<'PREAMBLE_EOF'
**Bundled scripts live in `${CLAUDE_SKILL_DIR}/scripts/`** — that token resolves to this skill's own directory whether it's installed project-locally or via a plugin marketplace, so the commands below work regardless of the current working directory. If a `reference/*.md` doc writes a script path rooted at `.claude/skills/impeccable/`, treat it as `${CLAUDE_SKILL_DIR}/` instead (same script, install-correct path).
PREAMBLE_EOF
    # Slurp-mode insertion preserves the file's exact byte layout (including
    # upstream's lack of a trailing newline). chomp is a no-op under -0777 ($/ is
    # undef), so strip the preamble's trailing newline with a regex.
    SKILL_ANCHOR="$SKILL_ANCHOR" PREAMBLE_FILE="$PREAMBLE_FILE" \
    perl -0777 -i -pe '
      BEGIN { local $/; open my $f, "<", $ENV{PREAMBLE_FILE} or die; $pre = <$f>; close $f; $pre =~ s/\n+\z//; }
      s/(\Q$ENV{SKILL_ANCHOR}\E\n\n)/$1 . $pre . "\n\n"/e;
    ' "$SKILL"
    rm -f "$PREAMBLE_FILE"
  fi

  # If the preamble still isn't there, the anchor moved: hand off rather than ship a
  # SKILL.md missing the fork override. (check-fork-overrides.mjs below is the backstop
  # for the path token; this guards the preamble, which the check does not police.)
  if ! grep -qF 'Bundled scripts live in' "$SKILL"; then
    echo "" >&2
    echo "Could not find the Setup anchor to insert the fork preamble in $SKILL." >&2
    echo "Upstream likely reworded \"$SKILL_ANCHOR\"." >&2
    echo "Insert the preamble by hand and update SKILL_ANCHOR in scripts/sync-upstream.sh," >&2
    echo "then: node scripts/check-fork-overrides.mjs && git add $SKILL && git commit" >&2
    echo "" >&2
    exit 2
  fi

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
# Positive invariant check: every SKILL.md script path must be rooted at
# ${CLAUDE_SKILL_DIR}/. This catches an upstream restructure into a new path
# form that the blanket rewrite above silently would not touch.
#
# Resolve a JS runtime rather than assuming bare `node`: interactive shells
# often expose `node` only as an nvm/asdf lazy-load function, which is invisible
# to this non-interactive script. `bun` is a real binary already required below
# (bun install) and runs the .mjs check fine, so fall back to it.
if command -v node >/dev/null 2>&1; then
  JS_RUNTIME=node
elif command -v bun >/dev/null 2>&1; then
  JS_RUNTIME=bun
else
  echo "error: neither node nor bun found on PATH." >&2
  echo "Load your node version manager (nvm/asdf) or install bun, then re-run." >&2
  exit 1
fi

if ! "$JS_RUNTIME" scripts/check-fork-overrides.mjs; then
  echo "" >&2
  echo "Override verification failed after the merge — stopping before commit." >&2
  echo "Upstream likely changed how SKILL.md references bundled scripts." >&2
  echo "Fix the rewrite rule above, then re-run, or resolve by hand." >&2
  exit 3
fi

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
