# Assurance case

Claims about what the harness protects, each backed by a test that fails if
the claim stops being true. To verify one, grep the quoted name in
`tests/review-smoke.sh`, `tests/engine-seam.sh`, `tests/grading-confounds.sh`,
`tests/cost-first.sh`, `tests/key-two-sided.sh`, `tests/panel-accounting.sh`
or `tests/byte-identity.sh` and run that suite. Anything backed only by a
design description belongs under non-goals instead — naming what this does NOT
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
`lib/run-pass.sh`, `lib/grade.sh`, `lib/input-lock.py`, `lib/prompts/*`). `prompt_bytes` was a size,
so two prompts of equal length were one row; `CADRE_PROMPT_FILE` replaces the
brief wholesale, which made the highest-leverage input the least described.

Before a benchmark run, the input lock also checks every loaded adapter file
and prompt source, including local overrides. A mismatch stops dispatch;
completion records carry the lock fingerprint and the expected adapter/source
hashes. `tests/input-lock.sh` exercises added, deleted, and modified inputs,
malformed locks, custom inputs, refusal before adapter execution, and receipt
agreement. This checks drift before dispatch, not concurrent writes after the
check or external CLI/provider changes. See [input locks](INPUT-LOCK.md).

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

**14. A regrade cannot destroy the grade it replaces.** Re-scoring writes to a
side file, appends the prior verdicts to a `<grade>.regraded.jsonl` ledger
beside the grade, and only then swaps. A regrade whose judge came back
UNUSABLE does not swap at all: the prior grade stays on disk, scores nothing
on that pass, and the run is reported as a grading failure with the provider's
reply kept. Failing to append the ledger also refuses the swap, keeping the
unapplied reply beside the grade — a regrade whose prior cannot be kept is the
overwrite this prevents. A refused regrade exits 5 even when other runs scored,
because it takes a run that WAS scored out of the table's denominator.
Tests, in `tests/grading-confounds.sh`: the ledger records an unchanged
regrade, a moved verdict keeps `before`/`after` and the key and harness
hashes, an unusable regrade leaves the prior grade intact with
`kept_prior: true`, an unwritable ledger keeps both the prior and the
`.unapplied.json` reply, the refused case exits 5 beside a scored run, and
`cadre run` reusing a grade appends nothing.

**15. A confound is stated before the number it explains.** Output cap, runs
that scored nothing because they were cut off or came back empty, scored runs
whose adapter reported the cap was hit, the run-to-run spread, and what a
regrade moved are all printed above the hit line in the report footer, and
the noise floor is printed above the panel's rate table. An unrecorded cap
prints `not recorded` rather than a default, and a spread measured from one
sweep prints `not measured` rather than 0.
Tests, in `tests/grading-confounds.sh`: each confound line is asserted to sit
at a lower line number than `- blocking items hit:`; plus the `not recorded`,
`mixed`, and `not measured` branches.

**16. Rates from different output caps are not compared.** `cadre panel`
refuses its observed hit-rate bounds when rows ran under different caps, names
each row's cap and the fix, and suppresses the within-floor grouping for the
same reason. A single row whose own runs straddled two caps refuses the
comparison by itself, and says so in its own sentence rather than borrowing the
cross-row one, which would be false about it. Cost bounds survive, because a
per-row spend receipt is not a comparison between rows.
Tests, in `tests/cost-first.sh`: "Output caps differ across rows", the refused
bounds line, no within-floor line while caps differ, the internally-mixed row
refusing alone once the other rows agree, and the comparison returning when
every row is on one cap.

**17. A rate difference smaller than the measured noise is not a ranking.**
The floor is the largest run-to-run spread any single row showed against its
own runs; rows within that floor of the top rate are named as indistinguishable
rather than ordered. A table where no row ran a pass twice prints
`Noise floor: NOT MEASURED` and no row is described as better than another. A
row whose rate is an UNRESOLVED range is not placed against an exact one at
all: comparing its low bound would call an exact row "top" over a row that may
in fact be the highest. In the report, a spread is refused outright when the
run slots did not grade the same passes, or when any slot carries an
UNRESOLVED item, because a slot rate is then a lower bound rather than a rate.
Tests, in `tests/cost-first.sh`: the unmeasured branch, the largest spread
winning over the first read, the named set shrinking as the floor drops, and
an unresolved row listed as not placed. In `tests/grading-confounds.sh`: two
slots with equal denominators over different passes, and an unresolved slot.

**18. A test that fails internally cannot be reported as a pass.** `test.sh`
lints every `tests/*.sh` before running it: it must either enable `set -e` in
its first 15 lines (`set -e`, `set -euo pipefail`, etc.) or end on
`[ "$FAIL" -eq 0 ]` as its last non-blank, non-comment line. A script that
satisfies neither is reported `FAIL ... (no exit contract: ...)` with a
non-zero receipt and is not executed, so the suite fails rather than counting
the lie as a pass. `CADRE_TEST_DIR` overrides the discovery directory for
self-testing without changing anything else.
Tests: `tests/runner-contract.sh` (counter style) — an honest errexit pass and
an honest counter-style pass both report PASS, the lying shape `false` then
`echo` is rejected with "no exit contract" and a non-zero suite exit, an
errexit script containing `false` then `echo` fails via errexit, an honest
`exit 7` fails, and a clean all-pass fixture dir exits 0 proving the lint does
not red-flag honest tests; the fixture dir never includes `runner-contract.sh`
itself. Residual: the lint is a proxy — `set -e` has exemptions (commands
inside `if`, `||`, `&&` and others do not abort) and a counter-style test can
still forget to call `check`, so a missed assertion that never increments `FAIL`
still passes.

