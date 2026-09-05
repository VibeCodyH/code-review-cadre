# Pi review adapter and matched evaluation

`pireview` adds a structured review submission tool to Pi 0.84.4. It keeps the
reviewer's findings and execution records so a formatting failure, an interrupted
run, and a completed clean review have different outcomes.

This is an optional integration. Existing Cadre adapters need no Node dependency.
The SDK package requires Node 22.19 or newer.

## Try the adapter

From the Cadre repository:

```sh
npm ci --prefix integrations/pi-review
agentcall pireview -d /path/to/disposable-checkout -M provider/model < review-prompt.md
```

Configure the provider and credentials in Pi first. An explicit model is required;
the adapter refuses a model fallback. `CADRE_PI_THINKING` defaults to `off` and
accepts `minimal`, `low`, `medium`, `high`, or `xhigh` when the model supports it.
`CADRE_TIMEOUT` sets the review deadline in seconds.

To put it on a Cadre panel:

```sh
cadre review --roster pireview:provider/model --synth none
```

Cadre supplies the disposable checkout in this path. The adapter uses Pi's normal
`read`, `bash`, `edit`, and `write` tools plus `submit_review` and
`execution_receipts`. Bash can access the
host filesystem. A disposable checkout and disabled resource discovery are NOT
a sandbox. Use only repositories and model providers you already trust with the
available tools and source.

User/project extensions, skills, context files, prompt templates, and themes are
disabled. Compaction and automatic model retries are disabled for this first
slice. Configured provider model parameters still apply. Large reviews that need
compaction are outside this slice's evaluation.

The adapter is reviewer-only. It cannot serve as a keyed judge or synthesizer.

## What survives a run

Artifacts go under `$CADRE_HOME/pi-review/run.*/review/` by default.
`CADRE_PI_REVIEW_ARTIFACTS` overrides the parent directory. The adapter's state
note records the location in `runs.jsonl` as `adapter_note`. Each run gets a new directory; existing output is
never overwritten.

- `result.json`: submitted findings, completion state, model identity, settings
  and code fingerprints, usage reported by Pi, and tool-call outcomes.
- `events.jsonl`: ordered tool calls/results and assistant lifecycle events.
  SDK reasoning deltas are not retained as full text.
- `review.md`: the submitted findings rendered for Cadre.

A finding includes its original title, severity, path/line, trigger, consequence,
and evidence. Locations must exist in the reviewed checkout; citations to deleted
files or base-only lines are not supported yet. An `executed` claim must name a recorded bash call that actually
exited. A failing reproduction can qualify. A tool call merely starting, timing
out, or being denied cannot. That check proves execution occurred; it does not
prove the command tested the claim correctly.

The reviewer calls `execution_receipts` to retrieve the actual command IDs and
exit outcomes before citing executed evidence. IDs are not inferred from prose.

Only a valid, completed `submit_review` can produce `ok`. Prose that says a review
is clean does not count as a submission. An explicit empty submission is allowed.
A provider failure, timeout, or duplicate submission cannot leave a clean
success. Accepted findings survive those failures as degraded output.

Artifacts contain review text, commands, and source excerpts. Keep them as private
as the repository being reviewed. The adapter does not serialize credentials or
provider configuration into its event log. Tools can still print sensitive data.

## Compare against stock Pi

First verify the eight synthetic cases without calling a model:

```sh
node evals/review-v1/verify-corpus.mjs
```

Then run the development comparison against an explicitly configured model:

The comparison requires Linux and `bwrap` (Bubblewrap), with working mount
namespaces. Each arm gets a private `/tmp`, with only its current checkout,
configuration, and output directory made visible there. This prevents a
reproduction from importing another attempt's temporary files. The runner checks
this support before dispatching a model; it does not fall back to a shared `/tmp`.
The standalone SDK adapter does not require Bubblewrap.

```sh
node evals/review-v1/compare.mjs --model provider/model --out /path/to/new-results
```

The default is two repetitions of six development cases, or 24 reviewer calls.
Each has a 180-second deadline. Set `--runs`, `--timeout`, or `--thinking` explicitly
to change those controls. `--case tenant-scope-buggy --runs 1` runs a two-call
protocol smoke test. `--agent-dir DIR` selects the source Pi configuration.

The baseline launches the pinned package's actual Pi CLI in JSON mode. The other
arm launches the SDK integration. Both receive the same common brief and byte
identical Git trees. Their scratch paths contain no case or buggy/fixed labels.
They use fresh sessions and copies of the same provider configuration, with the
same enabled coding tools and effective thinking setting. Unsupported thinking
settings are rejected before either arm runs. Alternating arm order reduces a
consistent first-run cache advantage; it does not eliminate server-load effects.

The private temporary directory is not a host filesystem sandbox. Other host
paths and network access remain available to the tools.

The intervention is the submission and receipt tools with their instructions, plus the
CLI-to-SDK lifecycle change. A difference cannot be attributed to any one of
those changes without a later experiment.

The runner checks the corpus and execution-code fingerprints before and after every arm.
Changed code stops the comparison. It preserves failed observations, validates
observed model identity, and marks tracked checkout mutations invalid. Untracked
reproduction files are allowed. `report.md` links both reviews, while `runs.jsonl`
records dispatches and completions. Stock JSON mode's exit code is insufficient:
the runner also checks the final assistant stop reason and event completion.

The temporary credential copies and checkouts are removed when the comparison
exits normally or throws. A forcibly killed process can leave private temporary
files behind. Results belong outside the Cadre worktree and are never committed
automatically.

## What the corpus establishes

The four original scenarios cover a cross-tenant update, cleanup after partial
failure, a non-atomic revision check, and a vacuous regression test. Each has a
buggy and repaired counterpart with the same behavioral oracle. The verifier
requires an explicit assertion failure on the buggy tree and success on its
repair. Crashes, import errors, launch failures, and timeouts cannot count as
proof of the defect. Every corpus file has a SHA-256 entry in the manifest.

The vacuous-test pair is held out from default runs. Use `--split holdout` only
after freezing the implementation; `--split all` includes both groups. The
holdout is visible source, so it is a tuning convention, not a secret dataset.

These are small synthetic development cases. Their keys are provisional guidance
backed by the specific behavioral checks. They are not independently adjudicated
production defects, and a repaired case is not proof that every possible finding
on that code is false. Scores here must not determine a production roster.

`ok` means the arm delivered usable output. The report does not turn that into a
quality score. `adjudication.template.json` leaves grades blank for a separate
read of the findings against the oracle and surrounding code. Keep that reader's
identity and method explicit. Preserve the original review as evidence and judge
out-of-key findings separately.

## Offline checks

After installing the optional SDK dependency:

```sh
node --test integrations/pi-review/review.test.mjs evals/review-v1/corpus.test.mjs evals/review-v1/compare.test.mjs
bash tests/pi-review.sh
bash tests/review-smoke.sh
bash tests/engine-seam.sh
```

The SDK tests include its real tool loop with a fake model stream. None of these
checks make a provider request. Live comparisons are separate from CI.

This slice builds on [context A/B evaluation (#8)](https://github.com/VibeCodyH/code-review-cadre/issues/8)
and [grading provenance (#39)](https://github.com/VibeCodyH/code-review-cadre/issues/39).
Repeated-seat production panels and independent judge calibration remain separate
work.
