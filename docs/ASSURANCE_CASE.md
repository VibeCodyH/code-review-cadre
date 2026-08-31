# Assurance case

Claims about what the harness protects, each backed by a test that fails if
the claim stops being true. To verify one, grep the quoted name in
`tests/review-smoke.sh` or `tests/engine-seam.sh` and run that suite. Anything backed only by a design
description belongs under non-goals instead — naming what this does NOT
protect against is half the point of the file.

The form is borrowed from alibaba/open-code-review's `ASSURANCE_CASE.md`. The
bar is not: theirs backs each claim with a description of the design; every
claim here cites a test.

## Claims

**1. A checkout handed to reviewers carries no credential-shaped files.**
Several adapters run their CLI with full tool approval, so the checkout is
the blast radius. `secrets_preflight` (lib/common.sh) refuses the run: exit 3,
fail closed, an unreadable directory is a refusal rather than a pass. Four
config files that usually carry no secret (`.npmrc`, `.netrc`, `.pypirc`,
`.dockercfg`) are gated on content instead of name, so a one-line
`package-lock=false` `.npmrc` does not fail every Node repo on its first run.
Tests: "a .env is still refused on the name alone", "an .npmrc carrying a
token IS refused", "benign .npmrc + credentials/ dir accepted".

**2. A credential deleted from the tree cannot reach reviewers through
history.** The checkout is a synthetic two-commit repo; `git log -p --all`
has no earlier history to answer with. External backing for treating history
as the leak path: gitleaks scans history by default (`gitleaks git` wraps
`git log -p`; `gitleaks dir` is the working-tree special case) — the
industry-standard scanner defaults to history precisely because a tree-only
view is known insufficient. The harness removes the history rather than
scanning it.
Test: the "deleted credentials must not reach reviewers" case, where a
reviewer that runs `git log -p --all` on the checkout finds nothing.

**3. A reviewer that did not finish is never scored as one that did.**
`classify_run` files truncated or partial output as degraded: kept, printed
in full, and excluded from a finding's denominator except where it raised
the finding — silence is not dissent.
Test: "it is degraded, findings kept".

**4. A review with no findings and no bottom line is not a clean pass.** The
`inconclusive` state exists because three artifacts on this machine scored
`ok` while being a summary, a clarification request, and a parroted diff —
counted as complete reviewers whose silence cleared every file.
Tests: "waffle -> .md.inconclusive", "run: filed .md.inconclusive".

**5. Harness state cannot contaminate the reviewed tree.** `CADRE_HOME` or
`CADRE_WORK` inside — or equal to — the reviewed repo is refused, because
state copied into the checkout is answer-key material sitting where the
reviewers read.
Tests: "nested CADRE_HOME refused", "CADRE_HOME == repo refused",
"CADRE_WORK == repo refused".

**6. The docs cannot silently drift from what the CLI does.** Adapter
invocation blocks are generated from `--print-command`, and the corrections
that mattered are pinned by tests.
Tests: "docs say the adapter wins", "preflight claim corrected", "but still
says what it misses".

**7. A reviewer is scored on what it wrote, not on what survived the merge.**
`claims[]` in `findings.json` is extracted from each reviewer's own file by
grep, with no model in the path. The merge is lossy on purpose — it truncates
an over-long review to fit the synthesizer's budget and leaves a dead reviewer
out entirely — so a projection built from the synthesis would mark a reviewer
as having missed a bug it actually reported.
Tests: "cap: the finding is NOT in the merge", "cap: but it IS claimed".

**8. Nothing downstream of the reviewers can write to the graded layer.**
Verification, synthesis and `settle` all produce opinions about findings, and
all three write `findings[]` only. A `status`, `ledger_id` or verify verdict on
a claim would make a reviewer's score a function of a later model's quality
while still looking like a score.
Tests: "fj: claims carry no settle/verify fields", "engine_claims writes no
status field", "engine_claims writes no ledger_id".

**9. A panel that degraded still leaves a record.** `findings.json` is written
whether the merge succeeded, failed, was skipped by the capability preflight,
or was never asked for — a run with one usable review still made claims, and
the degraded runs are the ones a benchmark most needs to see.
Tests: "ns: findings.json still written", "one: findings.json written",
"one: claims survived".

**10. The recorded panel is the panel that was asked for.** Every roster member
appears in `panel[]`, and the four states are kept apart: `ok`, `degraded`,
`absent` (asked, never answered — silence proves nothing) and `skipped` (never
asked, on purpose, with the gate and reason recorded). A seat filtered out by a
`?min-lines` gate is not in the dispatch list, so a panel derived from that list
alone reports a smaller roster than the user configured.
Tests: "gt: the gated seat is in the panel", "gt: it is skipped, NOT absent",
"gt: the roster size is honest".

**11. One stray byte cannot empty a reviewer's claims.** A NUL byte anywhere in
a review makes grep treat the file as binary and collapse its whole output to a
diagnostic on stderr. Without `-a` on the extraction grep, every finding in that
review vanishes and the reviewer scores as having found nothing — silently, with
no diagnostic in the pipeline.
Tests: "by: without -a the whole review is suppressed", "by: the pre-existing
claims survive", "by: the finding after the bad byte is claimed".

