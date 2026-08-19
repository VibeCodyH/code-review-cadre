# lib/engine — the review engine

Everything here answers one question: **what did this panel say about this tree?**

It ends at `findings.json`. The other half of cadre — `grade`, the judges,
`aggregate`, the pass runner — answers a different question, *how good was each
reviewer*, and it is a **consumer of `findings.json`** and nothing else. That is
the seam, and `tests/engine-seam.sh` is what holds it.

## The two layers, and which one gets graded

```
claims[]     verbatim. What each reviewer actually asserted, pulled out of that
             reviewer's own file by grep. No model in the path.
             >>> this is the layer the benchmark grades <<<

findings[]   the merged, human-facing view: what the synthesizer said after
             reading the whole panel. Model-produced, so never graded.
```

Everything downstream of the reviewers — the synthesizer, an optional `verify`
overlay, `settle` matching against your ledger — writes `findings[]`. None of
them may touch `claims[]`.

The reason is worth stating once. A synthesizer paraphrases. A verify pass can be
wrong about the code. A settle pass encodes one human's dismissals. If any of the
three could reach `claims[]`, a reviewer's score would become a function of a
downstream model's quality instead of a function of what the reviewer wrote — and
it would do that silently, because the score would still look like a score.

## Why claims are extracted from disk, never from the merge

The merge is lossy on purpose:

- an over-long review is cut to fit the synthesizer's budget (`CADRE_SYNTH_MAX`),
  so its later findings are not in the merge at all;
- a reviewer that returned nothing is kept out of every denominator, which is
  correct for a merge and would be a false clearance in a score.

So `engine_claims` re-reads each reviewer's file in full. A projection built by
parsing `synthesis.md` would mark a reviewer as having missed a bug it reported.

## Contract notes

- `target.base_tree` / `target.reviewed_tree` are **content addresses** and are
  required. Commit shas are not durable here: the snapshot is an unreferenced
  stash commit that the next `git gc` reclaims, and on a `--full` or dirty tree
  there is no revision at all.
- `severity_stated` on a claim is **verbatim**, never mapped onto
  `blocking|should-fix|nit`. Mapping is an interpretation and belongs on
  `findings[]`. A consumer can normalize; it cannot un-normalize.
- Agreement is **copied from the synthesizer's `[n/d]` tag, never recomputed**.
  Recomputing a denominator from a count of files restores the bug the merge
  already fixed: an absent reviewer read as a dissent. No tag means `null`.
- `findings.json` is a **lossy view**. `runs.jsonl` and `slots.tsv` remain the
  durable per-seat record, and `synthesis.md` remains the thing a human reads.
- `panel[]` carries **every roster member**, in one of four states, and the
  distinctions matter more than they look:

  | state | meaning |
  | --- | --- |
  | `ok` | returned a complete review |
  | `degraded` | stopped partway; kept, and excluded from denominators it did not raise |
  | `absent` | asked, never answered — its silence proves **nothing** |
  | `skipped` | never asked, on purpose; `skipped_gate`/`skipped_reason` say why |

  `absent` and `skipped` are deliberately not merged. Collapsing them turns a
  config decision into a reviewer failure, and dropping either makes the panel
  read cleaner than it was.
- The extraction grep runs with `-a`. One NUL byte in a review otherwise makes
  grep call the file binary and suppress every line **on stderr**, which silently
  empties that reviewer's claims — a reviewer that reported a blocking bug
  reading as one that found nothing.
- It is written on **every** path, including the ones where no merge happened.
  A missing `findings.json` must never be read as a clean panel.

## Files

| file | what it owns |
| --- | --- |
| `synthesize.sh` | the merge (`cmd_synthesize`), the claims projection, `findings.json` |
| `settle.sh` | the human-written ledger, and splitting a review into NEW vs settled |
