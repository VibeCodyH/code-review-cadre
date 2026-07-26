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
