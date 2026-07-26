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
The one above was slotted **secondary** for a reason (never run alone), and a
clean pass from it is not a signal, because it produced one on a commit it had
itself called blocking on the previous run. Same checkout, same prompt.

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
