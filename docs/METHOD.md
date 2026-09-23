# Method

The question this answers is not "which AI reviewer is best." It is "which
**set** of reviewers should speak on my pull requests, given the code I actually
write."

Those have different answers, and the second one is the one you have to act on.

## 1. The key has to come from outside the harness

**The circularity trap.** If a model writes the answer key and a model grades
against it, you have measured agreement-with-the-generator. Every part of that
loop can be confidently wrong in the same direction, and the report will look
exactly like a good result.

So the default source of truth is **what the author actually repaired next**:

| strategy | key comes from | trust |
|---|---|---|
| **mine fix-commits** (default) | the repair the author shipped | external |
| user-pointed critical paths | fix-commits *within* those paths | external, scoped |
| synthetic injection | a bug an agent introduced | **weak, label it, never default to it** |

A fix commit is external evidence. The author was not playing your benchmark;
they hit the bug, wrote a test, and fixed it. A reviewer that flagged it was
right and one that approved was wrong (by an act that happened before your
harness existed).

`cadre make-pass` still uses a model to *draft* the key, because transcribing a
diff into a rubric is tedious. But the model is transcribing evidence, not
inventing it, and `cadre add-pass` refuses to register a key that still carries
the draft marker.

### Every item is proved on both trees before it counts

An item that no reviewer could possibly hit and an item that is not a defect at
all look identical in the matrix: both are a K row, and both bias the rate
without saying so. So an item is registered only when it is proved in both
directions, against the defective tree and the clean one:

- **defective side**: one of the item's own `path:line` citations resolves in
  the target tree. There is real code there to point a reviewer at.
