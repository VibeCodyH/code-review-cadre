You are drafting an ANSWER KEY for a code-review benchmark pass. A human will
read and correct this draft before it becomes a pass, so flag what you are
unsure of rather than smoothing it over.

You are given two commits from the same repository:

  TARGET - the commit a reviewer will be asked to review. Pretend the reviewer
           knows nothing after it.
  FIX    - a later commit that repairs a defect the TARGET introduced. This is
           the evidence. The author shipped the repair, so a reviewer who flags
           the defect was right and one who approved was wrong. That is the
           author's own subsequent action, not your opinion.

Write the key as Markdown, in this shape:

  # Answer key for <target sha> (<one-line description of the target>)

  ## The key

  ### K1 - BLOCKING|SHOULD-FIX|NIT - <one-line statement of the defect>

  <file:line in the TARGET>. What is wrong, what breaks, and the concrete
  input or state that triggers it. Then how you verified it: "executed" with
  the command and its output, or "by inspection" with the call path traced.

  **Author's fix:** <what FIX changed, and where>.

Rules that matter more than completeness:

1. ONE defect per K-item, numbered K1, K2, ... Severity goes in the heading in
   those exact words: the grader parses the heading, so a key item with no
   severity word is scored as if it does not matter.
2. Only include a defect the FIX commit actually repairs, or one you verified
   yourself in the TARGET. Do not invent items to round out the list.
3. Say explicitly which items you EXECUTED and which are by inspection.
   Inspection-only items are weaker evidence and must be labelled as such.
4. Add a "## Scoring rules" section stating, for each item, what a review must
   claim to earn the HIT. Restating what the diff does is never a HIT.
5. If the FIX is a revert, or the defect is a type error, lint, or CI repair,
   say so and recommend rejecting this pair. Those are not gradeable review
   targets.
6. ★ A `fix(...)` subject line is NOT evidence of a defect. Diff the TARGET
   against its OWN contemporaries -- the sibling call sites, the comment above
   it, the type it returns, the schema it writes to -- and ask whether it breaks
   a promise the code already made. If the TARGET did the same thing every
   sibling did at that time, the FIX changed the requirements and there was no
   defect to find. Recommend rejecting that pair. Measured: a pair was accepted
   on its subject line alone, and the "defect" turned out to be the identical
   formula every contemporary used.
7. Line numbers must be from the TARGET commit. Line numbers from current main
   point a reviewer at the wrong code, and the grader cannot tell.
8. Every scoring rule must be falsifiable from the review text alone. The grader
   sees only this key and the review, never the repository.
9. ★★ A scoring rule must NAME the specific mechanism, and must say whether
   reaching the same conclusion through a DIFFERENT mechanism earns credit.
   Write both halves explicitly:

     K1 is a HIT only if the review claims <route> writes without consulting
     <the named gate, e.g. resolveOloPushMode> and requires that gate be honored.
     ★ A review that argues the same write is ungated by citing a DIFFERENT
     guard elsewhere (a sibling's own dry-run check, a wrapper it bypasses)
     DOES / DOES NOT earn credit. <pick one, in the key, before any run>

   Measured, and this is the most expensive failure this file has produced: two
   capable graders ran over the same nine reviews and split on ONE ITEM IN
   THREE. Every split turned on that one unwritten question. The stored grades
   proved it -- one grader's `quotes` credited the item on a sentence about a
   sibling function's guard, while naming a different sentence for the other
   item than a human reader had. They were not disagreeing about a verdict,
   they were reading different sentences, and the rule never told them which
   one counted.

   ★ Swapping graders CANNOT fix this. An underspecified rule produces a
   defensible split at any judge quality, and the resulting scores span the
   scale -- one candidate was graded 2/6, 4/6, and 6/6 by three readers,
   ordered by nothing but leniency. Ambiguity here costs more than a weak
   grader, because it is invisible: every one of those grades looked healthy.
10. Prefer a rule that names an ARTIFACT the review must mention -- an env var,
   a function, a column -- over one that describes an idea the review must
   convey. "Names OLO_RECON_DRY_RUN or resolveOloPushMode" is checkable by two
   readers the same way. "Understands the write is ungated" is not.
