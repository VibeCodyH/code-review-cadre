import { appendFileSync, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { isAbsolute, relative, resolve, sep } from 'node:path';

export const SDK_VERSION = '0.84.4';
export const SETTINGS = { compaction: { enabled: false }, retry: { enabled: false } };
export const REVIEW_CONTRACT = `Review only; do not repair implementation files. Investigate the supplied review task using the available tools. Before reporting each finding, inspect the strongest evidence that could invalidate it. Submit the complete review exactly once with submit_review. Ordinary prose is not a submission. Cite a repository-relative existing file and line, the concrete trigger, consequence, and evidence. Use execution="by-inspection" unless you actually executed a relevant command; execution="executed" must cite bash tool call IDs that completed with an exit outcome, including nonzero exits for failing reproductions. Before submitting executed findings, call execution_receipts and copy the exact returned id values into tool_call_ids; never guess IDs. Explain the observed outcome in evidence. An executed command alone does not prove a test passed or that your finding is correct. Submit an empty findings array and verdict="no defects found" only when the review completed and found no defects. Do not invent findings to satisfy the schema.`;

const string = { type: 'string', minLength: 1 };
export const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['findings', 'verdict'],
  properties: {
    findings: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['severity', 'title', 'path', 'line', 'trigger', 'consequence', 'evidence', 'execution', 'tool_call_ids'],
      properties: {
        severity: { type: 'string', enum: ['blocking', 'should-fix', 'nit'] },
        title: string, path: string, line: { type: 'integer', minimum: 1 },
        trigger: string, consequence: string, evidence: string,
        execution: { type: 'string', enum: ['by-inspection', 'executed'] },
        tool_call_ids: { type: 'array', items: string, uniqueItems: true },
      },
    } },
    verdict: { type: 'string', enum: ['blocking', 'should-fix', 'no defects found'] },
  },
};

export function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function exactKeys(object, keys) {
  return object && typeof object === 'object' && !Array.isArray(object)
    && Object.keys(object).length === keys.length && keys.every(key => Object.hasOwn(object, key));
}

// Structural and provenance checks, not an automated correctness judge.
export function validateReview(review, cwd, completed = new Map()) {
  if (!exactKeys(review, ['findings', 'verdict']) || !Array.isArray(review.findings)) {
    throw new Error('Review must contain findings and verdict only');
  }
  const root = realpathSync(cwd);
  const fields = Object.keys(REVIEW_SCHEMA.properties.findings.items.properties);
  for (const finding of review.findings) {
    if (!exactKeys(finding, fields)) throw new Error('Finding fields do not match the schema');
    for (const field of ['title', 'path', 'trigger', 'consequence', 'evidence']) {
      if (typeof finding[field] !== 'string' || !finding[field].trim()) throw new Error(`Empty or invalid ${field}`);
    }
    if (!['blocking', 'should-fix', 'nit'].includes(finding.severity)) throw new Error('Invalid severity');
    if (!['by-inspection', 'executed'].includes(finding.execution)) throw new Error('Invalid execution');
    if (!Number.isInteger(finding.line) || finding.line < 1) throw new Error('Invalid line');
    if (isAbsolute(finding.path) || finding.path.includes('\\') || finding.path.split('/').some(p => p === '..' || p === '' || p === '.')) {
      throw new Error('Path must be repository-relative without traversal');
    }
    let file;
    try { file = realpathSync(resolve(root, finding.path)); } catch { throw new Error('Finding file does not exist'); }
    const rel = relative(root, file);
    if (!rel || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel) || !statSync(file).isFile()) {
      throw new Error('Finding path must stay inside the checkout');
    }
    const source = readFileSync(file, 'utf8');
    const lines = source ? source.replace(/\n$/, '').split('\n').length : 0;
    if (finding.line > lines) throw new Error('Finding line does not exist');
    if (!Array.isArray(finding.tool_call_ids) || finding.tool_call_ids.some(id => typeof id !== 'string' || !id.trim())
      || new Set(finding.tool_call_ids).size !== finding.tool_call_ids.length) throw new Error('Invalid tool_call_ids');
    for (const id of finding.tool_call_ids) {
      if (!completed.has(id)) throw new Error('Unknown or incomplete tool call ID');
    }
    if (finding.execution === 'executed' && (!finding.tool_call_ids.length || finding.tool_call_ids.some(id => {
      const call = completed.get(id);
      return call.toolName !== 'bash' || !Number.isInteger(call.exit_code);
    }))) throw new Error('Executed findings require completed bash calls with an exit outcome');
  }
  const expected = review.findings.some(f => f.severity === 'blocking') ? 'blocking'
    : review.findings.some(f => f.severity === 'should-fix') ? 'should-fix' : 'no defects found';
  if (review.verdict !== expected) throw new Error('Verdict does not match finding severities');
  return structuredClone(review);
}

