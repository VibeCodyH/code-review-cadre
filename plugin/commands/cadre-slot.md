---
description: Compare all graded candidates and propose a panel
---

Read every `report-*.md` in `$CADRE_HOME` (default
`${XDG_STATE_HOME:-~/.local/state}/cadre`).

Build one table: rows are candidates, columns are key items, cells are
HIT/DEFER/MISS.

Then propose a panel, optimising for **complementary blind spots** rather than
top scores:

- anyone with a DEFER on a blocking item is out, whatever their hit rate
- prefer a candidate that covers items the current best misses over a
  higher-scoring one that agrees everywhere
- flag when two candidates share a model lineage: that is one opinion bought
  twice

State which items **nothing** in the lineup catches. That gap is the most useful
output here.
