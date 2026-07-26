---
description: Run the staffed roster against the current change and merge the reviews
---

Run `cadre review $ARGUMENTS` in the current repo.

With no arguments it reviews the working tree against the merge-base with the
default branch, using the roster in `$CADRE_HOME/roster`. Useful flags:
`--base <rev>`, `--roster a,b,c`, `--jobs N`, `--synth <agent-spec>`.

If it reports no roster, run `cadre panel --save` first and tell the user to
uncomment the lineup they want. Do not pick the lineup for them: the tool
deliberately writes every candidate commented out.

When it finishes, read `report.md` in the output directory and summarise:

1. Findings **more than one** reviewer raised. These are the ones to act on first.
2. Findings **exactly one** reviewer raised, each attributed. Do not bury these.
   A defect one reviewer caught alone is the reason the panel exists.
3. Any reviewer that **FAILED**, by name. A failed reviewer is not a clean
   review, and a panel of three where one died is a panel of two.

If `synthesis.md` exists, it is model-produced and unverified. Use it as an
index into the individual reviews, not as a replacement for reading them.

Verify findings against the source before repeating them to the user as fact.