export function renderReview(result) {
  const findings = result.findings ?? [];
  const sections = findings.map(f => `**${f.severity}**\n${f.title}\n\n${f.path}:${f.line}\n\nTrigger: ${f.trigger}\n\nConsequence: ${f.consequence}\n\nEvidence: ${f.evidence}\n\nExecution: ${f.execution}${f.tool_call_ids.length ? ` (${f.tool_call_ids.join(', ')})` : ''}`);
  if (result.status === 'ok') {
    if (!findings.length) sections.push('No defects found.');
    sections.push(`Verdict: ${result.verdict}`);
  } else {
    if (!findings.length) sections.push(`DID NOT COMPLETE: ${result.reason}`);
    sections.push(`_TRUNCATED: ${result.reason}; review did not complete${findings.length ? '; findings above are partial' : ''}.`);
  }
  return sections.join('\n\n') + '\n';
}

function usageOnly(usage = {}) {
  const output = {};
  for (const field of ['input', 'output', 'cacheRead', 'cacheWrite', 'totalTokens']) {
    if (typeof usage[field] === 'number' && Number.isFinite(usage[field])) output[field] = usage[field];
  }
  if (usage.cost) output.cost = Object.fromEntries(Object.entries(usage.cost).filter(([key, value]) =>
    ['input', 'output', 'cacheRead', 'cacheWrite', 'total'].includes(key) && typeof value === 'number' && Number.isFinite(value)));
  return output;
}

// Never serialize a runtime, model, credentials, transport headers, or raw SDK error.
// Tool and assistant content remain review evidence and can contain source code.
function eventRecord(event) {
  const base = { type: event.type };
  if (event.type.startsWith('tool_execution_')) {
    Object.assign(base, { toolCallId: event.toolCallId, toolName: event.toolName });
    if (event.type === 'tool_execution_start') base.args = event.args;
    if (event.type === 'tool_execution_end') {
      base.isError = event.isError;
      base.content = (event.result?.content ?? []).filter(part => part.type === 'text').map(part => ({ type: 'text', text: part.text }));
    }
  } else if (event.type === 'message_end' && event.message?.role === 'assistant') {
    base.role = 'assistant';
    base.stopReason = event.message.stopReason;
    base.usage = usageOnly(event.message.usage);
    base.content = (event.message.content ?? []).filter(part => part.type === 'text').map(part => ({ type: 'text', text: part.text }));
    base.hasError = Boolean(event.message.errorMessage);
  } else if (event.type === 'message_update') {
    base.updateType = event.assistantMessageEvent?.type;
  } else if (event.type === 'agent_end') {
    base.willRetry = Boolean(event.willRetry);
  }
  return base;
}

