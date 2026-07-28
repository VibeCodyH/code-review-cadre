# Deep review, 2026-07-28

Reviewers: this session's main loop (read the core paths directly), `codex` and
`grok` as independent cross-model audits, and three Sonnet subagents scoped to
docs drift, test coverage, and adapter parity. Every defect listed as fixed was
reproduced before it was fixed.

## Verdict

**The thesis survives. The mechanisms were weaker than the thesis, and they were
weakest exactly where the thesis is strongest.**

The claim cadre is built on — that reviewer #4 should bring a *different failure
set*, not a better score, so what you want is a roster and not a leaderboard —
held up under a deliberate falsifier pass. Neither external auditor could break
it. What both of them broke instead was the **evidence chain underneath it**:
`(valid keys) -> (reliable labels) -> (stable failure sets)`. Every serious
finding in this review is a link in that chain, not the thesis.

And the single largest problem was not in any auditor's report. It was
structural, and visible only from the outside:

> The judge-reliability rules decided on 2026-07-27 — two graders agree and
> that's the grade, a split means UNRESOLVED and scores nothing, a split is
> evidence about the KEY and not the judge, and a grade with no quote carries no
> weight — were written into the prompts and into my notes. **They were never
> built into the harness.** `cadre panel` did the opposite: it merged two
> judges' grades for one candidate into a single cell and destroyed the
> disagreement the judge-specific report filenames exist to preserve.

That is the shape of the whole review. The reasoning is sound and ahead of the
code, and the code was quietly reporting cleaner results than it had earned.

## Thesis, item by item

Both auditors were asked to attack, not to assess. The scores below are theirs
where they agree with my read, and mine where I disagree.

**Roster over leaderboard — SURVIVES.** No attack landed. The one real tension
is internal: `primary`/`secondary` slot labels imply a ranking the decorrelation
thesis spends its whole argument denying. That is a naming problem, not a
methodology problem, but it is the kind that teaches users the wrong model.

**Answer keys mined from fix commits — SURVIVES, with the sharpest caveat in
the project.** The miner does not sample "bugs a reviewer should catch." It
samples bugs that were *author-noticed, soon-repaired, test-accompanied,
blame-dominated, and small*. That is the subset already describable enough to
write a test for. The defects AI reviewers actually miss in production are
frequently the opposite: silent, multi-file, no new test, latent until an
external event. So a HIT measures *agreement with that author's later framing*.
The open track's own measured case — 0/2 on the key while stating five real
defects, one of which was later fixed — is the proof, and it is already the
recorded position: **the key is the floor, not the ceiling.** The docs say this.
The tool's own report text says this. It holds up. It just needs to keep saying
it louder than the score does.

**DEFER as an outright disqualifier — PARTIAL, and this one needed a code
change.** The threat model is right: a reviewer that finds a bug and argues it
away supplies *cover* for shipping, with citations, which is worse than silence.
But the implementation was a non-tunable kill switch sitting on the **softest**
grade boundary in the tool, driven by a single judge measured splitting on about
one item in three. The errors are asymmetric — a false DEFER zeroes a candidate,
a false HIT only pollutes a cell — and the candidates most likely to be
mislabelled DEFER are the verbose, cautious ones the panel thesis most wants.
Fixed as far as one commit can fix it: **a DEFER with no supporting quote no
longer disqualifies.** Without a quote that verdict is the judge's claim, not
the candidate's behaviour, and it is not re-checkable. It is still counted and
still surfaced for a human to read. The full fix is the dual-grader gate below.

**Decorrelation measurable at the operating sample size — this is the real
open question.** Grok's strongest attack, and I do not think the answer is in
the repo yet. At 2 runs against a handful of key items, with documented
run-to-run flip-flops on the same checkout and prompt, "different failure set"
is hard to distinguish from independent variance. `cadre panel` computes no
correlation, no uncertainty; it prints a matrix and asks a human to eyeball
gaps. The docs confess the small n honestly — and then the product still sells
roster optimization from that n. **The honest framing is that the matrix is a
hypothesis generator, not an estimator.** That is genuinely useful and worth
paying for; it is not the same claim as measuring decorrelation.

**Contamination and the public/private split — PARTIAL.** `ref-*` passes are
labelled contaminated by construction and excluded from roster signal, which is
the right call, correctly implemented. The residual risk is a user reading a
reference score as a result anyway.

**Overclaim scan — the numbers are external and the README says so, but then
uses them anyway.** The 56.8%-caught-by-exactly-one-model and 47/72/89%
coverage figures come from someone else's preprint. The README hedges them as
directional, and then `doctor` and `FREE-PANEL` operationalize the same numbers
as the reason to staff a second chair. Cadre's own corpus does not produce them.
This is the one item I would change before a single dollar changes hands: keep
the citation, drop the load-bearing use.

## Mechanisms: what was broken, and what got fixed

Committed on this branch, all with reproductions and tests (316 passing, up
from 295).

**The panel matrix invented coverage three separate ways.** This mattered more
than the grading bugs, because the matrix is the artifact the entire roster
thesis rests on — and all three defects made it read *cleaner* than the data
supported.

1. K numbers are local to one answer key, so every pass starts at K1. Keying
   the matrix by number alone folded pass alpha's K1 (say, an auth bypass) into
   pass beta's K1 (a dropped write). A hit on one reported the other as covered,
   and `--save` persisted that false coverage into the roster comments.
2. Two judges grading one candidate wrote into the same cell, so they merged.
   This is the one that erased the July 27 rules.
