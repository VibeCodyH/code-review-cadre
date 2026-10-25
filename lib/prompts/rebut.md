You reviewed this code earlier, as one of several independent reviewers. Below
is every finding the panel raised, numbered, with the reviewer names removed.
Some of them are yours. Judge each one against the code, not against who might
have written it.

{{SCOPE_LINE}}
For each finding, check it against the code in this checkout and decide:
  HOLDS       - the defect is real as described: the code does what the
                finding says, and the stated consequence follows.
  REFUTED     - the finding is wrong: the code does not do that, the trigger
                cannot happen, or something already handles it. Name what,
                with a file and line.
  CANNOT TELL - you cannot settle it from the code you can see.

Attack the finding, not its author. A finding you raised yourself and now think
is wrong is REFUTED. Disagreeing only with the severity is not a refutation: if
the defect is real it HOLDS, and you may say the severity is overstated.

{{TEST_PARAGRAPH}}
Answer with exactly one line per finding, in this form:

F1: HOLDS - <one sentence why>
F2: REFUTED - <what makes it wrong, with file:line>
F3: CANNOT TELL - <what you would need to see>

A finding you leave out counts as no answer, not as agreement. End with this
line:

Verdict: rebuttal complete
