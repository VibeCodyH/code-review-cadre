import assert from 'node:assert/strict';
import { updateDraft } from './drafts.mjs';
let draft = { id: 'draft', title: 'Original', revision: 1 };
const store = {
  async get() { return { ...draft }; },
  async put(id, value) { draft = { ...value }; },
  async compareAndSwap(id, revision, patch) {
    if (draft.revision !== revision) return false;
    draft = { ...draft, ...patch, revision: revision + 1 };
    return true;
  },
};
const results = await Promise.all([
  updateDraft(store, 'draft', 1, { title: 'First' }),
  updateDraft(store, 'draft', 1, { title: 'Second' }),
]);
const actual = { accepted: results.filter(Boolean).length, revision: draft.revision };
const expected = { accepted: 1, revision: 2 };
try {
  assert.deepEqual(actual, expected);
  console.log(JSON.stringify({ protocol: 'cadre/oracle@1', status: 'pass' }));
} catch (error) {
  if (!(error instanceof assert.AssertionError)) throw error;
  console.log(JSON.stringify({ protocol: 'cadre/oracle@1', status: 'assertion_failed' }));
  process.exitCode = 1;
}
