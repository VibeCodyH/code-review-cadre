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

    panel  slot  family  status  bytes  secs  prompt_bytes  v  prompt_sha  adapter_sha  harness_sha  source

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
  dispatched, the adapter file(s) that ran (both the shipped one and a user
  override, since `agentcall` sources both), and the harness files that shape a
  review. `prompt_bytes` is a size — two prompts that differ but happen to be
  the same length are indistinguishable by it, and `CADRE_PROMPT_FILE` replaces
  the brief wholesale, so the input with the largest effect on a review was the
  one the record described least. All three are **EMPTY when undetermined** and
  never zeroed: a reconstructed row, a promptless adapter that received no
  shared brief, or a machine with no `sha256sum`/`shasum`. This is provenance,
  not tamper-proofing — see `docs/ASSURANCE_CASE.md`.
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
