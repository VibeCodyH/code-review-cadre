import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runReview, validateReview, renderReview, SETTINGS } from './review.mjs';

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'pi-review-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const cwd = join(root, 'repo');
  mkdirSync(cwd);
  writeFileSync(join(cwd, 'file.js'), 'first\nsecond\n');
  return { root, cwd, out: join(root, 'artifacts'), prompt: 'Review this change.', model: 'test/model', timeout: 1 };
}

const finding = () => ({ severity: 'blocking', title: 'Original title', path: 'file.js', line: 2,
  trigger: 'When request A finishes after request B', consequence: 'A replaces the newer value',
  evidence: 'The assignment is unconditional.', execution: 'by-inspection', tool_call_ids: [] });
const review = () => ({ findings: [finding()], verdict: 'blocking' });
const clean = () => ({ findings: [], verdict: 'no defects found' });

function fakeSdk(program, hooks = {}) {
  const model = { provider: 'test', id: 'model', samplingParams: { temperature: 0.2 }, headers: { Authorization: 'SECRET' } };
  return {
    getAgentDir: () => '/fake-agent',
    ...(hooks.packageDir ? { getPackageDir: () => hooks.packageDir } : {}),
    ModelRuntime: { create: async options => {
      assert.equal(options.allowModelNetwork, false);
      assert.ok(options.signal);
      if (hooks.runtime) return hooks.runtime();
      return { getModel: (provider, id) => provider === 'test' && id === 'model' ? model : undefined };
    } },
    SettingsManager: { inMemory: settings => { assert.deepEqual(settings, SETTINGS); return settings; } },
    SessionManager: { inMemory: cwd => ({ cwd }) },
    DefaultResourceLoader: class {
      constructor(options) {
        for (const flag of ['noExtensions', 'noSkills', 'noPromptTemplates', 'noThemes', 'noContextFiles']) assert.equal(options[flag], true);
        assert.deepEqual(options.agentsFilesOverride({ agentsFiles: ['secret'] }), { agentsFiles: [] });
        assert.equal(options.systemPromptOverride('secret'), undefined);
        assert.deepEqual(options.appendSystemPromptOverride(['secret']), []);
      }
      async reload() {}
    },
    defineTool: tool => tool,
    createAgentSession: async options => {
      assert.equal(options.model, model); // Configured model object must survive intact.
      assert.deepEqual(options.tools, ['read', 'bash', 'edit', 'write', 'submit_review', 'execution_receipts']);
      let listener;
      const emit = event => listener?.(event);
      const end = (stopReason = 'stop', extra = {}) => emit({ type: 'message_end', message: {
        role: 'assistant', stopReason, content: [{ type: 'text', text: 'Done.' }],
        usage: { input: 5, output: 2, totalTokens: 7, cost: { total: 0.01 }, apiKey: 'SECRET' }, ...extra,
      } });
      const submit = async value => {
        emit({ type: 'tool_execution_start', toolName: 'submit_review', toolCallId: 'submission', args: value });
        const result = await options.customTools[0].execute('submission', value);
        emit({ type: 'tool_execution_end', toolName: 'submit_review', toolCallId: 'submission', isError: false, result });
      };
      const session = {
        model, thinkingLevel: hooks.thinking ?? options.thinkingLevel, agent: { state: {} },
        subscribe: fn => { listener = fn; return () => { listener = undefined; }; },
        abort: async () => {}, dispose: () => {},
        prompt: async (prompt, promptOptions) => {
          assert.match(prompt, /submit_review/);
          assert.equal(promptOptions.expandPromptTemplates, false);
          await program({ emit, end, submit, session });
        },
      };
      return { session };
    },
  };
}

test('valid submission preserves strings and records tool events, usage and hashes', async t => {
  const options = fixture(t);
  const result = await runReview(options, { sdk: fakeSdk(async ({ emit, submit, end }) => {
    emit({ type: 'agent_start' });
    await submit(review());
    end();
    emit({ type: 'agent_end', willRetry: false });
  }) });
  assert.equal(result.status, 'ok');
  assert.deepEqual(result.findings, review().findings);
  assert.deepEqual(result.usage, [{ input: 5, output: 2, totalTokens: 7, cost: { total: 0.01 } }]);
  assert.match(result.model_config_sha256, /^[a-f0-9]{64}$/);
  const events = readFileSync(join(options.out, 'events.jsonl'), 'utf8');
  assert.match(events, /tool_execution_end/);
  assert.match(events, /review_submitted/);
  assert.doesNotMatch(events + JSON.stringify(result), /SECRET|Authorization|apiKey/);
  assert.equal(readFileSync(join(options.out, 'review.md'), 'utf8'), renderReview(result));
  assert.equal(JSON.parse(readFileSync(join(options.out, 'result.json'))).status, 'ok');
  assert.equal(statSync(options.out).mode & 0o777, 0o700);
  assert.equal(statSync(join(options.out, 'events.jsonl')).mode & 0o777, 0o600);
  assert.equal(statSync(join(options.out, 'result.json')).mode & 0o777, 0o600);
  assert.equal(statSync(join(options.out, 'review.md')).mode & 0o777, 0o600);
});