**19. A panel's time reconciles, and a residual is recorded rather than
absorbed.** The `panel` event in `runs.jsonl` carries the measured wall clock,
the pre-pass and seat seconds, and `unattributed_secs` = wall minus both, so
the three always add up. A seat with no timer adds nothing and is counted in
`untimed_seats`. The residual is signed: with seats run one at a time it
cannot go negative, so a negative one is reported in the report and on stderr
as a second counted twice; under `--jobs N` it is reported as a net balance, never as a measure of overlap. The
token residual is `null`, because no measured token total exists to reconcile.
Tests, in `tests/panel-accounting.sh`: "totals reconcile exactly", "sequential
residual is not negative", "the uninstalled seat is untimed", "token residual
is unmeasured", "so the residual is negative, and kept", "report flags double
counting", and the readers `receipts`, `seats` and the evidence export still
reading a panel that carries the event. Residual: seconds are whole, so a
residual under a second per timer is invisible, and the time after the clock
stops (the Receipts table, cleanup, synthesis) is named as untimed, not
measured.

**20. A change that claims to be behavior-neutral cannot move a fixture
artifact unseen.** `tests/byte-identity.sh` replays one synthetic panel (a seat
in every delivery state, a misconfigured seat, a repeated seat, a gated seat,
a synthesis) and one graded pass through stub adapters, and compares every
file they leave, including the prompts handed to the synthesizer and the
judge, byte for byte with `tests/fixtures/byte-identity/`. Only clocks, the
temp directory and the harness's own identity hashes are normalized, and
docs/BYTE-IDENTITY.md lists each one. A mismatch prints the diff and fails; an
intended change regenerates the goldens with `--accept`, so the move is in
the commit.
Test: `tests/byte-identity.sh` itself. Residual: it sees only what the fixture
exercises (one job, diff mode, no adjudication, no real adapter or model), and
timings are compared as present or `null`, not by value.

**21. A key item is registered only when it is proved on both trees.**
`cadre add-pass` refuses a keyed pass unless each item cites a `path:line`
that resolves in the target tree and that the reference fix changes (three
lines of context, target numbering only). The reference fix is recorded by
`make-pass` beside the meta, never in the checkout. An item that cites nothing
the fix touched, a line past the target's end, or a line only the fixed file
has is refused by name, and nothing is registered. Each keyed pass in a grade
report states which items were proved, which were added since, or that
nothing was recorded.
Tests, in `tests/key-two-sided.sh`: a proved citation, a unique basename, one
passing citation among context, the outside-the-fix / past-the-end / fix-only
numbering / no-citation / untouched-file refusals, one item's citation not
proving another, add-pass refusing without a recorded fix, refusing a bad
item and then registering once only that citation is corrected, a CLEAN key
registering with no proof, the per-pass report line including an item added
after registration, and make-pass writing the record outside the checkout.

**22. No seat is recommended from one round.** The report counts the fewest
scored runs any pass with blocking items had, and prints it beside the rate on
the rate's own line and above the hit line in the footer. Below two, a
`SEAT:` verdict or a rate-based `DO NOT SLOT` becomes `ONE ROUND, not
slottable`; a quoted DEFER still disqualifies. Two run slots over different
passes count as one round each. `cadre panel` prints `ROUNDS` beside every rate
and does not place a row under the floor, or with no recorded count, in the
within-floor grouping.
Tests, in `tests/grading-confounds.sh`: one round withholds the seat and a
second round alone restores it; a low single round falls too; a DEFER stands;
slots over different passes are one round; no blocking item prints `-`. In
`tests/cost-first.sh`: the `ROUNDS` column, a one-round top rate not placed and
then placed after a second round, a legacy report not placed, every row under
the floor ranking nothing, and operator prose not read as a count.

## Non-goals, named

- **The two-sided key check proves a citation, not a grade.** It shows that an
  item points at code the reference fix repaired. It does not replay the judge,
  so it cannot show that a do-nothing review scores MISS or that a review of
  the clean tree scores MISS; both need model calls. A key edited after
  registration is not re-checked: the report compares item names, not bodies.
- **Two rounds is a floor, not a sample size.** It separates one draw from a
  repeated one. It does not make a two-round rate stable. The reversals that
  motivated it moved over three and ninety rounds.
- **Cap-matching is refused, not performed.** When two seats ran under
  different output caps the harness says the comparison is unavailable; it
  does not truncate the larger-cap run token-exactly and re-score it. That
  replay needs the serving stack's own tokenizer, which cadre does not have
  for a CLI seat, and a byte-count approximation would be a worse claim than
  declining to compare.
- **One noisy row sets the floor for the whole table.** The panel floor is a
  maximum, not a per-pair figure, so a single seat that disagrees with itself
  raises the bar every other row is read against and can bury a real
  difference between two steady seats. The direction is deliberate — calling a
  real difference noise costs you a seat, calling noise a difference staffs the
  wrong one — but it is a choice, not a measurement.
- **The noise floor is a spread, not a confidence interval.** It is computed
  from however many run slots a gauntlet happened to produce, usually two.
  It bounds what a delta has to clear to be worth reading; it does not give
  the delta a p-value, and two runs cannot.
- **The regrade ledger is provenance, not tamper-proofing.** It is a local
  append-only file with no signature. It makes a changed grade visible instead
  of silent; it cannot stop anyone editing it, the same scope #37 names for
  the harness hashes it records.
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
- **The served-model field records, it does not control.** `claudecr` reads
  the model out of the CLI's own result and declares it; cadre never passes
  `--model`, so a sweep whose default changes mid-run is *marked* (two rows,
  named by `receipts`), not refused. The value is trusted exactly as far as the
  adapter is — same channel and same posture as `cadre_state`. Nothing here pins
  a model for a benchmark; that is still the operator's job at sweep start.
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
