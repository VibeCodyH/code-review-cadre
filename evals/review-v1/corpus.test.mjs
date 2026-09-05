import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { DEFAULT_CORPUS_DIR, verifyCorpus } from './verify-corpus.mjs';

function temporaryCorpus(t) {
  const directory = mkdtempSync(join(tmpdir(), 'cadre-corpus-test-'));
  cpSync(DEFAULT_CORPUS_DIR, directory, { recursive: true });
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}

// Updating a test copy's digest lets these tests exercise the behavioral gate,
// independently of the gate that freezes the checked-in fixture bytes.
function replaceAndRehash(directory, relative, body) {
  writeFileSync(join(directory, relative), body);
  const manifestPath = join(directory, 'manifest.json');
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  manifest.hashes[relative] = createHash('sha256').update(body).digest('hex');
  writeFileSync(manifestPath, JSON.stringify(manifest));
}

test('frozen original corpus has four behavioral red/green pairs', () => {
  const results = verifyCorpus();
  assert.equal(results.length, 8);
  assert.equal(results.filter(result => result.actual === 'assertion_failed').length, 4);
  assert.equal(results.filter(result => result.actual === 'pass').length, 4);
  assert.ok(results.every(result => result.ok));
});

test('changed fixture bytes are rejected before running oracles', t => {
  const directory = temporaryCorpus(t);
  writeFileSync(join(directory, 'tenant-scope/target/documents.mjs'), '// drift\n');
  assert.throws(() => verifyCorpus(directory), /Corpus hash mismatch/);
});

test('an erroneously green buggy arm is rejected even with matching hashes', t => {
  const directory = temporaryCorpus(t);
  replaceAndRehash(directory, 'tenant-scope/target/documents.mjs',
    readFileSync(join(directory, 'tenant-scope/fixed/documents.mjs'), 'utf8'));
  assert.throws(() => verifyCorpus(directory), /expected assertion_failed, got pass/);
});

test('runtime crashes cannot masquerade as expected red', t => {
  const directory = temporaryCorpus(t);
  replaceAndRehash(directory, 'tenant-scope/oracle.mjs', "throw new Error('oracle crashed');\n");
  assert.throws(() => verifyCorpus(directory), /Oracle crashed or produced invalid output/);
});

test('module syntax and import failures cannot masquerade as expected red', t => {
  for (const body of ['export async function {', "import './missing.mjs';"]) {
    const directory = temporaryCorpus(t);
    replaceAndRehash(directory, 'tenant-scope/target/documents.mjs', body + '\n\n');
    assert.throws(() => verifyCorpus(directory), /Oracle crashed or produced invalid output/);
  }
});

test('extra untracked fixture files are rejected', t => {
  const directory = temporaryCorpus(t);
  writeFileSync(join(directory, 'tenant-scope/target/extra.txt'), 'unexpected');
  assert.throws(() => verifyCorpus(directory), /Corpus hash inventory mismatch/);
});
