#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { runReview, renderReview } from './review.mjs';

const controller = new AbortController();
process.on('SIGTERM', () => controller.abort('SIGTERM'));
process.on('SIGINT', () => controller.abort('SIGINT'));

try {
  const { values } = parseArgs({ options: {
    cwd: { type: 'string' }, model: { type: 'string' }, out: { type: 'string' },
    thinking: { type: 'string', default: 'off' }, timeout: { type: 'string', default: '900' },
  }, allowPositionals: false, strict: true });
  if (!values.cwd || !values.model || !values.out) throw new Error('Required: --cwd DIR --model provider/model --out NEW_DIRECTORY');
  const result = await runReview({
    cwd: resolve(values.cwd), out: resolve(values.out), model: values.model,
    thinking: values.thinking, timeout: Number(values.timeout), prompt: readFileSync(0, 'utf8'), signal: controller.signal,
  });
  process.stdout.write(renderReview(result));
  process.exit(result.status === 'ok' ? 0 : 1);
} catch (error) {
  // CLI validation/file errors only. runReview deliberately does not expose SDK auth errors.
  process.stderr.write(`pi-review: ${error.message}\n`);
  process.exit(1);
}
