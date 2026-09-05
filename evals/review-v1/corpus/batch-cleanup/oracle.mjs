import assert from 'node:assert/strict';
import { publish } from './publish.mjs';
const staged = new Set();
const stageFailure = new Error('Upload rejected');
let commits = 0;
const storage = {
  async stage(file) {
    if (file === 'reject') throw stageFailure;
    await new Promise(resolve => setTimeout(resolve, 15));
    staged.add(file);
    return file;
  },
  async remove(id) { staged.delete(id); },
  async commit() { commits++; },
};
let rejected = false;
try { await publish(['one', 'reject', 'two'], storage); }
catch (error) { if (error !== stageFailure) throw error; rejected = true; }
await new Promise(resolve => setTimeout(resolve, 30));
const actual = { rejected, commits, remaining: [...staged].sort() };
const expected = { rejected: true, commits: 0, remaining: [] };
try {
  assert.deepEqual(actual, expected);
  console.log(JSON.stringify({ protocol: 'cadre/oracle@1', status: 'pass' }));
} catch (error) {
  if (!(error instanceof assert.AssertionError)) throw error;
  console.log(JSON.stringify({ protocol: 'cadre/oracle@1', status: 'assertion_failed' }));
  process.exitCode = 1;
}