**12. A published number names the inputs that produced it.** Every row of
`slots.tsv` and every `complete` record carries a content hash for the rendered
prompt, for the adapter code that ran, and for the harness files that shape a
review (`bin/agentcall`, `lib/common.sh`, `lib/run-review.sh`,
`lib/run-pass.sh`, `lib/grade.sh`, `lib/prompts/*`). `prompt_bytes` was a size,
so two prompts of equal length were one row; `CADRE_PROMPT_FILE` replaces the
brief wholesale, which made the highest-leverage input the least described.

`adapter_sha` covers the files `agentcall` would source that define anything for
that agent — both copies of `<agent>.sh`, and any other file in either directory
mentioning `_<agent>(`. It sources every `*.sh` in both directories into one
namespace, so a foreign file defining `run_<agent>()` is a different reviewer
behind an otherwise unchanged adapter file.

**The hash is EMPTY whenever it could not be fully determined** — a
reconstructed row, a promptless adapter that received no shared brief, a box
with no sha256 tool, an unreadable or missing input, or any hashing step that
exits non-zero. Never a zero, never a partial digest: the digest of an empty
read is *stable*, so two runs that both failed would compare EQUAL, which is the
one answer this field must never give. Per-file digests are hashed rather than
concatenated bytes, so no pair of inputs can straddle a field boundary and
collide.

`cadre receipts` states whether every row in a comparison ran against the same
harness, on both branches — agreement and disagreement.
Tests: "adapter hash is per adapter", "adapter hash sees a foreign override",
"and ignores an unrelated adapter", "one harness hash for the panel",
"harness: agentcall is hashed", "sha: an unreadable input is EMPTY",
"sha: never the digest of nothing", "sha: file boundaries are kept",
"harness: a split is called out", "harness: agreement is stated".

**13. Receipts do not average across a schema change.** `slots.tsv` rows carry
the schema version that wrote them, and `cadre receipts` groups by
(family, schema) rather than by family. Rows written before the column existed
print schema `?` — unknown, not a default — because they straddle the change to
what `secs` means on a failed seat and nothing on disk separates the halves.
Nothing is excluded, so older panels stay readable.
Column 8 is read as a version only when it *reads* as one: a dataset written by
the older `lib/aggregate.sh` carries `source` there, and `recorded` /
`reconstructed` would otherwise have split every family into two named schemas.
Tests: "mixed: one row per schema", "mixed: the two secs never merge",
"mixed: pre-#19 panels still read", "olddata: a source word is never a schema".

## Non-goals, named

- **The preflight reads filenames, plus content for exactly four config
  files. A key in a source file passes.** An AWS key hardcoded in
  `src/config.js` is an ordinary tracked filename; it rides into a checkout
  handed to auto-approving CLIs. That is a deliberate no-dependency
  tradeoff. If a repo may carry in-source secrets, run a content scanner
  (`gitleaks dir`) before pointing cadre at it.
- **Leak control is not a sandbox.** Adapters with full tool approval can
  read your filesystem. METHOD.md §5 "What leak control does NOT buy you"
  says what the boundary actually is, and when you need a container.
- **A public target can leak its own answer** through issue and PR prose, no
  matter how shallow the clone. METHOD.md §5 — checking that is on you at
  target-pick time.
- **Receipts do not measure hidden reasoning tokens, provider billing, or
  in-CLI retries.** METHOD.md §6.
- **The input hashes are provenance, not tamper-proofing.** They are computed
  by the same tree they describe, so anyone who can edit `lib/` can edit what
  gets hashed. What they buy is that a comparison spanning an edit becomes
  visible instead of silent. Nothing here is a signature and nothing verifies
  a tree against a published manifest.
- **A scratch file in the tree is a source file to the harness.** Planning
  notes, TODO dumps and other author-written artifacts ride into the checkout
  like any other file — tracked, or untracked-but-not-gitignored (carried on
  purpose: a change whose whole contribution is new files must stay
  reviewable). A note spelling out the author's reasoning hands reviewers the
  blind spot the fresh checkout exists to remove — the rationale that produced
  a bug reads the code the way the author did — and in a graded pass it can
  spell out the answer. The harness cannot tell a scratch note from
  documentation. Keep session scratch out of the tree, or gitignore it,
  before pointing cadre at the repo.
- **Capability declarations are seeded from measured refusals, not
  exhaustive.** An undeclared quirk costs one wasted paid call, not a lost
  review — loose is safe, and a declaration earns its place from an observed
  refusal, never a guess. docs/ADDING-AN-AGENT.md has the contract.
- **The engine/benchmark seam is checked in the source, not enforced at
  runtime.** `bin/cadre` is one binary that sources both halves, so every
  function is in scope regardless of which side owns it;
  `tests/engine-seam.sh` reads the code for a crossing rather than observing a
  refusal, and it cannot see one made through a variable or an `eval`. Real
  isolation arrives with the two-binary split. Claim 8 is the part that IS
  enforced in the output: the assertions there run against a findings.json
  produced by a real panel.
