#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { cpSync, lstatSync, mkdtempSync, readFileSync, readdirSync, rmSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const DEFAULT_CORPUS_DIR = fileURLToPath(new URL('./corpus/', import.meta.url));

function inventory(root, prefix = '') {
  return readdirSync(join(root, prefix)).sort().flatMap(name => {
    const relative = prefix ? `${prefix}/${name}` : name;
    const stat = lstatSync(join(root, relative));
    if (stat.isSymbolicLink()) throw new Error(`Corpus symlink is forbidden: ${relative}`);
    if (stat.isDirectory()) return inventory(root, relative);
    if (!stat.isFile()) throw new Error(`Unsupported corpus entry: ${relative}`);
    return [relative];
  });
}

function localPath(root, relative) {
  if (typeof relative !== 'string' || !/^[a-zA-Z0-9_./-]+$/.test(relative)) {
    throw new Error(`Invalid corpus path: ${relative}`);
  }
  const full = resolve(root, relative);
  if (!full.startsWith(`${root}${sep}`)) throw new Error(`Corpus path escapes root: ${relative}`);
  return full;
}

export function verifyCorpus(corpusDir = DEFAULT_CORPUS_DIR) {
  const root = resolve(corpusDir);
  const files = inventory(root).filter(name => name !== 'manifest.json');
  const manifest = JSON.parse(readFileSync(join(root, 'manifest.json'), 'utf8'));
  if (manifest.schema !== 'cadre/review-corpus@1' || !Array.isArray(manifest.cases) || !manifest.cases.length) {
    throw new Error('Invalid review corpus manifest');
  }
  if (!manifest.hashes || JSON.stringify(Object.keys(manifest.hashes).sort()) !== JSON.stringify(files.sort())) {
    throw new Error('Corpus hash inventory mismatch');
  }
  for (const file of files) {
    const hash = createHash('sha256').update(readFileSync(join(root, file))).digest('hex');
    if (hash !== manifest.hashes[file]) throw new Error(`Corpus hash mismatch: ${file}`);
  }
  const ids = new Set();
  const pairs = new Map();
  for (const entry of manifest.cases) {
    if (!/^[a-z0-9][a-z0-9-]*$/.test(entry.id) || ids.has(entry.id)) throw new Error('Invalid or duplicate case id');
    ids.add(entry.id);
    if (!/^[a-z0-9][a-z0-9-]*$/.test(entry.scenario) || !['buggy', 'fixed'].includes(entry.variant) ||
        !['development', 'holdout'].includes(entry.split)) throw new Error(`Invalid case: ${entry.id}`);
    for (const field of ['base', 'target', 'oracle']) localPath(root, entry[field]);
    if (entry.base !== `${entry.scenario}/base` ||
        entry.target !== `${entry.scenario}/${entry.variant === 'buggy' ? 'target' : 'fixed'}` ||
        entry.oracle !== `${entry.scenario}/oracle.mjs`) throw new Error(`Invalid case layout: ${entry.id}`);
    if (!lstatSync(localPath(root, entry.base)).isDirectory() || !lstatSync(localPath(root, entry.target)).isDirectory()) {
      throw new Error(`Missing case tree: ${entry.id}`);
    }
    if (entry.variant === 'fixed' ? entry.key !== null : !entry.key || !entry.key.id || !entry.key.claim ||
        !entry.key.trigger || !entry.key.consequence || !['blocking', 'should-fix', 'nit'].includes(entry.key.severity) ||
        !Number.isInteger(entry.key.line) || entry.key.line < 1) throw new Error(`Invalid provisional key: ${entry.id}`);
    if (entry.key) {
      const target = localPath(root, entry.target);
      const source = readFileSync(localPath(target, entry.key.path), 'utf8');
      if (entry.key.line > source.split('\n').length) throw new Error(`Key line outside file: ${entry.id}`);
    }
    const pair = pairs.get(entry.scenario) || [];
    pair.push(entry);
    pairs.set(entry.scenario, pair);
  }
  for (const [scenario, pair] of pairs) {
    if (pair.length !== 2 || new Set(pair.map(entry => entry.variant)).size !== 2 ||
        pair[0].oracle !== pair[1].oracle || pair[0].split !== pair[1].split) {
      throw new Error(`Missing consistent buggy/fixed pair: ${scenario}`);
    }
  }
  return manifest.cases.map(entry => {
    const temporary = mkdtempSync(join(tmpdir(), 'cadre-corpus-'));
    try {
      cpSync(localPath(root, entry.target), temporary, { recursive: true });
      copyFileSync(localPath(root, entry.oracle), join(temporary, '__verify.mjs'));
      const child = spawnSync(process.execPath, ['__verify.mjs'], {
        cwd: temporary, encoding: 'utf8', timeout: 5000, maxBuffer: 1024 * 1024,
      });
      if (child.error || child.signal) throw new Error(`Oracle did not complete for ${entry.id}: ${child.error?.code || child.signal}`);
      let report;
      try { report = JSON.parse(child.stdout.trim()); }
      catch { throw new Error(`Oracle crashed or produced invalid output for ${entry.id}: ${child.stderr.trim()}`); }
      if (report.protocol !== 'cadre/oracle@1' || !['pass', 'assertion_failed'].includes(report.status) ||
          child.status !== (report.status === 'pass' ? 0 : 1) || child.stderr.trim()) {
        throw new Error(`Oracle protocol/runtime failure for ${entry.id}`);
      }
      const expected = entry.variant === 'buggy' ? 'assertion_failed' : 'pass';
      if (report.status !== expected) throw new Error(`Oracle behavior mismatch for ${entry.id}: expected ${expected}, got ${report.status}`);
      return { id: entry.id, variant: entry.variant, expected, actual: report.status, ok: true };
    } finally {
      rmSync(temporary, { recursive: true, force: true });
    }
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const results = verifyCorpus(process.argv[2]);
    console.log(JSON.stringify({ schema: 'cadre/corpus-verification@1', ok: true, results }, null, 2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
