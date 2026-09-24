# The run dataset — what it measures, and what it does not

`cadre dataset` walks every run in `$CADRE_HOME/reviews` and writes two
tab-separated files. This document is the part that matters: it says what those
numbers support and what they cannot, because the interesting failures here are
all failures of interpretation.

    cadre dataset [out-dir]     # default: $CADRE_HOME/dataset

## The headline caveat: there is no answer key in any of this

`cadre review` runs a panel against a real change. It has no ground truth. A
reviewer that returns a confident, well-formatted review of a diff it misread
lands in this dataset as `ok`, exactly like one that found the real bug.

So the ok/failed columns answer **"did this CLI deliver usable text?"** They do
not answer **"was the text any good?"** The first question is real and worth
measuring — a large fraction of the adapters in this repo exist because the
answer was no, in a way that looked like success — but it is not a quality
ranking, and a table of ok-rates presented as one would be a lie.

Scoring against ground truth is what `cadre run`, `cadre make-pass` and the
answer keys are for. **None of the runs aggregated here used them.** Any claim
about which model reviews *better* needs that path, not this file.

## slots.tsv — one row per reviewer slot

    panel  slot  family  status  bytes  secs  prompt_bytes  v  prompt_sha  adapter_sha  harness_sha  model  source

- **status** — `ok` / `degraded` / `inconclusive` / `failed` / `skipped`.
  `skipped` means the user-declared roster gate did not hold, so no prompt was
  sent; the row stays in `slots.tsv`, while `panels.tsv` excludes it from the
  seat count because it was not on the panel that reviewed.
  The other states are as `classify_run`
  decided at the time. `failed` covers a dead account, a refused call, an empty
  answer, and a crash; the artifact says which, this column does not.
  `inconclusive` is narrower and is **not** a flavour of `failed`: the run exited
  cleanly and produced text that states no finding and no verdict, so the CLI
  worked and the model did not review. Neither is scored, and the split is the
  point — `failed` is a fact about the adapter, `inconclusive` is a fact about the
  model, and only the second one belongs in a roster decision.
- **bytes** — size of the artifact on disk. **Read this with care: bigger is
  not better and is frequently worse.** Measured on one identical diff, kimi
  produced 126,030 bytes and codex 2,279. Kimi's file is mostly tool transcript
  and CLI chrome wrapped around a review of ordinary length; codex's is almost
  entirely findings. Byte count measures how much a CLI *prints*, not how much
  it *found*.
- **secs** — wall-clock, and **empty for most rows**. See `source`.
- **prompt_bytes** — size of the exact prompt dispatched to the seat, captured
  by the harness at dispatch time. It is empty for rows that predate this field
  and for reconstructed rows; cadre never guesses it from surviving files.
- **v** — the `slots.tsv` schema version that wrote the row: what these columns
  mean and which rule filled them. A row **without** it is not version 1, it is
  **unknown**, and `cadre receipts` groups on it rather than guessing. The
  distinction it protects: `secs` on a *failed* seat used to be blank and is now
  the measured seconds. Neither convention is wrong, and a total that spans both
  is a number nobody can interpret. Rows that predate the column straddle that
  change and nothing on disk can separate the halves after the fact, so they
  print as `?` and are listed on their own row.
- **prompt_sha** / **adapter_sha** / **harness_sha** — 12-hex content hashes of
  the three inputs that decide what a seat saw: the rendered prompt as
  dispatched, the adapter code that ran, and the harness files that shape a
  review (including `bin/agentcall`, which decides whether the brief arrives on
  stdin or in argv; `bin/cadre` is deliberately excluded, so a CLI edit does not
  invalidate stored comparisons). `adapter_sha` covers both copies of
  `<agent>.sh` *and* any other file in either adapter directory mentioning
  `_<agent>(` — `agentcall` sources every `*.sh` in both into one namespace, so
  a foreign file defining `run_<agent>()` is a different reviewer. `prompt_bytes` is a size — two prompts that differ but happen to be
  the same length are indistinguishable by it, and `CADRE_PROMPT_FILE` replaces
  the brief wholesale, so the input with the largest effect on a review was the
  one the record described least. All three are **EMPTY when undetermined** and
  never zeroed: a reconstructed row, a promptless adapter that received no
  shared brief, a machine with no `sha256sum`/`shasum`, or an input that could
  not be read in full. The digest of an empty read is *stable*, so a partial
  answer here would make two failed runs compare equal. This is provenance, not
  tamper-proofing — see `docs/ASSURANCE_CASE.md`.
- **model** — the model(s) that actually served the seat, as the adapter
  *reported* them (`cadre_model`; claudecr reads `modelUsage` from the CLI's
  JSON result). **EMPTY for every seat whose spec pins its model** — the spec
  already says what ran and this column is not a copy of it. It is filled only
  where the spec cannot say: `claudecr:<level>` spends its model slot on the
  effort level and inherits the CLI default, which can change mid-sweep. A seat
  listed under two models is one seat measured twice, and `cadre receipts` says
  so rather than adding the rows. Not a schema bump: `v` marks a change to what
  a column *means*, and no existing column moved.
