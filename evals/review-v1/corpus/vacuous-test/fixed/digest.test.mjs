import assert from 'node:assert/strict';
import { sendDigest } from './digest.mjs';
const recipients = [{ id: 'a', subscribed: true }, { id: 'b', subscribed: false }];
const deliveries = [];
await sendDigest(recipients, async id => deliveries.push(id));
assert.deepEqual(deliveries, ['a']);
