#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync, appendFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { verifyCorpus } from './verify-corpus.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const integration = join(root, 'integrations/pi-review');
export const settings = { compaction: { enabled: false }, retry: { enabled: false } };
const digest = value => createHash('sha256').update(value).digest('hex');
const json = path => JSON.parse(readFileSync(path, 'utf8'));
const save = (path, value) => writeFileSync(path, JSON.stringify(value, null, 2) + '\n', { mode: 0o600 });

export function parseArgs(args) {
  const options = { runs: 2, split: 'development', thinking: 'off', timeout: 180 };
  const names = new Set(['model', 'out', 'runs', 'split', 'thinking', 'timeout', 'case', 'agent-dir']);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--help') return { help: true };
    const key = args[i].replace(/^--/, '');
    if (!args[i].startsWith('--') || !names.has(key) || !args[i + 1] || args[i + 1].startsWith('--')) throw Error(`Unknown or incomplete option: ${args[i]}`);
    options[key] = args[++i];
  }
  if (!options.model?.includes('/') || !options.out) throw Error('--model provider/model and --out NEW_DIRECTORY are required');
  for (const name of ['runs', 'timeout']) {
    options[name] = Number(options[name]);
    if (!Number.isInteger(options[name]) || options[name] < 1 || options[name] > (name === 'runs' ? 10 : 3600)) throw Error(`Invalid --${name}`);
  }
  if (!['development', 'holdout', 'all'].includes(options.split)) throw Error('Invalid --split');
  if (!['off', 'minimal', 'low', 'medium', 'high', 'xhigh'].includes(options.thinking)) throw Error('Invalid --thinking');
  return options;
}

