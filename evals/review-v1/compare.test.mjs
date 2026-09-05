import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { compare, parseArgs, parseStock, preflightModel, prepareCheckout, settings } from './compare.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const temp = () => mkdtempSync(join(tmpdir(), 'cadre-comparison-test-'));
const message = (text, stopReason = 'stop') => ({ type: 'message_end', message: {
  role: 'assistant', model: 'model', provider: 'provider', stopReason,
  content: [{ type: 'text', text }], usage: { input: 10, output: 5, cacheRead: 0, cacheWrite: 0, totalTokens: 15 },
} });
const stream = (...events) => events.map(JSON.stringify).join('\n') + '\n';

test('stock exit zero cannot conceal a provider error or incomplete stream', () => {
  assert.equal(parseStock(stream(message('', 'error'), { type: 'agent_end' }), 0).status, 'failed');
  assert.equal(parseStock(stream(message('Verdict: no defects found')), 0).status, 'degraded');
  assert.equal(parseStock(stream(message('Verdict: no defects found'), { type: 'agent_end' }) + '{', 0).status, 'degraded');
});

test('stock clean requires explicit conclusion and complete terminal event', () => {
  const valid = parseStock(stream(message('Verdict: no defects found'), { type: 'agent_end' }), 0);
  assert.equal(valid.status, 'ok'); assert.equal(valid.usage.totalTokens, 15);
  assert.equal(parseStock(stream(message('I examined the files.'), { type: 'agent_end' }), 0).status, 'inconclusive');
  assert.equal(parseStock(stream(message('Verdict: no defects found'), { type: 'agent_end' }), 124, true).status, 'degraded');
});

test('stock verdict accepts equivalent bold Markdown without changing review evidence', () => {
  for (const verdict of [
    'Verdict: blocking', '**Verdict: blocking**', '**Verdict:** blocking', 'Verdict: **blocking**',
    '__Verdict: blocking__', '__Verdict:__ blocking', 'Verdict: __blocking__', '  **vErDiCt: BLOCKING**  ',
  ]) {
    const review = `Concrete tenant bypass finding.\n\n${verdict}\n\nThe lookup lost its tenant predicate.`;
    const result = parseStock(stream(message(review), { type: 'agent_end' }), 0);
    assert.equal(result.status, 'ok', verdict);
    assert.equal(result.verdict, 'blocking', verdict);
    assert.equal(result.review, review);
  }
});

test('stock verdict ignores quoted and code examples and rejects conflicting conclusions', () => {
  for (const review of [
    '> **Verdict: no defects found**',
    '```markdown\nVerdict: no defects found\n```',
    '~~~\n**Verdict: no defects found**\n~~~',
    '````\n```\nVerdict: no defects found\n````',
    '    Verdict: no defects found',
    '\tVerdict: no defects found',
    '`Verdict: no defects found`',
    'Verdict: no defects found\n**Verdict: blocking**',
  ]) {
    const result = parseStock(stream(message(review), { type: 'agent_end' }), 0);
    assert.equal(result.status, 'inconclusive', review);
    assert.equal(result.verdict, null, review);
  }
  const review = '> Verdict: no defects found\n```\nVerdict: no defects found\n```\n**Verdict: blocking**';
  assert.equal(parseStock(stream(message(review), { type: 'agent_end' }), 0).verdict, 'blocking');
});

test('formatted verdict never rescues a timed out, failed, or truncated stock run', () => {
  for (const [exitCode, timedOut, stopReason] of [[124, true, 'stop'], [1, false, 'stop'], [0, false, 'length']]) {
    const result = parseStock(stream(message('**Verdict: no defects found**', stopReason), { type: 'agent_end' }), exitCode, timedOut);
    assert.equal(result.status, 'degraded');
  }
});

test('CLI refuses unknown flags, fractional runs and implicit model', () => {
  for (const args of [[], ['--model', 'model', '--out', '/tmp/x'], ['--model', 'p/m', '--out', '/tmp/x', '--runs', '1.5'], ['--mystery', 'x']]) {
    assert.throws(() => parseArgs(args));
  }
});

