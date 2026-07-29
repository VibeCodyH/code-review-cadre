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

Committed on this branch, all with reproductions and tests (485 passing, up
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

**`cadre review` collapsed every failure to exit 1.** A credential refusal (3)
was indistinguishable from "the reviewers ran and failed" (1) to anything
wrapping cadre — including Cody's own WOWnet auto-review pipeline — and a retry
is the wrong response to a refusal. Found by tightening a test rather than by
reading the code, which is the third time in this review that mattered: the
loose version asserted "output contains `.env`" and would have passed whether or
not the preflight ran at all.

Also: the judge ran unscrubbed while every other model call was scrubbed, so the
judge saw `CADRE_HOME`. `secrets_preflight` refused on `password = "$PGPASSWORD"`,
where an env-var reference is not a credential. `run-pass.sh` used `command -v`
where the rest of the tool uses `agent_installed`, so a wrapper-only adapter
read as "not installed" and quietly shrank the run. An absent review in the open
track printed its row without incrementing `unusable`, so the totals said
"unusable runs: 0" for a two-run request with one review.

**A finished sweep reported COMPLETED with 3 of 30 reviews.** This one was found
by trying to *use* the tool for its own benchmark rather than by reading it, and
it is the most instructive failure in the review, because **nothing crashed** and
**four independent defects had to hold at once**:

1. `run-pass.sh` always exited 0 — it ended on `echo`. So `run_gauntlet`'s
   `|| return 1` had **never once fired** since the day it was written. A
   candidate that produced nothing carried the same status as one that produced
   everything.
2. A **budget** refusal was indistinguishable from a **rate limit**, in both
   directions, measured on the same night. claude's "You've hit your monthly
   spend limit" matched no keyword, so each pass failed in about a second and
   eleven more were attempted over fifty minutes. kimi's "429 … insufficient
   balance" matched the rate-limit scan and burned three backoff retries against
   an account with no balance. The distinction that holds is not
   permanent-vs-transient but *whether waiting inside this sweep can clear it*.
3. A pass whose **every run was UNUSABLE still counted as graded**, while adding
   nothing to either side of the ratio — the silent-denominator bug the skipped-
   pass guard was written for, still live on the path where it costs most. Eleven
   such passes scored `0/0` and printed "INCONCLUSIVE, check the passes
   registry", sending the reader to a registry that was fine.
4. **The report filename carried less than what identified it, for the third
   time.** `45211c9` put the judge in the name; the dual-grader work put the whole
   judge *list* in it; the pass **scope** was still missing. A driver sweeping
   passes one at a time therefore wrote all twelve reports to one path, each
   truncating the last, and the surviving artifact was 933 bytes describing the
   final pass while named as though it covered the gauntlet.

The rule worth keeping out of it is narrower than "exit nonzero on failure":
**reviews-on-disk and no-reviews are different exit codes.** A missing review is
fifteen minutes of a model's time and the reason to stop a sweep. A review that
exists but could not be *graded* is a judge outage — the expensive artifact is
safe and one cheap re-grade fixes it. My first version collapsed them, and the
test I had just written asserted the wrong one: it pinned `exit 4` on a fixture
where the review existed and only the second judge failed. Following that exit
code, a grader blip at hour two of a seven-hour sweep would have thrown away the
remaining five hours of review production to save a minute of judge calls. Now 4
means stop and 5 means re-grade, do not re-review.

### The re-run found a third one the same day

The sweep this section was written for was re-launched, and it stopped again at
**26 of 30 reviews**. The cause, verbatim from the `.failed` artifact:

    You've hit your session limit · resets 7:10pm (America/New_York)

It reset at 19:10, four minutes after the abort. The new machinery worked exactly
as intended — the driver counted artifacts, printed `26 / 30`, and named the
passes that were short, where the day before it had written COMPLETED over 3 of
30. But the *verdict* it wrote was wrong in a way that matters:

    ## Verdict: NOTHING MEASURED
    It is a failed measurement, and a failed measurement is not a result.
    Fix the cause and re-run.

There was nothing to fix. The cause was a wall clock that had already cleared
itself before an operator could read the sentence. Neither `rate_limited()` nor
`quota_exhausted()` matched the string, so the run also failed with **zero
retries** — and the *same corpus* held `You've hit your weekly limit · resets
5am`, unmatched for the same reason.

Filing a usage window under either existing bucket prescribes a wrong action, not
merely an imprecise label. As a rate limit it earns three retries over ~7 minutes,
which a reset hours away outlasts — and then every remaining pass retries and
fails, the exact burn `quota_exhausted()` was written to end. As a budget it drops
the agent for the whole sweep and reports a failed measurement, discarding a
candidate that would have worked fine twenty minutes later. So it gets the third
action and the third code:

| code | means | a driver should |
|---|---|---|
| 2 | usage error | fix the invocation |
| 3 | credential refusal | fix the key |
| 4 | no usable review | **stop**, find the defect |
| 5 | reviews exist, none gradeable | **keep going**, queue a re-grade |
| 6 | provider usage window closed | **wait for the reset, then re-invoke** |

6 is the weakest of the three failures on purpose: everything already on disk is
reused on the next invocation, which is why resuming cost four reviews instead of
thirty.

Two rules came out of it, both about method rather than code:

**Enumerate the refusals before writing the matcher.** All three gaps —
copilot's monthly quota, the session limit, the weekly limit — were written from
imagined provider phrasings while the real strings sat in
`~/.local/state/cadre/*/*.failed`. One `sort | uniq -c` over that directory found
the second gap before it ever cost a sweep, and turned up two more things worth
knowing: `Argument list too long` had been killing kimi and grok runs at ARG_MAX
on ~180KB prompts, which can only have *understated* those candidates on the
largest-diff passes, and a `maxSessionTurns` ceiling was failing runs
indistinguishably from a model that gave up.

**The discriminator was not the period word.** That was the rule the previous fix
established, and this corpus breaks it: `monthly spend limit` is a longer period
than `weekly limit` and the opposite kind of refusal. What separates them is that
one says *when it lifts* and the other says *where to pay*. A limit that states a
reset is waitable; a limit that states a billing URL is not.

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

1. ~~Build the dual-grader gate.~~ **Done.** `CADRE_JUDGE` takes a pair, both
   grade every run, agreement is the grade, and a split is UNRESOLVED: it scores
   nothing and the report states a range. No tie-break, because a tie-break makes
   one grader authoritative for exactly the items where graders are least
   reliable. When the range straddles a slot threshold the verdict is
   `UNRESOLVED, not slottable` rather than a guess. A split DEFER no longer
   disqualifies but is called out, since "the gate declined to decide" must not
   read as "the candidate is clear."
2. ~~Stop the external preprint numbers carrying product weight.~~ **Done.**
   Every use now leads with evidence cadre owns and demotes the preprint to
   corroboration with its limits attached.
3. ~~Reframe the panel matrix as a hypothesis generator.~~ **Done, and it needed
   a mechanism, not just a paragraph.** The matrix took the best grade across
   runs, so "caught it twice" and "caught it once, missed it once on the same
   checkout and prompt" printed identically — which is exactly how "we staffed a
   decorrelated panel" and "one run got lucky" became indistinguishable. A
   flipped cell now prints `HIT*`, an item covered only by starred cells gets its
   own line, and METHOD says plainly that the matrix generates hypotheses rather
   than estimating decorrelation.
4. ~~Rename `primary`/`secondary`.~~ **Done.** They are now
   `SEAT: can review alone` and `SEAT: needs a second reader` — a role, not a
   rank, since the old words had readers concluding the primary was the better
   buy when the whole argument is that the lower scorer may be the better seat.
5. ~~Adapter parity.~~ **Partly done, and it turned up something worse than the
   item it was on the list for.** `codex.sh` now passes `--ignore-user-config` in
   ro mode (probed for, since builds differ), matching `claude.sh`'s
   `--strict-mcp-config`. Without it a benchmark compared one model *without*
   your MCP servers against another *with* them — a property of the machine,
   invisible in the report.

   **The unclosed half is the important half.** Probing codex for its own tool
   list — the standing rule, and the reason to probe rather than read flags —
   showed that under `-s read-only` it still holds `collaboration.spawn_agent`,
   `send_message`, `list_agents`, `wait_agent` and `web.run`. That is the same
   class of hole as claude's `advisor`, which voided a whole benchmark round: a
   candidate that can consult another model is not a peer of one that cannot.
   The sandbox does not close it, because `-s read-only` governs model-generated
   *shell commands*, not the model's tool registry — and `--disable multi_agent`,
   `--disable multi_agent_v2` and `--disable collaboration_modes` were each
   probed and each a no-op. It is now recorded loudly in the adapter notes and
   pinned by tests, because an unrecorded asymmetry is what makes a comparison
   wrong while it still looks right. **A codex seat should be read as
   possibly-assisted when compared against claude.**
6. ~~Docs corrections found by the drift audit.~~ **Done, and one of them was
   not cosmetic.** CLI-REFERENCE still documented `claude -p --allowedTools
   Read,Grep,...` — the approach the adapter abandoned, and the one its own notes
   say voided a benchmark round, because `--allowedTools` only *pre-approves* and
   denies nothing. Anyone reading the doc to build their own harness would have
   reimplemented the hole. The claude, codex and grok rows now match what the
   adapters actually run, and the block says the adapter wins when they
   disagree. Separately, "the credential check reads filenames, not contents"
   stopped being true when `.npmrc`/`.netrc`/`.pypirc`/`.dockercfg` moved to
   content gating — corrected without losing the point it was making, which is
   that a key pasted into a source file still sails through.

**Nothing is left on this list.** What remains is not cleanup: it is the two
things the review could not settle — whether decorrelation is measurable at this
sample size at all, and whether the fix-commit key selects for the bugs that
matter. Both are now stated as open in the docs rather than answered by
implication.

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
