# Assurance case

Claims about what the harness protects, each backed by a test that fails if
the claim stops being true. To verify one, grep the quoted name in
`tests/review-smoke.sh` and run the suite. Anything backed only by a design
description belongs under non-goals instead — naming what this does NOT
protect against is half the point of the file.

The form is borrowed from alibaba/open-code-review's `ASSURANCE_CASE.md`. The
bar is not: theirs backs each claim with a description of the design; every
claim here cites a test.

## Claims

**1. A checkout handed to reviewers carries no credential-shaped files.**
Several adapters run their CLI with full tool approval, so the checkout is
the blast radius. `secrets_preflight` (lib/common.sh) refuses the run: exit 3,
fail closed, an unreadable directory is a refusal rather than a pass. Four
config files that usually carry no secret (`.npmrc`, `.netrc`, `.pypirc`,
`.dockercfg`) are gated on content instead of name, so a one-line
`package-lock=false` `.npmrc` does not fail every Node repo on its first run.
Tests: "a .env is still refused on the name alone", "an .npmrc carrying a
token IS refused", "benign .npmrc + credentials/ dir accepted".

**2. A credential deleted from the tree cannot reach reviewers through
history.** The checkout is a synthetic two-commit repo; `git log -p --all`
has no earlier history to answer with. External backing for treating history
as the leak path: gitleaks scans history by default (`gitleaks git` wraps
`git log -p`; `gitleaks dir` is the working-tree special case) — the
industry-standard scanner defaults to history precisely because a tree-only
view is known insufficient. The harness removes the history rather than
scanning it.
Test: the "deleted credentials must not reach reviewers" case, where a
reviewer that runs `git log -p --all` on the checkout finds nothing.

**3. A reviewer that did not finish is never scored as one that did.**
`classify_run` files truncated or partial output as degraded: kept, printed
in full, and excluded from a finding's denominator except where it raised
the finding — silence is not dissent.
Test: "it is degraded, findings kept".

**4. A review with no findings and no bottom line is not a clean pass.** The
`inconclusive` state exists because three artifacts on this machine scored
`ok` while being a summary, a clarification request, and a parroted diff —
counted as complete reviewers whose silence cleared every file.
Tests: "waffle -> .md.inconclusive", "run: filed .md.inconclusive".

**5. Harness state cannot contaminate the reviewed tree.** `CADRE_HOME` or
`CADRE_WORK` inside — or equal to — the reviewed repo is refused, because
state copied into the checkout is answer-key material sitting where the
reviewers read.
Tests: "nested CADRE_HOME refused", "CADRE_HOME == repo refused",
"CADRE_WORK == repo refused".

**6. The docs cannot silently drift from what the CLI does.** Adapter
invocation blocks are generated from `--print-command`, and the corrections
that mattered are pinned by tests.
Tests: "docs say the adapter wins", "preflight claim corrected", "but still
says what it misses".

## Non-goals, named

- **The preflight reads filenames, plus content for exactly four config
  files. A key in a source file passes.** An AWS key hardcoded in
  `src/config.js` is an ordinary tracked filename; it rides into a checkout
  handed to auto-approving CLIs. That is a deliberate no-dependency
  tradeoff. If a repo may carry in-source secrets, run a content scanner
  (`gitleaks dir`) before pointing cadre at it.
- **Leak control is not a sandbox.** Adapters with full tool approval can
  read your filesystem. METHOD.md §5 "What leak control does NOT buy you"
  says what the boundary actually is, and when you need a container.
- **A public target can leak its own answer** through issue and PR prose, no
  matter how shallow the clone. METHOD.md §5 — checking that is on you at
  target-pick time.
- **Receipts do not measure hidden reasoning tokens, provider billing, or
  in-CLI retries.** METHOD.md §6.