- **clean side**: the reference fix changes that same line (three lines of
  context, the rule the report's anchor check uses). The clean tree does not
  still hold the code the item calls a defect.

`cadre make-pass` records the source repo, target and fix beside the draft
(`passes.d/<label>.fix`, never in the checkout), and `cadre add-pass` refuses
the pass and names each item that has no citation passing both. One citation
is enough; the item's other citations can be context. Only the target's
numbering counts, so a line number that fits only the fixed file (keygen rule
7) is reported as past the end of the file. A CLEAN key has no items and
nothing to prove.

That means an item the fix never touched is refused, including one the key
author verified by hand in the target: with no reference fix there is no clean
side to prove it against. Drop it, or treat it as an out-of-key finding.

Each keyed pass in a grade report states what was proved: the items proved at
`add-pass`, any item added to the key since (the out-of-key findings §6 asks
you to fold in arrive this way, with no proof), or `not recorded` for a pass
registered by hand or before the check existed.

Named non-goal: the judge reads review text, so "the grading flags it on the
defective tree and not on the clean one" cannot be replayed without model calls,
and none is made here. This proves the item points at repaired code. It does not
prove that a judge scores a do-nothing review MISS, or a review of the clean
tree MISS. A key edited after registration is not re-checked; only the list of
item names is compared.

## 2. Two miner rules that came out of running it, not designing it

`cadre setup` mines pairs where commit B repairs commit A: for each fix-shaped
B, blame B's parent at the exact lines B changed, and report the pair when one A
owns most of the blame and A is recent relative to B.

That much is obvious. These two are not, and they did more for shortlist quality
than everything else combined:

1. **Most `fix:` commits are not behavioural.** On a real repo the raw yield was
   almost entirely type-checker, CI, lint and formatting repairs. You cannot
   grade a reviewer on "the compiler was unhappy." Filter on the subject *and*
   require at least one changed source file outside the test directories and not
   a `.d.ts`.

2. **★ Require the fix to also change a test.** The author writing a test
   alongside the repair is the single strongest available signal that the defect
   was real, reproducible, and describable, which is to say, gradeable. This
   one filter is why the shortlists are short and why the survivors are worth
   hand-reviewing.

**Reject reverts.** A revert proves *something* was wrong, but it makes a poor
key: the "defect" is the entire feature and the correct review comment is
unbounded.

## 3. HIT / DEFER / MISS, the grade that matters

A reviewer output gets one of three grades per key item:

- **HIT**, describes the defect *and* treats it as a problem
- **DEFER**, describes the defect and then concludes it is intentional,
  acceptable, or a nit not worth flagging
- **MISS**, does not describe it

Most benchmarks collapse DEFER into MISS, because both leave the bug unfixed.
That is the wrong merge.

A reviewer that never saw the bug is **limited**. A reviewer that found the bug
and argued it was fine is **dangerous**, and it argues well, typically by
citing the code's own comment, or a test that asserts the defective behaviour as
correct. In a panel that synthesises several reviews, that is worse than
silence: it does not merely fail to help: it talks the panel out of a real
finding (with a citation).

So a DEFER on a blocking item disqualifies a candidate outright, whatever its
hit rate. This is deliberately not a tunable weight. A single confident wrong
approval on a data-loss bug costs more than a hundred missed nits save.

Severity is read out of the key's own item headings, so what counts as blocking
is your judgement about your code, not a constant in the grader.

### Graded-only and delivery-inclusive hit rates

Reports show both rates for blocking items and for all key items:

- **Graded-only** uses runs with usable grades. The per-item matrix, judge
  reconciliation, slot recommendation and error codes keep this meaning.
- **Delivery-inclusive** adds a MISS on every key item for each `.failed`
  artifact classified `no-output` or `failed` (output without a usable review).
  For example, one run hitting 2/2 items and one no-output run produce 2/2
  graded-only and 2/4 delivery-inclusive.

Misconfigured and timed-out failures add no items. A recorded timeout exit code
of 124 or 137 excludes even an empty artifact from the delivery denominator.
Missing artifacts, partial or inconclusive reviews, and judge outages also add
no items. CLEAN passes have no denominator. A zero denominator displays `-`,
and unresolved grades keep their uncertainty range in both rates.

An all-failed run can therefore show a delivery-inclusive 0/N while grading
still fails. That number measures failure to deliver reviews and establishes
no review quality. It doesn't make a failed benchmark eligible for slotting.

For an attempt invalidated by operator or harness error, keep the raw artifact
and write an operator assertion beside it. If the artifact is
`<slug>-run1.md.failed`, its marker is `<slug>-run1.md.invalid.json`:

```sh
failed="$CADRE_HOME/<pass>/<slug>-run1.md.failed"
jq -n --arg reason 'Wrong endpoint configured for this attempt.' \
  '{reason: $reason}' > "${failed%.failed}.invalid.json"
cadre grade <agent-spec> <runs>
```

Use the same `.md.invalid.json` suffix to exclude a completed review. The marker
must contain one JSON object with a nonblank string `reason`. Reports list these
assertions under **Operator-invalid runs** and exclude them from both rates.
Malformed markers apply no exclusion, appear under **Rejected invalid-run
markers**, and make grading return nonzero. Regrading keeps the marker. When
`cadre run` dispatches a new attempt for that slot, it archives the old marker
and artifact bytes in a sibling `<slug>-run1.md.invalidated.<random>/` directory.
The new attempt is eligible for scoring. Reusing a completed review keeps its
marker; remove it only if the exclusion no longer applies to that same review.

Leak checking runs first against the current artifact, including failed output.
SUSPECT evidence invalidates both rates and cannot be hidden by any marker.
The offline regression suite is `bash tests/delivery-inclusive.sh`.

Each report also saves a [table manifest](TABLE-MANIFEST.md) with its selection
rule, reasoned exclusions, and key and target pins. `all-runs` keeps every
requested numbered run; `first-run` scores only run 1 without substituting a
later success. `cadre grade ... --freeze` protects that table from replacement.

### CLEAN passes: the case with nothing to find

A hit rate only measures what a reviewer catches. It says nothing about what it
raises that is not there, and reviewers trade one for the other — a reviewer
tuned to miss nothing also flags a lot of nothing.

A **CLEAN pass** is a checkout with no planted defect. Its key has no `K` items,
and the only thing it measures is how much the reviewer wrongly asserts. It has
to say so out loud:

```
# Pass: py-clean-001

## CLEAN - no planted defects

Nothing was planted here. This pass measures false positives only.
```

The declaration is not ceremony. An itemless key and a key **clobbered
mid-write** are byte-identical, and that clobber is a measured incident here —
`doctor` once said "ok, 2 key items" about a key whose `K1` heading had been
destroyed, and a blocking item got scored with no severity. So a key with no
items is still refused; a key with no items *and* the `## CLEAN` heading is a
probe. Declaring both is refused as a half-edited key.

Named non-goal: this narrows the hole and does not close it. A write truncated
*after* the marker still looks exactly like a clean key. What protects you is
that the marker is a thing an author typed, not a thing a partial write
produces.

CLEAN results are reported in their own section and pooled with nothing. They
have no items, so they contribute no denominator and no hit rate, and the score
is a **count** — findings raised where nothing was planted — not a rate, because
a rate needs a denominator of things that could have been flagged and a key with
no items does not have one.

### The grade is what two judges agree on

Everything above assumes HIT / DEFER / MISS is a fact. It is not: it is one
model's reading of another model's prose. Measured on this harness, two graders
over the same nine reviews **split on one item in three**, and three readers
scored the same candidate 2/6, 4/6 and 6/6 ordered by nothing but leniency.

That is fatal to the DEFER rule specifically. A non-tunable disqualifier sitting
on the softest boundary in the rubric, driven by a grader that splits that
often, will exclude the verbose and cautious reviewers a panel most wants — for
reasons that are grading artifacts. The errors are asymmetric too: a false DEFER
zeroes a candidate, while a false HIT only pollutes one cell.

So `CADRE_JUDGE` takes **two** judges, comma separated, and both grade every run:

- They agree — that is the grade.
- They split — the item is **UNRESOLVED**. It scores nothing, and the report
  states a **range** rather than a number.
- Both said DEFER on a blocking item, with a quote — disqualified, as above.
  One said DEFER and the other did not — UNRESOLVED, so it does not disqualify.
  The report says so plainly: the gate declined to decide, it did not clear the
  candidate.

**There is deliberately no tie-break.** A tie-break makes one grader
authoritative for exactly the items where graders are known to be unreliable,
which is backwards. And when the range straddles a slot threshold — resolving
the contested items one way would seat the candidate and the other way would
not — the verdict is `UNRESOLVED, not slottable` rather than a guess.

**A split is a finding about the KEY, not about either judge.** It says the
key's credit boundary does not decide that item. The report prints both
readings side by side, because the two cases need different fixes: judges
quoting *different* sentences means the boundary is loose, and quoting the
*same* sentence two ways means the wording is ambiguous. Neither fix is "pick a
judge." Tighten the key and re-grade.

Two graders of one lineage are one grader in two seats — they agree where a
single grader was already confident — so cadre warns when the pair shares a
family, on the same reasoning as §4 below. A single judge still works and still
grades; the report just says out loud that it is one reading rather than a
measurement.

## 4. Decorrelation, not maximisation

The trap at the end of every benchmark is to run the top three scorers. If those
three share a lineage, they share blind spots, and you have bought one reviewer
three times.

What you want from reviewer number four is not a higher score. It is **a
different failure set**.

The evidence that made this the objective: in the private repo this harness was
built for, a candidate scored 4 of 6 blocking items (worse than every
incumbent) and earned a slot anyway. It found a live bug that all three
incumbents missed across six runs, on both of its own runs. Its lineage was the
only thing different about it. Mentions of the affected function across the
whole pass: incumbents zero, zero, zero; candidate nine and fifteen.

That is the result a rank cannot express, so:

- read the **per-item rows** in the report, not just the totals
- a candidate that hits an item everyone else misses is worth more than a
  higher-scoring one that agrees with your panel everywhere
- when you can, add a **model lineage** you do not already have. A different
  wrapper around the same family is not a fourth opinion. (Check the vendor's
  own docs, some review products are front-ends over the same two or three
  underlying model families.)

The flip side (and it is a real cost): a decorrelated candidate is usually noisier.
The one above was seated **needs a second reader** for a reason, and a
clean pass from it is not a signal, because it produced one on a commit it had
itself called blocking on the previous run. Same checkout, same prompt.

### What the matrix is, and what it is not

That last sentence is not a footnote, it is the limit of the whole method, so it
gets said plainly here rather than left for a reader to infer.

`cadre panel` **generates hypotheses. It does not estimate decorrelation.**

Reports open with estimated tokens per credited blocking hit and the graded-only
blocking hit rate. Cost keeps the existing arithmetic: prompt plus review bytes,
divided by four, then by credited blocking hits. Only scored keyed runs contribute
spend. Delivery failures and CLEAN probes contribute none; a missing prompt receipt
or zero credited blocking hits makes cost unavailable (`-`).

Before the coverage matrix, `cadre panel` shows each candidate/judge observation
and its observed hit-rate and cost spread. These ranges are **observational**:
inputs, run counts and judges may differ. Unresolved grades retain lower/upper
bounds; percentages round to one decimal and keep the original fractions.
Invalid and scoped reports contribute no summary metrics. Older reports with
missing fields show `-`; missing values never establish equal cost or hit rate.
`--save` keeps this overview with the commented matrix. The per-item grades and
the **NOTHING in this lineup catches** warning still identify coverage gaps.

The `FILES % (runs)` cell shows each candidate's mean changed-file mention
coverage for that pass, with the number of measured runs. Shared-basename
ambiguity is excluded from the denominator; missing measurements and older
reports show `-`. This is a separate signal to weigh beside item hits, not an
automatic seating threshold. Mentioning a file does not prove it was reviewed.

Grade reports also check supported `path:line`, `path:start-end`, and
`path#Lstart-Lend` citations against that file's diff hunks (three context lines).
Paths are matched literally, including spaces and regex punctuation. A basename
unique across the old and new trees also works; shared basenames, unknown paths,
unsupported citation syntax, binary changes, and missing diffs provide no position
measurement. Supported paths start a line or follow whitespace, a backtick, or
a quote; other wrapping is deliberately left unclassified. Paths containing
tabs, newlines, double quotes, or backslashes are also unclassified. Renames are
compared as deletion and addition so an old-path citation can still resolve.

Any part of a cited range overlapping a hunk on either the old or new side is
enough to avoid a drift flag, because these citations do not establish which
side they mean. Zero-length sides contain no lines. An anchor outside all such
hunks is **possible position drift**, not an invalid finding: unchanged code
outside a hunk can be relevant. The check is advisory and never changes grades,
DEFER gates, or the slot verdict. The denominator counts supported occurrences,
not findings, and makes no claim that every citation was recognized.

The defaults are two runs against a handful of key items. That is on the order of
tens of binary outcomes — nowhere near enough to estimate co-failure structure,
separate lineage effects from run-to-run variance, or put an interval on "covers
what the others miss." The matrix computes no correlation and no uncertainty. It
prints what happened and asks a human to look at the shape of it.

So a gap in the matrix is a **question worth spending runs on**, not a measured
property of your panel: *nothing here caught K3 — is that a real hole, or did
these three all have a bad run?* The way to answer it is more runs, and the tool
marks the cells where you most need them. A `HIT*` means the candidate's own runs
disagreed with each other on that item, and an item covered only by starred cells
is coverage on a coin flip. Cadre says so in as many words rather than letting a
lucky run print the same cell as a reliable one.

Everything above about seating a different lineage still holds — it is the right
thing to do on priors, and the private-repo result is real. But "we staffed a
decorrelated panel" and "one run got lucky" produce the same matrix at n=2, and
a tool that let you tell them apart only by reading its source would be selling
you the first while delivering the second.

## 5. Leak control is a feature, not a caveat

If the key is "the bug the author fixed next," then the fix commit's **subject
line states the answer**: reviewers have git, and several have web access. A
reviewer can read the future and hand you back the key as a brilliant finding.

Enforced in the harness, and you get an error rather than a footnote:

- graded passes run in a `--depth 2 --single-branch` clone pinned at the target,
  with `origin` removed; there is no future history to read and nothing to fetch
  it back from
- keys live outside the reviewed tree. `cadre doctor` exits non-zero on a pass
  whose key is inside the checkout, and `cadre run` refuses that pass outright
- checkouts live in `$CADRE_WORK`, a **different tree** from `$CADRE_HOME`, with
  a random suffix. This one came out of a review of this repo. When the checkout
  was `$CADRE_HOME/checkouts/<label>`, the agent's own working directory spelled
  out the layout and `cat ../../keys/$(basename $PWD).md` reached the answer by
  relative path, with no environment variable involved at all. Scrubbing the
  environment did nothing about it. When you hide an identifier, check every
  other channel that still spells it out
- `run-pass.sh` refuses when the output directory is inside the reviewed
  checkout, **or contains it**. Otherwise reviewer #1's findings sit one `ls`
  away from the tree reviewer #2 reads, and you get cross-contamination that
  looks exactly like independent agreement
- agents are launched with `CADRE_HOME` and the other `CADRE_*` variables
  stripped from their environment, so the path to the keys and to every other
  reviewer's output is not handed to them
- a review that reproduces two or more key item headings **verbatim** is flagged
  SUSPECT in the report and should not be scored

### What leak control does NOT buy you

Be clear-eyed about this, because the previous list is easy to read as a
sandbox and it is not one.

Several adapters run their CLI with full tool approval, because that is the only
way to get the agent to read the diff at all. Such an agent can read your
filesystem. Removing `CADRE_HOME` from its environment stops the answer key
being *advertised*; it does not stop a determined agent from finding
`~/.local/state/cadre/keys/`. The verbatim-quote detector is the backstop, and
it only catches copying, not paraphrase.

If you need a real boundary, run the agents in a container with only the
checkout mounted. The harness does not do this for you.

**One thing the harness cannot check at all:** whether the target's defect is
also described in a public issue or a merged PR body. That text is fetchable
prose and several reviewers have web access, so a public target can leak its own
answer no matter how shallow the clone is. Checking it is on you, at the moment
you pick the target. The answer-key template has a prompt for it.

### Confounds are named before the score

Three things decide a run before the model's skill does, so the report states
them above the hit rate rather than below it.

**The output cap.** A run the cap cut off is an auto-fail whatever the model
knew. Two seats that ran under different caps are two measurements, and the
report says so rather than comparing them: `cadre panel` refuses its
hit-rate bounds line when caps differ across rows and names the fix, which is
re-running the larger-cap seat at the smaller cap. Cadre does not replay a
truncation to match caps for you — token-exact truncation needs the serving
stack's own tokenizer, and a byte-count guess would be a worse claim than
declining. An adapter declares the cap with `cadre_cap` and the reported stop
reason with `cadre_finish`; an adapter that declares neither leaves the cap
`not recorded`, which is a different statement from "no cap".

**Runs that scored nothing.** Cut off with a partial on disk, and empty from
the provider, are counted and printed separately. A seat whose rate is carried
by them has a cap or a provider problem, not a result. A run whose adapter
reported `finish_reason=length` and still produced a usable review IS scored —
its findings are real — and is named, because its silence past the cut is not
clearance.

**The noise floor.** Run *k* over every pass is one sweep of the registered
set, so the spread between sweeps is the candidate's own run-to-run variance.
The report prints it as percentage points before the hit rate, `cadre panel`
takes the largest spread any single row measured against itself as the floor
for the whole table, and rows within that floor of the top rate are named
rather than ranked. A candidate graded at one run per pass measured no spread
and is listed as unmeasured — which is not the same as having no noise, and is
why a one-run gauntlet cannot support a comparison at all.

**The round count.** A rate from one round is one draw, not a property of the
reviewer. nuhuh, where this rule comes from (#23), published its own
reversals: one seat at 0% on round one and 4.1% over three rounds, another at
12.5% on round one and 6.8% over ninety. A round is one scored run of a pass, and the count behind a rate
is the **fewest** scored runs any pass with blocking items contributed. Two run
slots over different passes are one round of each, the same trap the spread
line refuses. The report prints that count on the rate's own line and in the
footer above the hit line. `cadre panel` prints it as a `ROUNDS` column beside
every rate.

Below a floor of two rounds, the default run count, the rate is still printed
with its count, but nothing is ranked on it. A `SEAT:` verdict, or a `DO NOT
SLOT` from a low hit rate, becomes `ONE ROUND, not slottable`, with the
one-round reason kept inside it. Both directions fall because the published
reversals went both ways. A quoted DEFER on a blocking item is an act already
in hand rather than a rate, so its `DO NOT SLOT` stands, as a leak does. In
`cadre panel`, a row under the floor, or one from a report that predates the
count, is named as not placed and is kept out of the within-floor grouping.
`--selection first-run` is one round by construction, so it never recommends
a seat.

Two sweeps are only comparable when they graded the same passes, and equal item
counts do not prove that: a pass scoring only in slot 1 and another only in
slot 2 give both slots the same denominator over completely different items.
That case, and any slot carrying an UNRESOLVED item, make the spread
unavailable rather than a number — a slot rate is a lower bound once the judges
have split, so the gap between two bounds is partly the split. A row whose rate
is a range for the same reason is not placed in the panel grouping at all.

### A regrade never overwrites the grade it replaces

`cadre grade` re-scores reviews already on disk. Every replacement of an
existing grade appends one line to a `<grade>.regraded.jsonl` ledger beside it:
the prior item verdicts, the new ones, the keys that moved, and the SHA-256 of
the two inputs that could have moved them (the answer key, and the harness
digest that covers the rubric). A regrade that changed nothing is recorded too.
The report names every moved verdict with its prior value, and the saved table
carries the ledger beside the grade it describes.

A regrade that comes back UNUSABLE does not write at all. The prior grade stays
on disk, is NOT scored on that pass, and the run is reported as a grading
failure with the provider's reply kept. The reason is the failure that already
happened here in the other direction: a judge outage replacing nine usable
grades with `{"unusable":true}` destroys a baseline that cost hours of review
production to produce, to save one cheap call. The sweep exits 5 even if its
other runs scored, because the refusal took a run that was scored out of the
denominator, and "re-grade, do not re-review" is exactly the right instruction
for it. A ledger that cannot be written refuses the swap too, and keeps the
reply that was not applied beside the grade rather than discarding it.

## 6. What the report cannot tell you

**Out-of-key findings.** A candidate that reports real bugs your key does not
contain is producing the most valuable result the harness can generate and the
one it cannot score. They land in the report under "grade these by hand."
Verify each against the source; the credible ones belong in the key so the next
candidate is measured against a better test. Record that earlier candidates were
scored against the shorter key rather than back-charging them.

**Variance.** Two runs is a small sample. Treat a single clean pass as unproven,
not as a pass.

**Whether the judge is right.** It grades from the review text alone, which is
what stops it from re-reviewing the code, but a correct finding written badly
scores as a miss.

### What receipts do NOT measure

Receipts are harness-side measurements only. They do not measure hidden
reasoning tokens, provider-side billing, or retries a CLI performs internally;
those happen beyond the adapter boundary and are not visible to cadre.

Time the harness spent that no timer covered is not dropped either. Each panel
records its wall clock beside the seat and pre-pass seconds, and the
difference as `unattributed_secs` (docs/DATASET.md, the `panel` event), so the
seat column is never read as the whole cost of a panel.