- **source** — `recorded` (written live by `run-review.sh`, with status and
  timing measured and prompt size present on new rows) or `reconstructed`
  (rebuilt from artifacts after the fact). Reconstructed rows have **no timing
  or prompt size at all**: the per-slot scratch files were deleted when the
  panel finished, and fourteen panels ran before timing capture was fixed. Both
  fields are left EMPTY rather than zeroed, because a zero would average like a
  real measurement and drag every mean toward the floor. The four provenance
  columns follow the same rule for the same reason.

## panels.tsv — one row per panel

    panel  diff_id  seats  ok  degraded  inconclusive  failed  synthesis

**`diff_id` is the field that decides what may be compared with what.** It is
`base-tree..reviewed-tree`: two panels sharing one reviewed byte-identical
code, and their reviewers can honestly be set side by side. Two panels with
different `diff_id`s reviewed different code, and lining their reviewers up in
one table compares reviewer against *task difficulty* while looking exactly
like a head-to-head.

Most panels here have a unique `diff_id`. The one real cluster is four panels
over `2cfcd0ba..25beedef`, covering five distinct reviewers, with `codex` and
`grok` each run twice — which is the only repeatability signal in the set.

## `language` — on the run record, observational only

Every `dispatch` and `complete` event in `runs.jsonl` (panel and benchmark
paths) carries `language`: the dominant language of the change, from an
extension histogram over the files that changed between base and head in the
checkout the reviewers saw (`detect_language` in `lib/common.sh`; docs, data
and lock files are not counted). Deterministic — count desc, then name asc —
so a tie always resolves the same way. EMPTY when nothing recognisable
changed, never a guess. The panel manifest carries the same value on a
`language:` line, blank in that case.

A gauntlet report prints each pass's language and, **only when the graded
passes span at least two recorded languages**, a `By language (observational)`
table of blocking hits per language. Read the heading literally. Language and
repo are confounded — nothing matched those passes for difficulty, and a row
built from one repo measures that repo — so the table reflects the repos you
happened to register, not cross-language ground truth. It exists so that
per-language splits can fall out of ordinary BYO-repo use over time; it is
not a benchmark claim, and no such claim should be quoted from it.

## `panel` — the wall clock and what no timer covered

The last event a finished panel writes to its `runs.jsonl` is one `panel`
event. It sets the panel's measured wall clock against the parts that have
their own timers and records the difference, so the totals always reconcile:

    wall_secs = prerun_secs + seat_secs + unattributed_secs

- **wall_secs** — measured on its own, from the start of `run-review.sh` to
  just before the Receipts table. The table, the scratch cleanup and any
  synthesis run after it and are **not timed**; the report says so.
- **prerun_secs** — the `--prerun` command. `null` when there was none: it was
  never timed, which is different from taking zero seconds.
- **seat_secs** — the sum of the `secs` of this panel's `complete` rows,
  exactly the Receipts "panel total". `null` when no seat was timed. A seat
  with no timer (not installed, skipped) adds nothing here, and
  `untimed_seats` counts those. With `jobs` = 1 whatever they took is inside
  the residual; with `jobs` > 1 it may have run alongside a timed seat and
  appear nowhere.
- **unattributed_secs** — the residual, signed and never clamped. With
  `jobs` = 1 every timer is a disjoint slice of the wall clock, so it is
  never negative: a negative value means a second was counted twice, and the
  report and stderr both say so. With `jobs` > 1 seat timers overlap by design,
  so the residual is a NET balance: overlap pulls it down, harness and untimed
  work push it up, and neither can be read off it alone. A negative value
  says overlap outweighed the rest, not how much overlap there was.
- **est_tokens** / **unattributed_tokens** — the Receipts token estimate, and
  its residual as `null`. There is no measured token total to reconcile
  against (the estimate is a sum of per-seat estimates, and a provider's bill
  is invisible from here), so the residual is unmeasured, never 0.

It is a new event name, so every reader that selects `dispatch` or `complete`
(slots.tsv, `cadre receipts`, `cadre seats`) is untouched. A panel killed
before its report has no `panel` event, the same way a seat cut off mid-flight
has a `dispatch` and no `complete`. The evidence export carries it whole as
`shared/panel.jsonl`. Benchmark passes report no total beside their per-run
seconds and write no such event.

## Known blind spots

1. **No ground truth.** Above. This is the big one.
2. **Timing is missing for the older two-thirds.** Not reconstructible.
3. **n is small and unbalanced.** Some reviewers appear once. One `ok` is not
   a reliability rate, and nothing here should be quoted as a percentage
   without its denominator.
4. **The panels are not independent samples.** They ran in sequence on a repo
   that was being actively fixed between them, partly *because* of what the
   previous panel found. Later diffs are not harder or easier in a controlled
   way — they are just different.
5. **Every run is one repo**, this one: shell, ~200 tests, one author's style.
   Nothing here generalises to other languages or codebases.
6. **Failures are over-weighted toward accounts, not models.** Several `failed`
   rows are exhausted free-tier quota, which says nothing about the model and
   everything about the account it was billed to.
7. **The synthesis column is not a quality signal either.** `ok` means a
   merge was produced and classified usable, not that the merge was correct.
