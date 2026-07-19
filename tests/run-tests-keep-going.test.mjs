import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const RUNNER = 'scripts/run-tests.mjs';

// The fork's test baseline is "exactly 1 expected failure" (see CLAUDE.md), so
// the runner must keep executing later files and suites after a failure and
// report every failure at the end, instead of aborting at the first red file.
describe('run-tests keep-going', () => {
  it('runs remaining files after a failure and reports all failures at the end', () => {
    const dir = mkdtempSync(join(tmpdir(), 'run-tests-keep-going-'));
    try {
      const failFile = join(dir, 'fail.test.mjs');
      const passFile = join(dir, 'pass.test.mjs');
      writeFileSync(
        failFile,
        "import test from 'node:test';\nimport assert from 'node:assert/strict';\ntest('always fails', () => assert.equal(1, 2));\n"
      );
      writeFileSync(
        passFile,
        "import test from 'node:test';\ntest('always passes', () => {});\n"
      );

      const suitesModule = join(dir, 'suites.mjs');
      writeFileSync(
        suitesModule,
        `export const DEFAULT_SUITES = ['demo'];
export const OPT_IN_SUITES = [];
export const SUITES = {
  demo: {
    description: 'fixture suite: one failing file, then one passing file',
    commands: [
      { runner: 'node', files: ${JSON.stringify([failFile, passFile])} },
    ],
  },
};
export function expandSuites(requested) {
  return requested.length ? requested : DEFAULT_SUITES;
}
`
      );

      const result = spawnSync(process.execPath, [RUNNER, 'demo'], {
        encoding: 'utf8',
        env: cleanEnv(suitesModule),
      });

      const output = `${result.stdout}\n${result.stderr}`;
      assert.equal(result.status, 1, `expected exit 1, got ${result.status}\n${output}`);
      assert.match(output, new RegExp(escapeRegExp(passFile)), 'passing file after the failure should still run');
      assert.match(output, /1 failing command/, 'summary should count failing commands');
      assert.match(output, new RegExp(`failed.*${escapeRegExp(failFile)}`), 'summary should name the failing file');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('exits 0 and prints no failure summary when everything passes', () => {
    const dir = mkdtempSync(join(tmpdir(), 'run-tests-keep-going-'));
    try {
      const passFile = join(dir, 'pass.test.mjs');
      writeFileSync(
        passFile,
        "import test from 'node:test';\ntest('always passes', () => {});\n"
      );

      const suitesModule = join(dir, 'suites.mjs');
      writeFileSync(
        suitesModule,
        `export const DEFAULT_SUITES = ['demo'];
export const OPT_IN_SUITES = [];
export const SUITES = {
  demo: {
    description: 'fixture suite: single passing file',
    commands: [{ runner: 'node', files: ${JSON.stringify([passFile])} }],
  },
};
export function expandSuites(requested) {
  return requested.length ? requested : DEFAULT_SUITES;
}
`
      );

      const result = spawnSync(process.execPath, [RUNNER, 'demo'], {
        encoding: 'utf8',
        env: cleanEnv(suitesModule),
      });

      const output = `${result.stdout}\n${result.stderr}`;
      assert.equal(result.status, 0, `expected exit 0, got ${result.status}\n${output}`);
      assert.doesNotMatch(output, /failing command/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// This test file itself runs under `node --test`, which exports
// NODE_TEST_CONTEXT; if that leaks into the runner's grandchildren they report
// over IPC and exit 0 even when failing, masking the behavior under test.
function cleanEnv(suitesModule) {
  const env = { ...process.env, RUN_TESTS_SUITES_MODULE: suitesModule };
  delete env.NODE_TEST_CONTEXT;
  return env;
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
