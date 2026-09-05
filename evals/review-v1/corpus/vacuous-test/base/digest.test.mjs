import assert from 'node:assert/strict';
import { sendDigest } from './digest.mjs';
const deliveries = [];
await sendDigest([{ id: 'a', subscribed: true }], async id => deliveries.push(id));
assert.deepEqual(deliveries, ['a']);