export async function runReview(options, deps = {}) {
  const { cwd, out, prompt, model: requestedModel, thinking = 'off', timeout = 900, signal } = options;
  if (typeof prompt !== 'string' || !prompt.trim()) throw new Error('A nonempty stdin prompt is required');
  if (typeof requestedModel !== 'string' || !/^[^/\s]+\/\S+$/.test(requestedModel)) throw new Error('Explicit provider/model is required');
  if (!['off', 'minimal', 'low', 'medium', 'high', 'xhigh'].includes(thinking)) throw new Error('Invalid thinking level');
  if (!Number.isFinite(timeout) || timeout <= 0 || timeout > 86400) throw new Error('Timeout must be in (0, 86400] seconds');
  if (!cwd || !out || !statSync(cwd).isDirectory()) throw new Error('cwd directory and new out directory are required');
  mkdirSync(out, { mode: 0o700 }); // EEXIST is deliberate: never overwrite a previous run.
  const started = new Date().toISOString();
  const provider = requestedModel.slice(0, requestedModel.indexOf('/'));
  const id = requestedModel.slice(requestedModel.indexOf('/') + 1);
  const result = {
    schema: 'cadre/pi-review@1', status: 'failed', provider, model: id,
    requested_model: requestedModel, thinking, sdk_version: null, expected_sdk_version: SDK_VERSION,
    prompt_sha256: sha256(prompt), contract_sha256: sha256(REVIEW_CONTRACT),
    settings_sha256: sha256(JSON.stringify(SETTINGS)), started_at: started,
    findings: [], verdict: null, reason: 'missing_submission', usage: [], tool_calls: [], finish_reasons: [],
  };
  result.source_sha256 = sha256(readFileSync(new URL('./review.mjs', import.meta.url)));
  try { result.lock_sha256 = sha256(readFileSync(new URL('./package-lock.json', import.meta.url))); }
  catch { result.lock_sha256 = null; }
  let session, unsubscribe, submission, terminalReason, settled = false, timer, externalAbort;
  let sequence = 0;
  const completed = new Map();
  const calls = new Map();
  const controller = new AbortController();
  const log = event => {
    if (!settled) appendFileSync(resolve(out, 'events.jsonl'), JSON.stringify({ seq: ++sequence, at: new Date().toISOString(), ...event }) + '\n', { mode: 0o600 });
  };
  log({ type: 'run_start', model: requestedModel, thinking });
  const stopIfTimedOut = () => { if (controller.signal.aborted) throw new Error('timeout'); };
  try {
    const timeoutPromise = new Promise((_, reject) => {
      const cancel = reason => {
        terminalReason ??= reason;
        controller.abort();
        session?.abort().catch(() => {});
        reject(new Error(reason));
      };
      timer = setTimeout(() => cancel('timeout'), timeout * 1000);
      externalAbort = () => {
        if (signal.reason === 'SIGINT' || signal.reason === 'SIGTERM') result.interrupted_by = signal.reason;
        cancel('external_abort');
      };
      signal?.addEventListener('abort', externalAbort, { once: true });
      if (signal?.aborted) externalAbort();
    });
    const work = async () => {
      const sdk = deps.sdk ?? await import('@earendil-works/pi-coding-agent');
      stopIfTimedOut();
      if (typeof sdk.getPackageDir === 'function') {
        let metadata;
        try { metadata = JSON.parse(readFileSync(resolve(sdk.getPackageDir(), 'package.json'), 'utf8')); }
        catch { terminalReason = 'sdk_package_unverified'; throw new Error('sdk_package_unverified'); }
        if (metadata.name !== '@earendil-works/pi-coding-agent' || typeof metadata.version !== 'string') {
          terminalReason = 'sdk_package_unverified'; throw new Error('sdk_package_unverified');
        }
        result.sdk_version = metadata.version;
        if (result.sdk_version !== SDK_VERSION) { terminalReason = 'sdk_version_mismatch'; throw new Error('sdk_version_mismatch'); }
      } else if (!deps.sdk) {
        terminalReason = 'sdk_package_unverified'; throw new Error('sdk_package_unverified');
      } // Injected unit-test doubles have no installed package and retain sdk_version:null.
      const runtime = await sdk.ModelRuntime.create({ signal: controller.signal, allowModelNetwork: false });
      stopIfTimedOut();
      const model = runtime.getModel(provider, id);
      if (!model || model.provider !== provider || model.id !== id) { terminalReason = 'model_not_found'; throw new Error('model_not_found'); }
      result.model_config_sha256 = sha256(JSON.stringify({
        provider: model.provider, id: model.id, api: model.api,
        baseUrl: model.baseUrl, reasoning: model.reasoning, input: model.input,
        contextWindow: model.contextWindow, maxTokens: model.maxTokens,
        samplingParams: model.samplingParams, compat: model.compat, thinkingLevelMap: model.thinkingLevelMap,
      }));
      const settingsManager = sdk.SettingsManager.inMemory(structuredClone(SETTINGS));
      const loader = new sdk.DefaultResourceLoader({
        cwd, agentDir: sdk.getAgentDir(), settingsManager,
        noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
        extensionsOverride: base => ({ ...base, extensions: [], errors: [] }),
        skillsOverride: () => ({ skills: [], diagnostics: [] }),
        promptsOverride: () => ({ prompts: [], diagnostics: [] }),
        themesOverride: () => ({ themes: [], diagnostics: [] }),
        agentsFilesOverride: () => ({ agentsFiles: [] }),
        systemPromptOverride: () => undefined, appendSystemPromptOverride: () => [],
      });
      await loader.reload();
      stopIfTimedOut();
      const tool = sdk.defineTool({
        name: 'submit_review', label: 'Submit review',
        description: 'Submit the complete review after checking findings against surrounding code. Exactly one successful submission is accepted. Executed means a relevant bash call actually exited (including nonzero failure reproductions), not an automated correctness or test-pass guarantee.',
        parameters: REVIEW_SCHEMA,
        execute: async (toolCallId, params) => {
          stopIfTimedOut();
          if (submission) {
            terminalReason ??= 'duplicate_submission';
            throw new Error('Review already submitted');
          }
          submission = validateReview(params, cwd, completed);
          result.submission_tool_call_id = toolCallId;
          log({ type: 'review_submitted', toolCallId, review: submission });
          return { content: [{ type: 'text', text: 'Review accepted. End this review now.' }], details: {} };
        },
      });
      const receiptsTool = sdk.defineTool({
        name: 'execution_receipts', label: 'Execution receipts',
        description: 'List exact tool call IDs, commands, and exit codes for completed bash executions. Before submitting executed findings, copy the relevant returned id into tool_call_ids. Nonzero exit codes can be valid failing reproductions; receipts do not establish finding correctness.',
        parameters: { type: 'object', additionalProperties: false, properties: {} },
        execute: async () => {
          stopIfTimedOut();
          const receipts = [...completed.values()].filter(call => call.toolName === 'bash' && Number.isInteger(call.exit_code))
            .map(call => ({ id: call.id, command: call.command, exit_code: call.exit_code }));
          return { content: [{ type: 'text', text: JSON.stringify({ receipts }) }], details: {} };
        },
      });
      const created = await sdk.createAgentSession({
        cwd, agentDir: sdk.getAgentDir(), model, thinkingLevel: thinking, modelRuntime: runtime,
        tools: ['read', 'bash', 'edit', 'write', 'submit_review', 'execution_receipts'], customTools: [tool, receiptsTool],
        resourceLoader: loader, settingsManager, sessionManager: sdk.SessionManager.inMemory(cwd),
      });
      session = created.session;
      if (controller.signal.aborted) session.dispose();
      stopIfTimedOut();
      if (created.modelFallbackMessage || session.model?.id !== id || session.model?.provider !== provider) {
        terminalReason = 'model_fallback'; throw new Error('model_fallback');
      }
      result.model = session.model.id;
      result.provider = session.model.provider;
      result.effective_thinking = session.thinkingLevel;
      if (session.thinkingLevel !== thinking) { terminalReason = 'thinking_level_changed'; throw new Error('thinking_level_changed'); }
      unsubscribe = session.subscribe(event => {
        if (settled) return;
        log(eventRecord(event));
        if (event.type === 'tool_execution_start') {
          if (submission && event.toolName === 'submit_review') terminalReason ??= 'duplicate_submission';
          calls.set(event.toolCallId, { id: event.toolCallId, toolName: event.toolName, completed: false,
            ...(event.toolName === 'bash' && typeof event.args?.command === 'string' ? { command: event.args.command } : {}) });
        }
        if (event.type === 'tool_execution_end' && calls.has(event.toolCallId)) {
          const call = { ...calls.get(event.toolCallId), completed: true, isError: event.isError };
          if (call.toolName === 'bash') {
            // In pinned Pi 0.84.4 a nonzero bash exit throws this footer; spawn,
            // timeout and abort failures do not establish a completed command.
            const output = (event.result?.content ?? []).filter(p => p.type === 'text').map(p => p.text).join('\n');
            const nonzero = /Command exited with code (\d+)\s*$/.exec(output);
            if (event.isError === false) call.exit_code = 0;
            else if (nonzero) call.exit_code = Number(nonzero[1]);
          }
          calls.set(event.toolCallId, call);
          completed.set(event.toolCallId, call);
        }
        if (event.type === 'message_end' && event.message?.role === 'assistant') {
          const message = event.message;
          if ((message.model && message.model !== id) || (message.provider && message.provider !== provider)) terminalReason = 'assistant_model_mismatch';
          result.finish_reasons.push(message.stopReason);
          result.usage.push(usageOnly(message.usage));
          if (['error', 'aborted', 'length'].includes(message.stopReason) || message.errorMessage) {
            terminalReason = `assistant_${['error', 'aborted', 'length'].includes(message.stopReason) ? message.stopReason : 'error'}`;
          }
        }
      });
      await session.prompt(`${prompt}\n\n${REVIEW_CONTRACT}`, { expandPromptTemplates: false });
      if (session.agent?.state?.errorMessage) terminalReason ??= 'assistant_error';
      if (submission && completed.get(result.submission_tool_call_id)?.isError !== false) terminalReason ??= 'submission_not_completed';
      if (submission && result.finish_reasons.at(-1) !== 'stop') terminalReason ??= 'missing_terminal_stop';
    };
    await Promise.race([work(), timeoutPromise]);
  } catch {
    terminalReason ??= 'sdk_failure';
  } finally {
    clearTimeout(timer);
    if (externalAbort) signal?.removeEventListener('abort', externalAbort);
    unsubscribe?.();
    session?.dispose();
    if (submission) {
      result.findings = submission.findings;
      result.verdict = submission.verdict;
      result.status = terminalReason ? 'degraded' : 'ok';
      result.reason = terminalReason ?? null;
    } else result.reason = terminalReason ?? 'missing_submission';
    result.tool_calls = [...calls.values()];
    result.finished_at = new Date().toISOString();
    log({ type: 'run_end', status: result.status, reason: result.reason });
    settled = true;
    writeFileSync(resolve(out, 'result.json'), JSON.stringify(result, null, 2) + '\n', { mode: 0o600 });
    writeFileSync(resolve(out, 'review.md'), renderReview(result), { mode: 0o600 });
  }
  return result;
}
