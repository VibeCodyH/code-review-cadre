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
- **Repository-level ACR benchmarking, scored semantically and by line.**
  [alibaba/aacr-bench](https://github.com/alibaba/aacr-bench) (Apache-2.0,
  [arXiv:2601.19494](https://arxiv.org/abs/2601.19494), 14 authors) is the
  closest published work to this one on the metric side, closer than
  withmartian. Its README calls it *"the industry's first multilingual,
  repository-level context-aware code review evaluation dataset"*: 200 real
  pull requests, 50 projects, 10 languages, annotated AI-assisted and
  expert-verified. It ships a pluggable reviewer layer
  (`evaluation/reviewers/{claude,codex,ocr}.py`), an LLM judge and run pipeline
  (`judge.py`, `pipeline.py`, `evaluate.py`), MCP servers that collect reviewer
  findings, and per-reviewer token and wall-clock instrumentation with the
  cross-vendor accounting written down. Semantic and line-level matching each
  get their own precision, recall and F1, and the two NEST rather than stand
  side by side: `evaluation/judge.py` filters every candidate
  `path -> side -> line(k) -> semantic` and drops it the moment a stage fails,
  so a finding at the wrong line can never reach semantic F1. Coverage
  and line-position validity are the same two axes this repo opened its own
  metric work on, and convergence from a 14-author paper is support for the
  axis. It is not support for anyone's numbers, theirs or ours. The related
  *"~1/9 of the tokens"* claim made by
  [alibaba/open-code-review](https://github.com/alibaba/open-code-review) has
  no published run record behind it, but their harness does instrument tokens,
  so it is checkable by rerunning rather than unfalsifiable. Do not repeat it
  as measured, and do not call it unmeasurable either.
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
- **Greppable check tables as reviewer input.**
  [goshipit](https://github.com/Capta1nRaj/goshipit) (Apache-2.0) writes its
  checks as literal patterns to look for rather than as topics —
  `findById(req.params.id)` with no ownership filter, not "check authorization"
  — and resolves framework-specific names once per project instead of
  hardcoding a framework list.
  [CHECKS-SECURITY-RELIABILITY.md](CHECKS-SECURITY-RELIABILITY.md) is adapted
  from its category C and F tables, with severities reassigned to the rubric
  here. That file is a reading list; it is not wired into any prompt, because
  the review brief has to stay identical across passes to be comparable.
- There is a whole [survey of code-review
  benchmarks](https://arxiv.org/html/2602.13377v1). Read it before believing
  anyone's novelty claim, including this one.

## What is actually different here

Items 1-4 are sourced from the closest competitor's own stated limitations,
not from our opinion about it. Item 5 is sourced from trying to do it their way.

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

5. **The seat under test can be a subscription.** AACR-Bench drives every
   reviewer through an API-metered environment contract:
   `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` for Claude Code,
   `CODEX_API_KEY` for Codex, `OCR_LLM_URL` / `OCR_LLM_TOKEN` for
   OpenCodeReview. There is no path for a seat you already pay a flat rate
   for, so scoring the tools a developer uses every day means paying a second
   time, per token, for capability already owned. `bin/agentcall` drives the
   CLI as you actually run it, on the plan you already have. Learned by
   setting their harness up rather than by reading it: the environment
   contract is visible in the source, what it costs to work around is not.
   The smallest diff in a 15-instance pilot, four changed lines, cost about
   $3.78 on a Claude arm that timed out at eleven minutes and produced no
   findings, because the agent re-explores the repository per instance and
   diff size does not bound spend.

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