test('an explicit clean submission succeeds; clean-looking prose does not', async t => {
  const options = fixture(t);
  const result = await runReview(options, { sdk: fakeSdk(async ({ submit, end }) => { await submit(clean()); end(); }) });
  assert.equal(result.status, 'ok');
  assert.match(renderReview(result), /Verdict: no defects found/);
  const missing = await runReview({ ...options, out: join(options.root, 'missing') }, { sdk: fakeSdk(async ({ end }) => {
    end('stop', { content: [{ type: 'text', text: 'No defects found. Verdict: no defects found' }] });
  }) });
  assert.equal(missing.status, 'failed');
  assert.equal(missing.reason, 'missing_submission');
  assert.doesNotMatch(renderReview(missing), /Verdict: no defects found/);
});

for (const reason of ['error', 'aborted', 'length']) {
  test(`${reason} after a valid submission retains findings as degraded`, async t => {
    const options = fixture(t);
    const result = await runReview(options, { sdk: fakeSdk(async ({ submit, end }) => {
      await submit(review());
      end(reason, { errorMessage: 'Authorization Bearer SECRET' });
    }) });
    assert.equal(result.status, 'degraded');
    assert.equal(result.reason, `assistant_${reason}`);
    assert.deepEqual(result.findings, review().findings);
    assert.match(renderReview(result), /_TRUNCATED/);
    assert.doesNotMatch(renderReview(result), /Verdict:/);
    assert.doesNotMatch(readFileSync(join(options.out, 'events.jsonl'), 'utf8'), /SECRET/);
  });
}

test('clean submission followed by provider failure never renders a clean verdict', async t => {
  const result = await runReview(fixture(t), { sdk: fakeSdk(async ({ submit, end }) => { await submit(clean()); end('error'); }) });
  assert.equal(result.status, 'degraded');
  assert.doesNotMatch(renderReview(result), /Verdict: no defects found/);
});

test('corrected duplicate submission cannot leave the original clean verdict successful', async t => {
  const options = fixture(t);
  const result = await runReview(options, { sdk: fakeSdk(async ({ submit, end }) => {
    await submit(clean());
    await assert.rejects(submit(review()), /already submitted/);
    end();
  }) });
  assert.equal(result.status, 'degraded');
  assert.equal(result.reason, 'duplicate_submission');
  assert.deepEqual(result.findings, []);
  assert.equal(result.verdict, 'no defects found'); // Original submission is evidence, never overwritten.
  assert.doesNotMatch(renderReview(result), /Verdict: no defects found/);
  assert.equal(JSON.parse(readFileSync(join(options.out, 'result.json'))).status, 'degraded');
});

test('external termination retains submitted findings and aborts the active session', async t => {
  const controller = new AbortController();
  let aborted = false;
  const options = { ...fixture(t), signal: controller.signal };
  const result = await runReview(options, { sdk: fakeSdk(async ({ submit, session }) => {
    session.abort = async () => { aborted = true; };
    await submit(review());
    controller.abort('SIGTERM');
    await new Promise(() => {});
  }) });
  assert.equal(aborted, true);
  assert.equal(result.status, 'degraded');
  assert.equal(result.reason, 'external_abort');
  assert.equal(result.interrupted_by, 'SIGTERM');
  assert.deepEqual(result.findings, review().findings);
  assert.match(readFileSync(join(options.out, 'events.jsonl'), 'utf8'), /run_end/);
});

test('external termination also interrupts pending SDK initialization', async t => {
  const controller = new AbortController();
  const options = { ...fixture(t), signal: controller.signal };
  const result = await runReview(options, { sdk: fakeSdk(async () => {}, { runtime: () => {
    controller.abort('SIGINT');
    return new Promise(() => {});
  } }) });
  assert.equal(result.status, 'failed');
  assert.equal(result.reason, 'external_abort');
  assert.equal(result.interrupted_by, 'SIGINT');
  assert.match(readFileSync(join(options.out, 'review.md'), 'utf8'), /DID NOT COMPLETE/);
});

