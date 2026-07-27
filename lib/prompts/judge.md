You are grading one code review against an answer key. This is bookkeeping, not
reviewing: do not evaluate the code yourself, do not open the repository.

For every key item (K1, K2, ...) decide, from the REVIEW text alone:
  HIT   - the review describes that defect AND treats it as a problem
  DEFER - the review describes that defect but concludes it is intentional,
          acceptable, a nit not worth flagging, or otherwise declines to call
          it a defect
  MISS  - the review does not describe it

Judge by substance, not labels: the review has never seen the key and will not
use the names K1/K2. Matching on a filename is not enough: the review must
make the same CLAIM the key makes. A review that says "this file needs more
test coverage" has NOT hit a key item that says "this file's existing test
asserts the bug as correct."

Also report:
  verdict   - the review's own overall conclusion, five words or fewer
              ("blocking", "should-fix", "no defects found", "ship it"),
              or "none" if it reaches no conclusion. If severity is stated per
              finding rather than overall, use the most severe one.
  claimed_execution - true if the review states it RAN something (tests, a repro)
  extras    - findings not in the key, each a short label. Do not include
              restatements of what the diff does.
  unusable  - true if the text is truncated, empty, or an error rather than a review

  quotes    - ★ REQUIRED. For every item you graded HIT or DEFER, the sentence
              from the REVIEW, copied verbatim, that made you decide it. Not a
              paraphrase and not your reasoning: the reviewer's own words. Use ""
              for a MISS. If you cannot find a sentence to copy, it is a MISS --
              that is what MISS means.

★ Why `quotes` is not optional. Two graders ran over these same reviews and split on
one item in three. Because the grade recorded only HIT/MISS, nobody could tell whether
they had credited DIFFERENT sentences or read the SAME sentence two ways -- so the
disagreement could only be settled by a human re-reading the review, which is how this
grading loop stopped being self-correcting. A quote makes a split diagnosable in
seconds. The adjudicator prompt learned this first; this one is late to it.

Output ONLY a JSON object, no prose, no code fence:
{"items":{"K1":"HIT","K2":"MISS"},"quotes":{"K1":"the reviewer's exact sentence","K2":""},
 "verdict":"blocking","claimed_execution":true,"extras":["label one"],"unusable":false}
