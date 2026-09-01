# Security and reliability checks

A reading list for a reviewer, not a scanner and not a scoring rubric. Nothing
here is wired into `lib/prompts/`: the review brief is kept byte-identical
across passes so results stay comparable, and 48 injected checks would break
that. Use this when you want a human or an agent to sweep a checkout
deliberately, or as source material if you ever add a `--checks <file>` flag.

Every row is written to be answerable **from the checkout alone**, and to be a
defect rather than a policy preference. Checks that need deployment state, a
live URL, or an account somewhere were dropped, as were checks that are real
but are not defects in the code under review. The drops are listed at the
bottom with the reason.

Severity is cadre's, not the source's. It is assigned by consequence:

- **blocking** — data loss or corruption, auth bypass, secret exposure, or
  silently wrong output reaching a user.
- **should-fix** — a real bug with a bounded blast radius: it fails loudly,
  needs an unlikely input, or gets caught before production.
- **nit** — cannot produce a wrong result on its own.

A pattern match is not a finding. Every row below still needs the consequence
named on the actual code before it gets reported.

Adapted from [goshipit](https://github.com/Capta1nRaj/goshipit) v0.1.3,
categories C and F. Source IDs are kept in the last column so the adaptation is
auditable. **This file is a derivative work and remains under Apache-2.0; the
rest of this repository is MIT.** See [../NOTICE](../NOTICE).

## Security

| Check | Severity | src |
| --- | --- | --- |
| User input reaching a DB query as string concatenation, or reaching `dangerouslySetInnerHTML` / `innerHTML` / `v-html` | blocking | C1 |
| A protected page or endpoint with no auth check — no middleware entry, no session read, no guard in the handler | blocking | C4 |
| CORS reflecting an arbitrary request `Origin` while `credentials: true`. Bare `Access-Control-Allow-Origin: *` on an API that carries no credentials is should-fix, not blocking — browsers already refuse to send credentials to it | blocking | C7 |
| A webhook handler that parses the body before verifying the provider signature, or that has no signature check at all | blocking | C8 |
| State-changing routes (POST/PUT/DELETE/PATCH) with neither a CSRF token check (`csurf`, `csrf_protect`, or the framework's built-in) nor `SameSite=Strict`/`Lax` on the session cookie. An explicit `@csrf_exempt` on a state-changing view is the same finding, stated out loud | blocking | C17 |
| Request data written without server-side validation. Client-side-only validation is not validation. Blocking when the unvalidated value reaches a write or a permission decision; should-fix when it only reaches a read | blocking | C18 |
| Lockfile `resolved:` URLs pointing outside the official registry, or an `.npmrc`/`.yarnrc` scoping a private registry with no auth token — dependency confusion, and it executes install scripts | blocking | C20 |
| `md5(`, `sha1(`, or bare `sha256(` hashing a password. (The source also flags bcrypt-without-argon2; that is a preference, not a defect — bcrypt with a sane cost is fine) | blocking | C22 |
| Multi-tenant schema (`tenantId`/`orgId`/`workspaceId`) with queries on shared tables that omit the tenant filter, or migrations with no row-level security | blocking | C26 |
| Resource lookup by user-supplied id with no ownership filter: `findById(req.params.id)`, `.findUnique({ where: { id } })`, `WHERE id = $1` with no `AND user_id = …` — IDOR | blocking | C27 |
| Request body passed whole into a write: `Object.assign(record, req.body)`, `Model.update(req.body)`, `create({ data: body })`, `**kwargs` into a model constructor — mass assignment, and the escalation path is a `role`/`is_admin` column | blocking | C28 |
| Server-only env vars (`DATABASE_URL`, `JWT_SECRET`, `STRIPE_SECRET_KEY`) read in a client component, or a server-only module (`prisma`, `pg`, `mysql2`, `redis`) imported into a `'use client'` file — the value ships in the bundle | blocking | C30 |
| User-controlled URL reaching a server-side HTTP client with no allowlist: `fetch(req.query.`, `axios.get(req.body.`, `requests.get(user_` — SSRF, and on a cloud host the first stop is the metadata endpoint | blocking | C32 |
| User-controlled path in a filesystem call: `fs.readFile(req.params.`, `path.join(__dirname, req.`, `open(user_` with no `path.normalize` plus a `startsWith(baseDir)` confinement check | blocking | C33 |
| `eval(`, `new Function(`, `vm.runInNewContext(`, or `exec`/`execSync` with an interpolated request value, outside test code | blocking | C34 |
| Auth, password-reset, payment, and contact endpoints with no rate limit. On an edge runtime, a Node-only limiter (`express-rate-limit`, `ioredis`) will not run at all; off edge, `@upstash/ratelimit` without `export const runtime = 'edge'` is the mirror mistake. Applies to the broader non-auth surface too, at lower priority | should-fix | C2, C31 |
| API error handlers returning `err.stack` or the raw driver error to the client — leaks paths, queries, and sometimes the connection string | should-fix | C3 |
| A manifest with no committed lockfile — installs are non-deterministic, but they fail loudly rather than silently | should-fix | C6 |
| Session cookies missing `httpOnly`, `secure`, or `sameSite`. Needs a second bug (XSS, a plaintext hop) to become an incident, which is what keeps it out of blocking | should-fix | C9 |
| No `Content-Security-Policy`, or one with `default-src *`, or missing `object-src 'none'` | should-fix | C11 |
| No `X-Frame-Options: DENY`/`SAMEORIGIN` and no `frame-ancestors` in CSP — clickjacking | should-fix | C12 |
| No `X-Content-Type-Options: nosniff` | should-fix | C13 |
| `Referrer-Policy: unsafe-url`, or absent — leaks any token that appears in a URL to third-party hosts | should-fix | C14 |
| No `Strict-Transport-Security`, or `max-age` under 31536000, or missing `includeSubDomains` | should-fix | C16 |
| GraphQL with `introspection: true` ungated by env, no depth or complexity limit, or subscriptions that never authenticate `connectionParams` | should-fix | C21 |
| TLS config permitting 1.0/1.1 in a committed `nginx.conf`, `ssl.conf`, or `.htaccess` | should-fix | C23 |
| Schema columns like `ssn`, `dob`, `card_number`, `bank_account`, `passport`, `tax_id` stored with no encryption at rest | should-fix | C25 |
| A redirect target taken from user input with no allowlist or same-origin check. Blocking instead when the redirect carries an OAuth code or a session token, because then it is credential exfiltration | should-fix | C19 |
| Source maps emitted in a production build (`devtool: 'source-map'` in the prod webpack config, `productionBrowserSourceMaps: true`, `sourcemap: true` in a Vite/Rollup prod build) | should-fix | C29 |
| Upload handlers trusting the request's own `mimetype`/`contentType` with no server-side magic-byte check. Blocking when the uploaded file is later served from the application's own origin — that is stored XSS | should-fix | C35 |
| No `Permissions-Policy` scoping camera/microphone/geolocation to `(self)` or `()` | nit | C15 |

## Reliability

| Check | Severity | src |
| --- | --- | --- |
| A migration that has already been applied being edited in place, rather than superseded by a new one — every environment past that point drifts silently | blocking | F5 |
| A form or contact handler whose only body is `console.log` or `res.json({ ok: true })`, with no write and no send — submissions are accepted and dropped, and nothing anywhere reports it | blocking | F15 |
| A webhook handler with no idempotency guard — no stored event id, no `processedEvents` table, no Redis `SET NX`. Providers retry by design, so this is duplicate writes and double charges, not a hypothetical | blocking | F16 |
| No top-level error boundary: no React `ErrorBoundary`, no `+error.svelte`, no 500 template, no `recover()` in a Go handler | should-fix | F2 |
| Error reporting present but inert — no `Sentry.init()` in the app entry, a placeholder DSN, or an init that is not gated to production | should-fix | F3 |
| Runtime version unpinned: no `.nvmrc`, no `engines`, no `runtime.txt`, no version in `go.mod`/`pyproject.toml` | should-fix | F1 |
| Dev-only tooling in production dependencies — test runners, type packages, linters, bundler plugins in `dependencies` rather than `devDependencies` | should-fix | F6 |
| No SIGTERM handler draining in-flight requests and closing the DB pool. On a rolling deploy, in-flight writes are cut mid-transaction | should-fix | F7 |
| No connection pool config — `connection_limit` in a Prisma URL, `pool` in pg/mysql2, `pool_size` in SQLAlchemy. A connection per request exhausts the database before it exhausts the app | should-fix | F12 |
| A foreign-key column (`REFERENCES`, `@relation`, `ForeignKey`) with no index on it — cascade deletes and joins become full scans, and it gets slow only once the table is big | should-fix | F17 |
| An `uncaughtException` or `unhandledRejection` handler that logs and lets the process continue. The defect is the swallow, not the absence: after an uncaught throw the process state is undefined, and modern Node already exits on an unhandled rejection by default. The handler should log and then exit | should-fix | F19 |
| Two lockfiles in the same project (`package-lock.json` alongside `yarn.lock`, `yarn.lock` alongside `pnpm-lock.yaml`) — different CI runners resolve different trees | should-fix | F20 |
| A listener registered per request or in a loop with no matching `off()`/`removeListener()` — an unbounded emitter leak. Raising `setMaxListeners(N)` silences the warning and does not fix it, so a call to it is itself a tell | should-fix | F21 |
| Transactional email sending from an `@gmail.com`/`@hotmail.com`/`@yahoo.com` From address — no custom SPF or DKIM is possible, so delivery degrades quietly | should-fix | F11, F18 |
| Raw `console.log` where the project already has a structured logger (Winston, Pino, `logging`, `slog`). Worth a look at what is being logged: a request body printed in full is a secret-exposure finding, not a nit | nit | F4 |
| No `/health`, `/ping`, or `/status` endpoint | nit | F8 |
| Missing `build`, `start`, or `test` script in `package.json`/`Makefile`/`pyproject.toml` | nit | F9 |

## Dropped, and why

These are in the source and are deliberately not above. A reviewer handed a
checkout cannot answer them, and a check that cannot be answered comes back as
a manufactured finding that adjudication then has to spend a pass discarding.

| src | Check | Why dropped |
| --- | --- | --- |
| C5 | Run `npm audit` / `pip-audit` / `cargo audit` and flag CVEs | An instruction to run a tool, not a defect pattern. Cadre reviewers are already told they may run targeted commands |
| C10 | GPL/AGPL packages in a commercial codebase | A licensing decision, not a defect. Belongs to whoever owns the license policy |
| C24 | CI pipeline missing a SAST tool or an audit step | Process maturity. Real, but it is not a defect in the code under review |
| F10 | Email-send patterns present but no transactional email library in deps | Prescribes an architecture from a grep. Sending mail without one of the named libraries is not by itself wrong |
| F13 | No automated database backup | Deployment state. Not visible in a checkout, and absence of a backup script proves nothing about whether backups exist |
| F14 | No uptime monitoring configured | Same — an external service, configured outside the repo |
| F5 (part) | Unapplied migrations | The applied-vs-pending split lives in the target database, not the checkout. Only the edit-in-place half survives, above |