test('submission without final stop is degraded', async t => {
  const result = await runReview(fixture(t), { sdk: fakeSdk(async ({ submit }) => { await submit(review()); }) });
  assert.equal(result.reason, 'missing_terminal_stop');
});

test('validation checks schema, location, verdict and execution provenance', t => {
  const { cwd, root } = fixture(t);
  assert.deepEqual(validateReview(review(), cwd), review());
  for (const patch of [
    { severity: 'critical' }, { execution: 'tested' }, { title: ' ' }, { line: 3 }, { line: 1.5 },
    { path: '../file.js' }, { path: '/tmp/file.js' }, { path: 'missing.js' }, { tool_call_ids: ['missing'] },
    { execution: 'executed' }, { extra: true },
  ]) assert.throws(() => validateReview({ findings: [{ ...finding(), ...patch }], verdict: 'blocking' }, cwd));
  assert.throws(() => validateReview({ ...review(), verdict: 'no defects found' }, cwd));
  writeFileSync(join(root, 'outside.js'), 'code');
  symlinkSync(join(root, 'outside.js'), join(cwd, 'escape.js'));
  assert.throws(() => validateReview({ findings: [{ ...finding(), path: 'escape.js', line: 1 }], verdict: 'blocking' }, cwd));
  const executed = { findings: [{ ...finding(), execution: 'executed', tool_call_ids: ['call'] }], verdict: 'blocking' };
  for (const call of [{ toolName: 'read', isError: false }, { toolName: 'bash', isError: true }]) {
    assert.throws(() => validateReview(executed, cwd, new Map([['call', call]])));
  }
  for (const exit_code of [0, 1]) assert.deepEqual(validateReview(executed, cwd, new Map([['call', { toolName: 'bash', exit_code }]])), executed);
});

test('actual successful bash completion permits execution attribution', async t => {
  const result = await runReview(fixture(t), { sdk: fakeSdk(async ({ emit, submit, end }) => {
    emit({ type: 'tool_execution_start', toolCallId: 'bash1', toolName: 'bash', args: { command: 'node reproduce.mjs' } });
    emit({ type: 'tool_execution_end', toolCallId: 'bash1', toolName: 'bash', isError: false, result: { content: [{ type: 'text', text: 'reproduced' }] } });
    await submit({ findings: [{ ...finding(), execution: 'executed', tool_call_ids: ['bash1'] }], verdict: 'blocking' });
    end();
  }) });
  assert.equal(result.status, 'ok');
  assert.equal(result.tool_calls[0].completed, true);
});

test('a failing reproduction is executed evidence; an aborted bash is not', async t => {
  const options = fixture(t);
  for (const [name, output, expected] of [['nonzero', 'assertion failed\n\nCommand exited with code 1', 'ok'], ['aborted', 'Command aborted', 'failed']]) {
    const result = await runReview({ ...options, out: join(options.root, name) }, { sdk: fakeSdk(async ({ emit, submit, end }) => {
      emit({ type: 'tool_execution_start', toolCallId: 'bash1', toolName: 'bash', args: { command: 'node reproduce.mjs' } });
      emit({ type: 'tool_execution_end', toolCallId: 'bash1', toolName: 'bash', isError: true, result: { content: [{ type: 'text', text: output }] } });
      await submit({ findings: [{ ...finding(), execution: 'executed', tool_call_ids: ['bash1'] }], verdict: 'blocking' });
      end();
    }) });
    assert.equal(result.status, expected);
  }
});

test('runtime timeout persists failed artifacts without waiting for initialization', async t => {
  const options = { ...fixture(t), timeout: 0.02 };
  const result = await runReview(options, { sdk: fakeSdk(async () => {}, { runtime: () => new Promise(() => {}) }) });
  assert.equal(result.status, 'failed');
  assert.equal(result.reason, 'timeout');
  assert.match(readFileSync(join(options.out, 'events.jsonl'), 'utf8'), /run_end/);
});

test('timeout after submission retains a degraded record', async t => {
  const result = await runReview({ ...fixture(t), timeout: 0.02 }, { sdk: fakeSdk(async ({ submit }) => {
    await submit(review());
    await new Promise(() => {});
  }) });
  assert.equal(result.status, 'degraded');
  assert.equal(result.reason, 'timeout');
  assert.equal(result.findings.length, 1);
});

