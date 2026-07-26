# Answer key. `<target-sha>` (<one line: what the target commit did>)

**Why this target.** Every key item below is a bug **the author repaired in a
later commit** (`<fix-sha>`). Nothing here is an opinion about what counts as a
defect: the repair shipped, so a reviewer that flags it was right and a reviewer
that approved was wrong (by the author's own subsequent action).

**Bug class.** <One line. Track this across your passes: three passes that are
all "a null check is missing" measure one skill three times. Vary the class
deliberately: merge/precedence, truncation, validation policy, lifecycle and
ordering, data already in the database before the change.>

## Leak control

The fix commit's subject line states the answer, and reviewers have git: some
have web access too. This pass runs in a `--depth 2 --single-branch` checkout
pinned at the target. Total history visible to a reviewer:

```
<target-sha> <target subject>
<parent-sha> <parent subject>
```

No `.env*` or credential files present (checked before any agent ran: several
reviewers run with tool auto-approval). Push URL removed.

If the defect is also described in a public issue or a merged PR body, say so
here and consider rejecting the target: that text is fetchable prose and a
reviewer with web access can hand the key back as a finding.

---

## The key

State for each item whether you verified it by EXECUTION or by INSPECTION.
Inspection-only items are weaker evidence, and saying which is which is the
difference between a benchmark and a vibe.

### K1 - BLOCKING - <one-line statement of the defect>

`<file>:<lines>`. What is wrong, and why the code reads as correct at a glance.
The concrete input or pre-existing state that triggers it.

Verified by execution at `<target-sha>`:

```
input   <...>
output  <...>
```

**Author's fix:** `<fix-sha>` <what it changed>.

### K2 - SHOULD-FIX - <one-line statement of the defect>

`<file>:<lines>`. By inspection: the call path is <traced>, but this was never
executed.

**Author's fix:** `<fix-sha>` <what it changed>.

### K3 - NIT - <one-line statement of the defect>

Not repaired by the author, so this is weaker evidence (scored, but it should
not carry the pass).

## Scoring rules

- Say, per item, what a review must CLAIM to earn the HIT. "Notes over 500 chars
  are rejected" restates the diff; "rows written before the cap existed can no
  longer be saved" is the finding. Only the second one is a hit.
- Findings outside this key are **not** automatically false positives. Verify
  them against the source. If one holds, fold it into the key, and record that
  earlier candidates were scored against the shorter key rather than
  back-charging them.
- A confident "no defects found" on a commit the author repaired the next day is
  a scored miss, not a neutral result.
- A DEFER on a blocking item disqualifies a candidate on its own, whatever the
  hit rate. See docs/METHOD.md.
