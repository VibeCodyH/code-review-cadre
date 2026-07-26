---
description: Mine this repo for (target, fix) commit pairs and help build a benchmark pass
---

Run `cadre setup <repo>` on the current repo (or the path in $ARGUMENTS).

Then read the shortlist and recommend 2-3 rows worth turning into passes. Pick
for **different bug classes**, not for the highest blame share: three passes
that are all "a null check is missing" measure one skill three times.

For each recommendation, state the target commit, the fix commit, the bug class,
and the `cadre make-pass` command. Do not run `make-pass` yourself; the answer
key needs a human's eyes before it becomes a pass.

If `cadre` is not on PATH, say so and stop.
