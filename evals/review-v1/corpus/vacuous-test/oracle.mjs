import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const original = spawnSync(process.execPath, ['digest.test.mjs'], { encoding: 'utf8', timeout: 1000 });
if (original.error || original.status !== 0) throw new Error('Original public test did not pass');
await writeFileSync('digest.mjs', 'export async function sendDigest(recipients, deliver) {}\n');
const mutant = spawnSync(process.execPath, ['digest.test.mjs'], { encoding: 'utf8', timeout: 1000 });
if (mutant.error || mutant.signal) throw new Error('Mutation probe did not complete');
if (mutant.status !== 0 && !mutant.stderr.includes('ERR_ASSERTION')) throw new Error('Mutation probe crashed');
const actual = { rejectsNoOpMutant: mutant.status !== 0 };
const expected = { rejectsNoOpMutant: true };
try {
  assert.deepEqual(actual, expected);
  console.log(JSON.stringify({ protocol: 'cadre/oracle@1', status: 'pass' }));
} catch (error) {
  if (!(error instanceof assert.AssertionError)) throw error;
  console.log(JSON.stringify({ protocol: 'cadre/oracle@1', status: 'assertion_failed' }));
  process.exitCode = 1;
}