3. An INVALID report — one where a run reproduced key headings verbatim, so the
   setup is known compromised — still had its surviving HIT rows close coverage
   gaps. The README already said the whole pass is excluded from scoring. The
   panel was the place still spending it.

**A registered pass that never ran vanished from the denominator.** A missing
key or checkout printed `skipping` to the scrollback and disappeared. The saved
report could then state `SLOT: primary` and `Caught every blocking item in every
run (2/2)` when the registered benchmark was four blocking observations and half
were never graded. Nothing in the saved artifact recorded the omission. Skipped
passes now appear in the report, and a short denominator cannot recommend a
seat.

**A judge outage could publish as a score of zero.** The grader validated only
that the reply was *some* valid JSON. A provider error body — `{"error":"quota
exhausted"}` — parsed, `unusable` defaulted to false, every absent item
defaulted to MISS, and a plausible 0/N candidate score got saved instead of an
outage. Now requires `.items`.

**`extract_json` failed on a lone brace inside a JSON string.** Newly reachable
*because* `quotes` became required: a reviewer quoting a line of shell or C
carries an unbalanced brace, and a perfectly good grade was recorded UNUSABLE
with the judge taking the blame. This is the failure mode I would watch for
generally — a correctness fix in one layer becoming a reliability bug in
another.

**`CADRE_WORK` inside `CADRE_HOME` was refused on the benchmark path and not on
the live one.** From a reviewer's own working directory, `../../../keys`
resolved straight into the answer keys. The check moved into `common.sh` so
every entry point pays it.

**A complete short review of rate-limit code was classified as a provider
refusal.** The README claims the length guard prevents exactly this. In code,
being short was what *enabled* the keyword match, and a concise real review has
no adapter marker to rescue it. A refusal never states a severity-tagged
finding, so the keyword match now requires zero findings.

Also: the judge ran unscrubbed while every other model call was scrubbed, so the
judge saw `CADRE_HOME`. `secrets_preflight` refused on `password = "$PGPASSWORD"`,
where an env-var reference is not a credential. `run-pass.sh` used `command -v`
where the rest of the tool uses `agent_installed`, so a wrapper-only adapter
read as "not installed" and quietly shrank the run. An absent review in the open
track printed its row without incrementing `unusable`, so the totals said
"unusable runs: 0" for a two-run request with one review.

## Scope, expanded at the same time

`cadre review` was diff-only, which came up because a session asked it to review
something that was not a change and was told the tool did not do that. It does
now: `cadre review --full <target>` takes a repo, a subdirectory, a directory
that is not a repo at all, or a single file.

Worth recording *why* it is not simply the diff path with the diff turned off.
Target mode shows reviewers strictly **more** than a diff review does — the
whole tree rather than what changed — so it is built around that rather than
around reusing the existing plumbing:

- Nothing is fetched or cloned. Only the named files are copied, so history
  cannot leak because it is never transferred in any form. This is a stronger
  guarantee than the diff path's synthetic two-commit repo, not a weaker one.
- `.gitignore` is honoured even when the target is not a repo, and applied to
  the **worktree** rather than only the index. `git add` skips an ignored file,
  which keeps it out of the diff and leaves it sitting in the directory every
  reviewer runs in — and `secrets_preflight` skips ignored files too, so an
  ignored `.env` would have passed the credential check and still been readable.
- There is a size ceiling, refused before any reviewer exists, and the error
  names the biggest directories because the real mistake is almost always a
  `node_modules` or a `vendor` nobody meant to include. Every reviewer reads all
  of it, so a target is a bill as much as a review.
- `files.txt` records what the reviewers saw. The checkout is a temp directory
  that gets deleted, so otherwise nothing afterwards would say what
  `--full ./docs` actually covered.
- A separate brief. A reviewer told to review a change reports on volume: handed
  a whole tree under the diff brief, it treats every file as new work and scales
  its findings to the file count.

`--scope`, `--ask` and `--brief` were designed alongside this and deliberately
not built yet. `--full` alone answers the actual complaint, and a committed
one-flag version is worth more than an unfinished five-flag one.

## What I did not fix

Ranked by what I would do next.

1. **Build the dual-grader gate.** Two judges agree, that's the grade. They
   split, the item is UNRESOLVED, scores nothing, and the report states a range.
   A split is evidence the **key** is underspecified, not that the judge is bad.
   This is the recorded decision, it is the single largest remaining gap, and
   the panel fix in this branch is a prerequisite rather than a substitute — the
   matrix can now *show* a disagreement, but nothing yet acts on one.
2. **Reframe the panel matrix as a hypothesis generator in the docs**, and stop
   the external preprint numbers from carrying product weight.
3. **Rename `primary`/`secondary`.** They import the leaderboard the thesis
   rejects.
4. Docs corrections found by the drift audit: the CLI-reference rows for
   `claude` and `grok`, and the "filename not contents" claim.
5. Adapter parity, which is a real leak surface and the only place a second
   model can quietly gain capability: `claude.sh --safe-mode`,
   `codex.sh --ignore-user-config`, `cursor.sh` sandbox pinning, and the
   grok/qwen rc fallback. The standing rule holds — probe the agent, never
   trust the capability flag.

## One note on method

Three findings in this review were confirmed by running the code rather than by
reading it, and in each case the reproduction changed the conclusion. The
`extract_json` brace bug reads like a cosmetic parser nit and is actually a
mechanism that blames the judge for a good grade. The panel judge-merge reads
like a display issue and actually deletes the measurement. `cadre panel`'s
output looked correct until it was run against two report files whose names
differed only in the judge.

That is the same argument the project makes about reviewers, turned on itself:
reading finds candidates, execution decides.