test('rejects reused output paths and mismatched model/thinking', async t => {
  const options = fixture(t);
  mkdirSync(options.out);
  await assert.rejects(runReview(options), /EEXIST/);
  const model = await runReview({ ...options, out: join(options.root, 'unknown'), model: 'test/missing' }, { sdk: fakeSdk(async () => {}) });
  assert.equal(model.reason, 'model_not_found');
  const thinking = await runReview({ ...options, out: join(options.root, 'thinking') }, { sdk: fakeSdk(async () => {}, { thinking: 'high' }) });
  assert.equal(thinking.reason, 'thinking_level_changed');
});

test('verifies installed SDK version and rejects package drift before runtime initialization', async t => {
  const options = fixture(t);
  writeFileSync(join(options.root, 'package.json'), JSON.stringify({ name: '@earendil-works/pi-coding-agent', version: '0.84.5' }));
  let initialized = false;
  const result = await runReview(options, { sdk: fakeSdk(async () => {}, { packageDir: options.root, runtime: () => { initialized = true; } }) });
  assert.equal(result.status, 'failed');
  assert.equal(result.reason, 'sdk_version_mismatch');
  assert.equal(result.sdk_version, '0.84.5');
  assert.equal(result.expected_sdk_version, '0.84.4');
  assert.equal(initialized, false);
});

test('installed SDK exposes real nonzero bash receipt IDs to the model before executed submission', async t => {
  let sdk;
  try { sdk = await import('@earendil-works/pi-coding-agent'); }
  catch (error) {
    if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
    t.skip('Optional pinned SDK not installed; run npm ci in integrations/pi-review');
    return;
  }
  const options = { ...fixture(t), timeout: 5 };
  const command = 'printf "reproduced\\n"; exit 1';
  let observedReceipt;
  const actualSdk = {
    ...sdk,
    getAgentDir: () => options.root,
    ModelRuntime: { create: async () => {
      const runtime = await sdk.ModelRuntime.create({ authPath: join(options.root, 'auth.json'), modelsPath: null, allowModelNetwork: false, refreshOnCreate: false });
      runtime.registerProvider('test', { api: 'openai-completions', baseUrl: 'http://127.0.0.1:1', apiKey: 'fake-test-key', models: [{
        id: 'model', name: 'Fake model', reasoning: false, input: ['text'], contextWindow: 100000, maxTokens: 1000,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      }] });
      return runtime;
    } },
    createAgentSession: async settings => {
      const created = await sdk.createAgentSession(settings);
      let turn = 0;
      created.session.agent.streamFunction = (_model, context) => {
        let content;
        if (turn === 0) content = [{ type: 'toolCall', id: 'actual-bash-id', name: 'bash', arguments: { command } }];
        else if (turn === 1) content = [{ type: 'toolCall', id: 'receipt-request', name: 'execution_receipts', arguments: {} }];
        else if (turn === 2) {
          const response = context.messages.find(message => message.role === 'toolResult' && message.toolName === 'execution_receipts');
          observedReceipt = JSON.parse(response.content.find(part => part.type === 'text').text).receipts[0];
          content = [{ type: 'toolCall', id: 'real-submit', name: 'submit_review', arguments: {
            findings: [{ ...finding(), execution: 'executed', tool_call_ids: [observedReceipt.id] }], verdict: 'blocking',
          } }];
        } else content = [{ type: 'text', text: 'Done.' }];
        const stopReason = turn++ < 3 ? 'toolUse' : 'stop';
        const message = { role: 'assistant', api: 'openai-completions', provider: 'test', model: 'model',
          content, stopReason, timestamp: Date.now(),
          usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        };
        return {
          async *[Symbol.asyncIterator]() {
            yield { type: 'start', partial: message };
            yield { type: 'done', reason: message.stopReason, message };
          },
          async result() { return message; },
        };
      };
      return created;
    },
  };
  const result = await runReview(options, { sdk: actualSdk });
  assert.equal(result.status, 'ok', result.reason);
  assert.equal(result.sdk_version, '0.84.4');
  assert.deepEqual(observedReceipt, { id: 'actual-bash-id', command, exit_code: 1 });
  assert.deepEqual(result.findings[0].tool_call_ids, [observedReceipt.id]);
  assert.equal(result.findings[0].execution, 'executed');
  assert.deepEqual(result.finish_reasons, ['toolUse', 'toolUse', 'toolUse', 'stop']);
  assert.equal(result.tool_calls[0].isError, true);
  assert.equal(result.tool_calls[0].exit_code, 1);
});