function stockVerdict(review) {
  const verdicts = new Set();
  let fence;
  for (const raw of review.split('\n')) {
    if (/^(?: {4}|\t)/.test(raw)) continue; // Markdown indented code.
    const line = raw.trim();
    if (line.startsWith('>')) continue;
    const marker = /^(`{3,}|~{3,})(.*)$/.exec(line);
    if (marker) {
      if (!fence) fence = marker[1];
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) fence = undefined;
      continue;
    }
    if (fence) continue;
    const match = line.replace(/\*\*|__/g, '').match(/^Verdict:\s*(blocking|should-fix|no defects found)\s*$/i);
    if (match) verdicts.add(match[1].toLowerCase());
  }
  return verdicts.size === 1 ? [...verdicts][0] : null;
}

export function parseStock(text, exitCode, timedOut = false) {
  const events = [];
  let malformed = false;
  for (const line of text.split('\n').filter(Boolean)) {
    try { events.push(JSON.parse(line)); } catch { malformed = true; }
  }
  const messages = events.filter(e => e.type === 'message_end' && e.message?.role === 'assistant').map(e => e.message);
  const last = messages.at(-1);
  const review = (last?.content ?? []).filter(c => c.type === 'text').map(c => c.text).join('\n');
  const completed = events.some(e => e.type === 'agent_end');
  const failure = timedOut || exitCode !== 0 || malformed || !completed || last?.stopReason !== 'stop';
  const verdict = stockVerdict(review);
  return {
    status: failure ? (review.trim() ? 'degraded' : 'failed') : (verdict ? 'ok' : 'inconclusive'),
    reason: timedOut ? 'timeout' : malformed ? 'invalid event stream' : last?.stopReason ?? 'no final assistant message',
    review, verdict, model: last?.model ?? null, provider: last?.provider ?? null,
    usage: sumUsage(messages),
    tool_calls: events.filter(e => e.type === 'tool_execution_start').length,
  };
}

function sumUsage(messages) {
  const usage = messages.map(m => m.usage).filter(Boolean);
  if (!usage.length) return null;
  const sum = key => usage.every(u => typeof u[key] === 'number') ? usage.reduce((n, u) => n + u[key], 0) : null;
  return Object.fromEntries(['input', 'output', 'cacheRead', 'cacheWrite', 'totalTokens'].map(k => [k, sum(k)]));
}

function git(cwd, args) {
  const result = spawnSync('git', ['-c', 'core.hooksPath=/dev/null', '-c', 'init.templateDir=', '-C', cwd, ...args], {
    encoding: 'utf8', timeout: 15000,
    env: { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', GIT_AUTHOR_DATE: '2026-01-01T00:00:00Z', GIT_COMMITTER_DATE: '2026-01-01T00:00:00Z' },
  });
  if (result.status !== 0) throw Error(`git ${args[0]} failed: ${result.stderr}`);
  return result.stdout.trim();
}

export function prepareCheckout(corpus, item, cwd) {
  cpSync(join(corpus, item.base), cwd, { recursive: true });
  git(cwd, ['init', '-q']);
  git(cwd, ['config', 'user.name', 'Cadre fixture']);
  git(cwd, ['config', 'user.email', 'fixture@example.invalid']);
  git(cwd, ['add', '--all']);
  git(cwd, ['commit', '-qm', 'Base']);
  git(cwd, ['tag', 'BASE']);
  for (const file of readdirSync(cwd)) if (file !== '.git') rmSync(join(cwd, file), { recursive: true, force: true });
  cpSync(join(corpus, item.target), cwd, { recursive: true });
  git(cwd, ['add', '--all']);
  git(cwd, ['commit', '--allow-empty', '-qm', 'Change under review']);
  return { base_tree: git(cwd, ['rev-parse', 'BASE^{tree}']), reviewed_tree: git(cwd, ['rev-parse', 'HEAD^{tree}']) };
}

function softwareHashes() {
  const paths = ['evals/review-v1/compare.mjs', 'evals/review-v1/prompt.md', 'evals/review-v1/verify-corpus.mjs'];
  for (const file of readdirSync(integration).sort()) if (/\.(mjs|json)$/.test(file) && !file.endsWith('.test.mjs')) paths.push(`integrations/pi-review/${file}`);
  return Object.fromEntries(paths.sort().map(p => [p, digest(readFileSync(join(root, p)))]));
}

export async function preflightModel(pkgDir, agentDir, requested, thinking) {
  const sdk = await import(pathToFileURL(join(pkgDir, 'dist/index.js')));
  const runtime = await sdk.ModelRuntime.create({
    authPath: join(agentDir, 'auth.json'), modelsPath: join(agentDir, 'models.json'),
    modelsStorePath: join(agentDir, 'models-cache.json'), allowModelNetwork: false,
    refreshOnCreate: false, signal: AbortSignal.timeout(10000),
  });
  const slash = requested.indexOf('/');
  const model = runtime.getModel(requested.slice(0, slash), requested.slice(slash + 1));
  if (!model || `${model.provider}/${model.id}` !== requested) throw Error('Requested model is unavailable; no arms were dispatched');
  const settingsManager = sdk.SettingsManager.inMemory(settings);
  const loader = new sdk.DefaultResourceLoader({ cwd: agentDir, agentDir, settingsManager,
    noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
  });
  await loader.reload();
  const { session } = await sdk.createAgentSession({ cwd: agentDir, agentDir, model, modelRuntime: runtime,
    thinkingLevel: thinking, tools: [], resourceLoader: loader, settingsManager,
    sessionManager: sdk.SessionManager.inMemory(agentDir),
  });
  try {
    if (session.thinkingLevel !== thinking) throw Error(`Requested thinking level ${thinking} is unsupported; no arms were dispatched`);
    return { provider: model.provider, model: model.id, effective_thinking: session.thinkingLevel };
  } finally { session.dispose(); }
}

function corpusFingerprint(corpus) {
  const walk = path => readdirSync(path, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name)).flatMap(entry =>
    entry.isDirectory() ? walk(join(path, entry.name)) : [[join(path, entry.name).slice(corpus.length + 1), digest(readFileSync(join(path, entry.name)))]]);
  return digest(JSON.stringify(walk(corpus)));
}

function copyConfig(source, target, provider) {
  mkdirSync(target, { mode: 0o700 });
  let providerConfig = null;
  if (existsSync(join(source, 'models.json'))) {
    const config = json(join(source, 'models.json'));
    providerConfig = config.providers?.[provider] ?? null;
    save(join(target, 'models.json'), { providers: providerConfig ? { [provider]: providerConfig } : {} });
  }
  if (existsSync(join(source, 'auth.json'))) {
    const auth = json(join(source, 'auth.json'));
    save(join(target, 'auth.json'), auth[provider] ? { [provider]: auth[provider] } : {});
  }
  save(join(target, 'settings.json'), settings);
  // Fingerprint the exact provider config without publishing its endpoints or credentials.
  return digest(JSON.stringify(providerConfig));
}

export async function execute(command, args, { cwd, env, prompt, timeout, stdout, stderr }) {
  return new Promise((resolveRun, reject) => {
    const started = Date.now();
    let timedOut = false;
    let killTimer;
    const child = spawn(command, args, { cwd, env, detached: process.platform !== 'win32', stdio: ['pipe', 'pipe', 'pipe'] });
    const kill = signal => { try { process.kill(process.platform === 'win32' ? child.pid : -child.pid, signal); } catch {} };
    const timer = setTimeout(() => {
      timedOut = true;
      kill('SIGTERM');
      killTimer = setTimeout(() => kill('SIGKILL'), 3000);
    }, timeout * 1000);
    child.stdout.on('data', data => appendFileSync(stdout, data, { mode: 0o600 }));
    child.stderr.on('data', data => appendFileSync(stderr, data, { mode: 0o600 }));
    child.stdin.on('error', () => {});
    child.once('error', error => { clearTimeout(timer); clearTimeout(killTimer); reject(error); });
    child.once('close', (code, signal) => {
      clearTimeout(timer); clearTimeout(killTimer);
      resolveRun({ exit_code: code, signal, timed_out: timedOut, seconds: (Date.now() - started) / 1000 });
    });
    child.stdin.end(prompt);
  });
}

export function report(rows, manifest) {
  const lines = ['# Pi review comparison', '',
    'Synthetic development evidence. Completion means usable output, not a correct review.',
    'Quality grades are intentionally absent until findings are checked against the case oracle and code.', '',
    `Model requested: ${manifest.model}. Repetitions: ${manifest.runs}. Split: ${manifest.split}.`,
    'Stock Pi CLI and the SDK adapter use the same pinned Pi release, checkout, common brief, provider configuration, thinking setting, and wall-clock limit.',
    'The intervention adds structured submission, execution receipts, and their instructions. This compares that bundle, not the SDK alone.', '',
    '| Case | Repeat | Arm | Output | Seconds | Review |', '|---|---:|---|---|---:|---|'];
  for (const row of rows) lines.push(`| ${row.case} | ${row.repeat} | ${row.arm} | ${row.status} | ${row.seconds.toFixed(1)} | [read](${row.run_id}/review.md) |`);
  lines.push('', 'Missing, failed, and partial runs remain visible. Repeat attempts are not independent panel votes.',
    'See manifest.json for fingerprints, runs.jsonl for measured records, and each run directory for events and results.', '');
  return lines.join('\n');
}

export async function compare(options, dependencies = {}) {
  const corpus = join(here, 'corpus');
  await verifyCorpus(corpus);
  const corpusManifest = json(join(corpus, 'manifest.json'));
  const cases = corpusManifest.cases.filter(c => (options.split === 'all' || c.split === options.split) && (!options.case || c.id === options.case));
  if (!cases.length) throw Error('No cases selected');
  const out = resolve(options.out);
  if (out.startsWith(root + '/') || out === root) throw Error('Put comparison artifacts outside the Cadre worktree');
  mkdirSync(out, { mode: 0o700 });
  const pkgDir = join(integration, 'node_modules/@earendil-works/pi-coding-agent');
  const version = json(join(pkgDir, 'package.json')).version;
  if (version !== '0.84.4') throw Error('Comparison requires pinned Pi 0.84.4; run npm ci in integrations/pi-review');
  const prompt = readFileSync(join(here, 'prompt.md'), 'utf8');
  const source = resolve(options['agent-dir'] ?? process.env.PI_CODING_AGENT_DIR ?? join(homedir(), '.pi/agent'));
  const provider = options.model.slice(0, options.model.indexOf('/'));
  const work = mkdtempSync(join(tmpdir(), 'cadre-pi-eval-'));
  const manifest = {
    schema: 'cadre/pi-comparison@1', model: options.model, sdk_version: version, runs: options.runs,
    split: options.split, thinking: options.thinking, timeout: options.timeout, settings,
    corpus_sha256: corpusFingerprint(corpus), software: softwareHashes(),
    prompt_sha256: digest(prompt), cases: cases.map(c => c.id), started_at: new Date().toISOString(),
    intervention: 'submit_review and execution_receipts tools plus their instructions; stock CLI versus SDK lifecycle',
  };
  const rows = [];
  const append = row => appendFileSync(join(out, 'runs.jsonl'), JSON.stringify(row) + '\n', { mode: 0o600 });
  try {
    const frozenConfig = join(work, 'config');
    manifest.provider_config_sha256 = copyConfig(source, frozenConfig, provider);
    save(join(out, 'manifest.json'), manifest);
    manifest.preflight = await (dependencies.preflightModel ?? preflightModel)(pkgDir, frozenConfig, options.model, options.thinking);
    save(join(out, 'manifest.json'), manifest);
    for (let repeat = 1; repeat <= options.runs; repeat++) {
      for (let index = 0; index < cases.length; index++) {
        const item = cases[index];
        const order = (index + repeat) % 2 ? ['stock', 'review'] : ['review', 'stock'];
        for (const arm of order) {
          if (JSON.stringify(softwareHashes()) !== JSON.stringify(manifest.software) || corpusFingerprint(corpus) !== manifest.corpus_sha256) throw Error('Evaluation code or corpus changed during the run; start a fresh comparison');
          const runId = `run-${String(rows.length + 1).padStart(4, '0')}`;
          const runOut = join(out, runId);
          mkdirSync(runOut, { mode: 0o700 });
          const runWork = mkdtempSync(join(work, 'attempt-'));
          const cwd = join(runWork, 'checkout');
          const trees = prepareCheckout(corpus, item, cwd);
          const agentDir = join(runWork, 'config');
          cpSync(frozenConfig, agentDir, { recursive: true });
          const env = { ...process.env, PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: '1', PI_TELEMETRY: '0' };
          for (const key of Object.keys(env)) if (key.startsWith('CADRE_')) delete env[key];
          const stdout = join(runOut, arm === 'stock' ? 'events.jsonl' : 'stdout.txt');
          const stderr = join(runOut, 'stderr.txt');
          writeFileSync(stdout, '', { mode: 0o600 }); writeFileSync(stderr, '', { mode: 0o600 });
          const args = arm === 'stock'
            ? [join(pkgDir, 'dist/bundle/cli.js'), '-p', '--mode', 'json', '--no-session', '--no-extensions', '--no-skills', '--no-prompt-templates', '--no-themes', '--no-context-files', '--offline', '--tools', 'read,bash,edit,write', '--model', options.model, '--thinking', options.thinking]
            : [join(integration, 'cli.mjs'), '--cwd', cwd, '--model', options.model, '--out', join(runOut, 'sdk'), '--thinking', options.thinking, '--timeout', String(options.timeout)];
          const baseRecord = { run_id: runId, case: item.id, arm, repeat, ...trees };
          append({ event: 'dispatch', ...baseRecord, at: new Date().toISOString() });
          let execution;
          const launchTime = Date.now();
          try { execution = await (dependencies.execute ?? execute)(process.execPath, args, { cwd, env, prompt, timeout: options.timeout, stdout, stderr }); }
          catch { execution = { exit_code: null, signal: null, timed_out: false, seconds: (Date.now() - launchTime) / 1000, launch_error: true }; }
          let result;
          if (arm === 'stock') result = parseStock(readFileSync(stdout, 'utf8'), execution.exit_code, execution.timed_out);
          else if (existsSync(join(runOut, 'sdk/result.json'))) {
            try {
              result = json(join(runOut, 'sdk/result.json'));
              result.review = readFileSync(join(runOut, 'sdk/review.md'), 'utf8');
            } catch { result = { status: 'failed', review: '', reason: 'incomplete SDK artifacts', usage: null }; }
            if ((execution.timed_out || execution.exit_code !== 0) && result.status === 'ok') {
              result.status = 'degraded';
              result.reason = execution.timed_out ? 'timeout' : 'process did not finish successfully';
              // Keep the original SDK artifact intact, but the normalized review
              // must not present a completed verdict after the outer deadline.
              result.review = result.findings?.length
                ? result.review.replace(/\n*Verdict: (blocking|should-fix|no defects found)\s*$/, '')
                : `DID NOT COMPLETE: ${result.reason}`;
              result.review += `\n\n_TRUNCATED: ${result.reason}; review did not complete.\n`;
            }
          } else result = { status: 'failed', review: '', reason: 'no SDK result', usage: null };
          const expectedModel = options.model.slice(provider.length + 1);
          const observed = { provider: result.provider ?? null, model: result.model ?? null };
          if (result.status === 'ok' && (observed.provider !== provider || observed.model !== expectedModel)) {
            result.status = 'invalid'; result.reason = 'observed model identity does not match requested model';
          }
          let treeUnchanged = false;
          try {
            treeUnchanged = git(cwd, ['status', '--porcelain', '--untracked-files=no']) === '' && git(cwd, ['rev-parse', 'HEAD^{tree}']) === trees.reviewed_tree && git(cwd, ['rev-parse', 'BASE^{tree}']) === trees.base_tree;
          } catch { /* A damaged checkout is an invalid run, not a missing observation. */ }
          if (!treeUnchanged) { result.status = 'invalid'; result.reason = 'reviewer changed or removed the checkout'; }
          if (JSON.stringify(softwareHashes()) !== JSON.stringify(manifest.software) || corpusFingerprint(corpus) !== manifest.corpus_sha256) {
            result.status = 'invalid'; result.reason = 'evaluation software or corpus changed during this run';
          }
          writeFileSync(join(runOut, 'review.md'), result.review ?? '', { mode: 0o600 });
          save(join(runOut, 'result.json'), result);
          const row = { ...baseRecord, ...execution, status: result.status, reason: result.reason, requested_model: expectedModel, observed,
            usage: Array.isArray(result.usage) ? sumUsage(result.usage.map(usage => ({ usage }))) : result.usage ?? null,
            tool_calls: Array.isArray(result.tool_calls) ? result.tool_calls.length : result.tool_calls ?? null, tree_unchanged: treeUnchanged };
          rows.push(row); append({ event: 'complete', ...row });
          writeFileSync(join(out, 'report.md'), report(rows, manifest), { mode: 0o600 });
          console.log(`${runId} ${item.id} r${repeat} ${arm}: ${row.status}, ${execution.seconds.toFixed(1)}s`);
          rmSync(runWork, { recursive: true, force: true });
        }
      }
    }
    save(join(out, 'adjudication.template.json'), {
      schema: 'cadre/pi-adjudication@1', status: 'NOT_ADJUDICATED',
      instructions: 'Read each complete review against the hidden oracle and code. Record HIT/MISS/DEFER for buggy cases; judge each extra finding separately. Do not label every extra false. Evidence must quote the original review. Keep author identity and grading method explicit.',
      runs: rows.map(row => ({ run_id: row.run_id, key_verdict: null, evidence: null, extra_findings: null })),
    });
    return { out, rows };
  } finally {
    rmSync(work, { recursive: true, force: true });
    manifest.finished_at = new Date().toISOString();
    manifest.completed_runs = rows.length;
    manifest.expected_runs = cases.length * options.runs * 2;
    save(join(out, 'manifest.json'), manifest);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (options.help) console.log('node evals/review-v1/compare.mjs --model provider/model --out NEW_DIRECTORY [--runs 2] [--split development|holdout|all] [--case ID] [--thinking off] [--timeout 180] [--agent-dir DIR]');
    else { const result = await compare(options); if (result.rows.some(r => r.status !== 'ok')) process.exitCode = 1; }
  } catch (error) { console.error(`comparison: ${error.message}`); process.exitCode = 1; }
}