test('real SDK preflight rejects unsupported thinking before either model arm runs', async () => {
  const work = temp();
  try {
    writeFileSync(join(work, 'models.json'), JSON.stringify({ providers: { fixture: {
      baseUrl: 'https://example.invalid/v1', api: 'openai-completions', apiKey: 'unused-fixture-key',
      models: [{ id: 'plain', name: 'Fixture', reasoning: false, input: ['text'], contextWindow: 8192, maxTokens: 1024,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
    } } }));
    const pkgDir = join(here, '../../integrations/pi-review/node_modules/@earendil-works/pi-coding-agent');
    await assert.rejects(() => preflightModel(pkgDir, work, 'fixture/plain', 'high'), /unsupported/);
    const result = await preflightModel(pkgDir, work, 'fixture/plain', 'off');
    assert.deepEqual(result, { provider: 'fixture', model: 'plain', effective_thinking: 'off' });
  } finally { rmSync(work, { recursive: true, force: true }); }
});

test('paired checkouts have identical commits and no key or oracle', () => {
  const work = temp();
  try {
    const corpus = join(here, 'corpus');
    const item = JSON.parse(readFileSync(join(corpus, 'manifest.json'))).cases[0];
    const first = prepareCheckout(corpus, item, join(work, 'one'));
    const second = prepareCheckout(corpus, item, join(work, 'two'));
    assert.deepEqual(first, second);
    assert.deepEqual(readdirSync(join(work, 'one')).sort(), ['.git', 'README.md', 'documents.mjs']);
    assert.equal(existsSync(join(work, 'one/oracle.mjs')), false);
  } finally { rmSync(work, { recursive: true, force: true }); }
});

test('comparison persists invalid model and destroyed checkout, hides case labels from both arms', async () => {
  const work = temp();
  const observations = [];
  try {
    const result = await compare({ model: 'provider/model', out: join(work, 'output'), runs: 1,
      split: 'development', case: 'tenant-scope-buggy', thinking: 'off', timeout: 10, 'agent-dir': work }, {
      preflightModel: async () => ({ provider: 'provider', model: 'model', effective_thinking: 'off' }),
      execute: async (_command, args, options) => {
        observations.push(options);
        assert.doesNotMatch(options.cwd, /tenant|buggy|fixed/);
        assert.doesNotMatch(args.join(' '), /tenant-scope|buggy|fixed/);
        assert.deepEqual(JSON.parse(readFileSync(join(options.env.PI_CODING_AGENT_DIR, 'settings.json'))), settings);
        if (args[0].includes('/bundle/')) {
          const event = message('Verdict: no defects found'); event.message.model = 'wrong-model';
          writeFileSync(options.stdout, stream(event, { type: 'agent_end' }));
        } else {
          const out = args[args.indexOf('--out') + 1]; mkdirSync(out);
          writeFileSync(join(out, 'result.json'), JSON.stringify({ status: 'ok', model: 'model', provider: 'provider', usage: [], tool_calls: [] }));
          writeFileSync(join(out, 'review.md'), 'Verdict: no defects found\n');
          rmSync(join(options.cwd, '.git'), { recursive: true });
        }
        return { exit_code: 0, signal: null, timed_out: false, seconds: 0.01 };
      },
    });
    assert.equal(result.rows.length, 2);
    assert.equal(result.rows.every(r => r.status === 'invalid'), true);
    assert.equal(observations[0].prompt, observations[1].prompt);
    for (const row of result.rows) assert.equal(JSON.parse(readFileSync(join(result.out, row.run_id, 'result.json'))).status, 'invalid');
    assert.equal(observations.every(o => !existsSync(o.cwd)), true);
    await assert.rejects(() => compare({ model: 'provider/model', out: result.out, runs: 1, split: 'development' }), /EEXIST/);
  } finally { rmSync(work, { recursive: true, force: true }); }
});

test('outer deadline degrades SDK exit-zero success just as it degrades stock success', async () => {
  const work = temp();
  try {
    const result = await compare({ model: 'provider/model', out: join(work, 'output'), runs: 1,
      split: 'development', case: 'tenant-scope-buggy', thinking: 'off', timeout: 10, 'agent-dir': work }, {
      preflightModel: async () => ({ provider: 'provider', model: 'model', effective_thinking: 'off' }),
      execute: async (_command, args, options) => {
        if (args[0].includes('/bundle/')) {
          writeFileSync(options.stdout, stream(message('Verdict: no defects found'), { type: 'agent_end' }));
        } else {
          const out = args[args.indexOf('--out') + 1]; mkdirSync(out);
          writeFileSync(join(out, 'result.json'), JSON.stringify({ status: 'ok', model: 'model', provider: 'provider',
            findings: [], verdict: 'no defects found', usage: [], tool_calls: [] }));
          writeFileSync(join(out, 'review.md'), 'No defects found.\n\nVerdict: no defects found\n');
        }
        return { exit_code: 0, signal: null, timed_out: true, seconds: 10 };
      },
    });
    assert.equal(result.rows.length, 2);
    assert.equal(result.rows.every(row => row.status === 'degraded' && row.reason === 'timeout'), true);
    const sdk = result.rows.find(row => row.arm === 'review');
    const normalized = readFileSync(join(result.out, sdk.run_id, 'review.md'), 'utf8');
    assert.doesNotMatch(normalized, /Verdict: no defects found/);
    assert.match(normalized, /_TRUNCATED: timeout/);
    assert.match(readFileSync(join(result.out, sdk.run_id, 'sdk/review.md'), 'utf8'), /Verdict: no defects found/);
  } finally { rmSync(work, { recursive: true, force: true }); }
});
