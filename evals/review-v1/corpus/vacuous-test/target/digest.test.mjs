import assert from 'node:assert/strict';
import { sendDigest } from './digest.mjs';
const recipients = [{ id: 'a', subscribed: false }, { id: 'b', subscribed: false }];
const deliveries = [];
await sendDigest(recipients, async id => deliveries.push(id));
assert.ok(deliveries.every(id => recipients.find(recipient => recipient.id === id).subscribed));
