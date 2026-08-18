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
- **Ensemble judging beats a single judge.**
  [SE-Jury (Zhou et al., ASE 2025)](https://conf.researchr.org/details/ase-2025/ase-2025-papers/222/SE-Jury-An-LLM-as-Ensemble-Judge-Metric-for-Narrowing-the-Gap-with-Human-Evaluation-)
  reports ensemble LLM judges correlating with human judgment 34.4–113.0%
  better than prior automatic metrics, matching human inter-rater reliability
  on code generation and program repair. Peer-reviewed backing for the
  multi-judge premise — not for any tie-break: the grade here is still only
  what two judges agree on, and a split stays UNRESOLVED. (Downstream tools
  quote punchier per-task accuracy numbers from this paper; verify against
  the paper itself, we could not reproduce those figures from the abstract.)
- **Fresh context reviews better than the authoring context.** The premise
  behind handing reviewers a clean checkout instead of the conversation that
  produced the change, and it is backed three ways:
  [Liang et al.](https://arxiv.org/abs/2305.19118) name it
  Degeneration-of-Thought — once a model has confidence in a solution,
  reflection stops producing novel thoughts about it, even when the stance is
  wrong (their fix, multi-agent debate, is also this repo's shape);
  [Huang et al.](https://arxiv.org/abs/2310.01798) find LLMs cannot
  intrinsically self-correct reasoning, and sometimes get worse trying;
  [Panickssery et al.](https://arxiv.org/abs/2404.13076) show evaluators
  recognise and systematically prefer their own generations. None of it is
  new to software: Fagan inspections (1976) and Weinberg's egoless
  programming (1971) are the same principle without the GPUs. In tooling the
  pattern already ships as Claude Code's built-in `/code-review` and
  [fresh-eyes-review](https://github.com/eai-org/agent-toolkit/blob/main/skills/fresh-eyes-review/SKILL.md).
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
   ends in a seat recommendation (can review alone, needs a second reader, or
   do-not-slot) and
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
