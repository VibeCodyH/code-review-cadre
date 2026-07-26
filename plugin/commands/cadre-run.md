---
description: Put a candidate reviewer through the gauntlet and report its slot
---

Run `cadre run $ARGUMENTS` (agent spec, then optional run count).

Then summarise the report:

- the slot and the one-line reason
- per-item rows where this candidate **disagrees** with the incumbents: a
  candidate that hits an item everyone else misses matters more than its total
- any out-of-key findings, flagged as unverified

Do not tell the user to slot it. `cadre` recommends; the roster is theirs.
