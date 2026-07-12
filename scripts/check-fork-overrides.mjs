#!/usr/bin/env bun
//
// check-fork-overrides.mjs — assert the two personal-fork overrides hold.
//
// This is a POSITIVE invariant check, not a "does the old bad pattern still
// exist" check. It catches an upstream restructure that our sync rewrite rule
// silently would not touch (e.g. a new path prefix or a moved scripts dir),
// which a negative grep for `.claude/skills/impeccable/scripts/` cannot.
//
// Invariants:
//   1. plugin/hooks/hooks.json does NOT exist.
//   2. In plugin/skills/impeccable/SKILL.md, every `scripts/<file>` path
//      reference is rooted at exactly `${CLAUDE_SKILL_DIR}/`, OR at the literal
//      `<skill-base-dir>/` runtime-substitution placeholder upstream documents as
//      the fallback for that same token — no other prefix (project-relative,
//      ${CLAUDE_PROJECT_DIR}, bare, or anything new).
//   3. SKILL.md still contains at least one `${CLAUDE_SKILL_DIR}/scripts/`
//      reference. If it drops to zero, the scripts dir was likely renamed or
//      the reference style changed structurally — a human should re-check the
//      override rule in scripts/sync-upstream.sh.
//
// Exit 0 = overrides intact. Exit 1 = a violation a human must look at.
//
// Usage: bun scripts/check-fork-overrides.mjs
//
import { existsSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const ROOT = execFileSync('git', ['rev-parse', '--show-toplevel']).toString().trim();
const HOOKS = 'plugin/hooks/hooks.json';
const SKILL = 'plugin/skills/impeccable/SKILL.md';
// `${CLAUDE_SKILL_DIR}/` is the fork's canonical token. `<skill-base-dir>/` is the
// literal placeholder upstream added as the runtime-resolved fallback for that same
// directory (SKILL.md step 1); it is install-correct, not a hardcoded project path,
// so the fork keeps it verbatim rather than forking the sentence.
const WANT_PREFIXES = ['${CLAUDE_SKILL_DIR}/', '<skill-base-dir>/'];

// A path token ending in `scripts/<file-or-glob>`, plus everything up to the
// nearest boundary (whitespace, backtick, quote, paren) before `scripts/`.
const SCRIPT_REF = /([^\s`'"()]*)scripts\/([A-Za-z0-9._*-]+)/g;

const problems = [];

// Invariant 1
if (existsSync(`${ROOT}/${HOOKS}`)) {
  problems.push(`${HOOKS} exists but the fork deletes it (marketplace hook must not register).`);
}

// Invariants 2 + 3
if (!existsSync(`${ROOT}/${SKILL}`)) {
  problems.push(`${SKILL} is missing; cannot verify script-path override.`);
} else {
  const lines = readFileSync(`${ROOT}/${SKILL}`, 'utf8').split('\n');
  let rootedCount = 0;
  lines.forEach((line, i) => {
    for (const m of line.matchAll(SCRIPT_REF)) {
      const prefix = m[1];
      // rootedCount tracks the canonical token specifically (invariant 3): the
      // `<skill-base-dir>/` fallback alone must never satisfy "the token is present".
      if (prefix === '${CLAUDE_SKILL_DIR}/') {
        rootedCount++;
      } else if (!WANT_PREFIXES.includes(prefix)) {
        problems.push(
          `${SKILL}:${i + 1}: script path "${m[0]}" is not rooted at ` +
          `\${CLAUDE_SKILL_DIR}/ or <skill-base-dir>/ (prefix was "${prefix || '<none>'}"). ` +
          `The sync rewrite rule did not normalize it — upstream likely ` +
          `changed the path form; update scripts/sync-upstream.sh.`
        );
      }
    }
  });
  if (rootedCount === 0 && !problems.some((p) => p.startsWith(SKILL))) {
    problems.push(
      `${SKILL}: no \${CLAUDE_SKILL_DIR}/scripts/ references found at all. ` +
      `The scripts dir may have been renamed or the reference style changed; ` +
      `re-check the override rule in scripts/sync-upstream.sh.`
    );
  }
}

if (problems.length) {
  console.error('Fork-override check FAILED:');
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}

console.log('Fork overrides intact: hooks.json deleted, all SKILL.md script paths on ${CLAUDE_SKILL_DIR}/scripts/.');
