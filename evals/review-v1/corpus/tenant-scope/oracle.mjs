import assert from 'node:assert/strict';
import { renameDocument } from './documents.mjs';
let document = { id: 'shared-id', tenantId: 'tenant-b', title: 'Original' };
let saves = 0;
const store = {
  async find(query) {
    return Object.entries(query).every(([key, value]) => document[key] === value) ? { ...document } : null;
  },
  async save(value) { saves++; document = value; return value; },
};
try {
  await renameDocument(store, { tenantId: 'tenant-a' }, document.id, 'Changed');
} catch (error) {
  if (error.message !== 'Document not found') throw error;
}
const actual = { saves, title: document.title };
const expected = { saves: 0, title: 'Original' };
try {
  assert.deepEqual(actual, expected);
  console.log(JSON.stringify({ protocol: 'cadre/oracle@1', status: 'pass' }));
} catch (error) {
  if (!(error instanceof assert.AssertionError)) throw error;
  console.log(JSON.stringify({ protocol: 'cadre/oracle@1', status: 'assertion_failed' }));
  process.exitCode = 1;
}
