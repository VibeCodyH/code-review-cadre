# Prior art

Checked before this was written, not assumed. Credibility here comes from
naming what we did not invent.

## Already exists, we do not claim any of it

- **Fix-commit-derived answer keys.** SWE-bench lineage. The [Code Review Agent
  Benchmark](https://arxiv.org/html/2603.23448v2) builds keys from what the
  author repaired next, which is exactly what `cadre setup` does.
- **LLM-as-judge grading of reviewer output.** Standard practice.
- **Multi-bot comparison.**
  [withmartian/code-review-benchmark](https://github.com/withmartian/code-review-benchmark)
  already tracks CodeRabbit, Copilot, Claude, Cursor, Codex, Gemini, Greptile,
  Qodo and others on a shared corpus.
- **Headless multi-CLI wrappers.**
  [RobertTLange/headless-cli](https://github.com/RobertTLange/headless-cli).
  `bin/agentcall` started from its read-only recipes for a couple of the CLIs.
- There is a whole [survey of code-review
  benchmarks](https://arxiv.org/html/2602.13377v1). Read it before believing
  anyone's novelty claim, including this one.

## What is actually different here

Sourced from the closest competitor's own stated limitations, not from our
opinion about it.

1. **BYO-repo.** withmartian is *"not a tool you apply to private repos… you can
   add new tools, but not evaluate against your own proprietary codebases."*
   Everything in this repo is built around pointing the harness at a repo that
   will never be published: mining your own history for targets, leak-controlled
   local checkouts, a secrets preflight before any agent runs.

2. **The output is a roster, not a rank.** withmartian: *"Doesn't recommend
   models. No multi-model panel selection or comparison framework."* `cadre run`
   ends in a slot recommendation (primary, secondary, or do-not-slot) and
   deliberately does not maintain a leaderboard.

3. **DEFER is a distinct, disqualifying grade.** withmartian: *"Can't separate
   'found bug but dismissed it' from 'genuinely missed it'."* This is the
   strongest contribution here and the reason the rubric exists in the shape it
   does. See [METHOD.md](METHOD.md).

4. **Decorrelation is the objective.** Not "which reviewer scores highest" but
   "which reviewer fails on different items than the ones I already run."

None of these are algorithmic novelties. They are a different question asked of
the same machinery.

## Honest limitations

- The judge is a model. It can misgrade, and it grades from the review text
  alone, which is the only way to keep it from re-reviewing the code, but it
  means a correct finding written unclearly scores as a miss.
- Two runs per pass is a small sample. Reviewer output varies run to run; we
  have measured the same CLI, same checkout, same prompt returning "no defects
  found" on one run and a blocking finding on the next.
- Answer keys are drafted by a model and corrected by you. If you skip the
  correcting, you are measuring agreement with the drafter. `cadre add-pass`
  refuses while the draft marker is present, and that is the only enforcement
  there can be.
- Shipped reference passes are contaminated by construction: see
  [../passes/README.md](../passes/README.md).
