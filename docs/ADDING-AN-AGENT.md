# Adding an agent

Three cases, in increasing order of work.

## A new MODEL on a CLI you already have

Nothing to add. Use `agent:provider/model`:

```
cadre run opencode:vendor/some-model-1.1
```

Multi-provider front-ends are the cheapest way to get a model lineage your other
CLIs cannot reach, which is what [decorrelation](METHOD.md#4-decorrelation-not-maximisation)
needs.

## A new CLI

```
agentcall --new mycli        # writes $CADRE_HOME/agents.d/mycli.sh
```

Edit the stub. It has two required functions, and one optional:

- `notes_mycli()`, one paragraph, printed by `cadre agents`. Write **measured**
  quirks here, not the vendor's description. This file is where the next person
  finds out that a flag silently no-ops.
- `run_mycli()`. `$dir`, `$mode` (`ro`/`rw`), `$model`, `$prompt` and `$TIMEOUT`
  are in scope. Print the agent's **final text** on stdout and nothing else.
- `cannot_mycli()` (optional). Machine-checkable incapability declarations.
  Print one tag per line. Undeclared means unrestricted: **a missed declaration
  wastes a paid call, it does not lose a review.** Loose is safe here. Dispatch
  reads these before any seat runs and refuses a doomed seat with the tag named
  in the report and in `slots.tsv`. `$model` is in scope, so multi-provider
  front-ends can key a declaration on the model half of the spec.

  Tags currently checked:

  | tag | blocks when |
  |---|---|
  | `role:reviewer` | the seat is dispatched as a reviewer |
  | `role:judge` | the seat is used as `CADRE_JUDGE` |
  | `role:synth` | the seat is used as `--synth` |
  | `prompt:security-audit` | the brief is a security-audit-shaped prompt (not mere "security" in a priority list) |

  Model-level quirks that are not CLI-level (today: `cerebras/*` cannot be a
  reviewer) live in `model_cannot` in `lib/common.sh` so every adapter that
  reaches that model inherits them. See `cadre preflight` for the table.

### Say which kind of nothing you have

An adapter that returns "" when its CLI dies reads downstream as *a reviewer that
looked and found no defects*. That is the worst thing an adapter can do, so the
output contract has three cases you emit and **only the adapter can tell them
apart** —
nothing further down the pipe can see the difference between an empty answer and
an empty failure.

| you have | print | cadre records it as |
|---|---|---|
| a complete review | the review, nothing else | `ok` |
| review text, cut short | the text, then a line starting `_TRUNCATED` | `degraded` |
| no review at all | a line starting `DID NOT RUN` or `DID NOT COMPLETE`, then any raw output that helps diagnose it | `failed` |
| your CLI refused for a reason that is the OPERATOR's to fix (a model the vendor does not serve, a flag this build lacks) | `DID NOT RUN, misconfigured: <why>` | `failed`, reported as MISCONFIGURED rather than as a reviewer failure |

**If the clock is what stopped you, say so on that marker line, with the number:**
`DID NOT COMPLETE, <agent> was killed at the ${TIMEOUT}s timeout`. It does not
change your state — you are still `failed` — it changes what the operator is
told. Cadre reports a clock kill and a provider that returned nothing as two
different things, because they call for opposite responses, and the exit code is
not enough to tell them apart: most adapters here normalise theirs to 0 on a
kill, so the marker line is the only place the fact survives. Leave the number
out and your timeout prints as a flat `FAILED`, which reads as a verdict on the
model.

There is a fourth state, `inconclusive`, and **it is not yours to emit.** Cadre
decides it by reading the artifact: a run that exited cleanly and stated neither a
finding nor a bottom line never reviewed anything, whatever else it printed. You
cannot signal it and you do not need to — if your adapter knows the run went
wrong, say `DID NOT RUN` and get `failed`, which is stronger information. What
`inconclusive` catches is the case no adapter can see: the CLI worked perfectly
and the *model* declined the job. One of the three measured examples was an
unmarked truncation, so no `_TRUNCATED` was ever coming.

### Declaring the state directly, when you know it

The markers above are text, and cadre reads them back out of the artifact. That
works, and every shipped adapter uses it. It has one weakness: text a *model*
controls can collide with text the contract reserves. A synthesis asked to say
which reviewers were truncated quotes `_TRUNCATED` and classifies itself as
truncated; a short review that merely discusses rate limiting trips the keyword
scan. No text test can tell those apart, because both are legitimate.

If your adapter *knows* — it read a `stopReason`, it caught its own timeout —
say so out of band:

```sh
run_youragent() {
  ...
  cadre_state degraded "stopReason=MaxTokens"     # ok | degraded | inconclusive | failed
}
```

`cadre_state` outranks the markers, the exit code, and every inference cadre
would otherwise make. Nothing the model prints can forge one, because printing
is not calling it.

**How far to trust it.** A declaration is trusted exactly as much as the
*adapter* is, and no further. Cadre hands the adapter a path and believes what
it finds there; it cannot tell your `cadre_state` call from anything else that
wrote to the same file. The agent CLI you spawn runs as the same uid as cadre,
and several of them will run a shell on request — so a model that goes looking
can reach that file, and a declared `ok` outranks a `_TRUNCATED` marker and a
nonzero exit. The path is a private temp directory rather than a bare temp file,
which stops the blind `for f in /tmp/tmp.*` version, and that is a speed bump,
not a boundary. Same posture as the rest of the environment scrub:
mitigation, not a sandbox, docs/METHOD.md §5. The marker contract is the more
conservative channel precisely because the adapter, not the model, appends it
after the CLI has already exited.

**It is optional.** Say nothing and the marker contract above is still in
charge — that is not a deprecated path. Two things it will not do for you: an
unknown state is ignored rather than believed (a wrong field would outrank the
text, so falling back is the safe direction), and declaring `ok` will not
rescue an artifact that came back empty. It is also a no-op when `agentcall`
runs outside cadre, so it costs a standalone caller nothing.

**`cadre_model <id[,id...]>`** rides the same channel and carries the model(s)
that actually served the run. Most adapters never need it: the spec pins the
model (`codex:gpt-5`) and the row already says what ran. It exists for a seat
whose model slot is spent on something else — `claudecr:high` holds the effort
level, so the CLI's *default* model serves it, and that default can change
between two passes of one sweep with nothing in the artifacts recording the
split. Declare it only from something the CLI *reported* (`claudecr` reads
`modelUsage` out of `--output-format json`); never from a setting, a flag you
passed, or a guess. If you cannot read it, say nothing — the field stays EMPTY,
and EMPTY means "not determined", which is a true statement where a default
would be a claim. It lands on `runs.jsonl`, on column 12 of `slots.tsv`, and in
the report's Receipts table, and `cadre receipts` names any seat that ran under
more than one model instead of adding those rows together.

The one thing this asks of you: **do not append your own trailing summary to a
review.** The check is edge-anchored, so a "review complete, 0 issues" footer your
wrapper adds would satisfy it on behalf of a model that said nothing.

**Take the prompt on stdin or from a file if your CLI offers either.** Linux
caps a single argv entry near 128KB no matter what `ARG_MAX` says, and the exec
fails with `Argument list too long` — an error naming neither your agent nor the
reason, which lands in the artifact as non-empty text and scores as a review
that found nothing. Reviews are small and never reach it. A **synthesis** is
every review concatenated, so this fires precisely when merging matters most: a
3-reviewer panel produced a 184KB prompt here and killed an argv-only adapter.
`codex` and `claude` pipe it, `grok` writes a temp file, `opencode` takes stdin
even though its help only documents a positional. If your CLI truly has neither,
call `argv_prompt_ok || return 0` before you exec; it prints a `DID NOT RUN`
naming the size and the way out.

**To be usable as a synthesizer, an adapter must ALSO exit nonzero when it
truncates.** The text marker is enough for a reviewer slot and not enough for a
synth slot, because the synthesis prompt asks the model to report which
reviewers were truncated — so a complete, correct synthesis can legitimately end
by quoting a `_TRUNCATED` line, and cadre cannot tell that apart from a merge
that died mid-sentence. It stops reading the marker there and reads your exit
status instead. An adapter that returns 0 while printing the marker will pass a
half-finished synthesis off as a whole one, and nothing downstream can catch it.
`grok` and `codex` do both.

`degraded` is a real state, not a polite failure. A partial review's findings go
to the synthesizer and into the report; what changes is that its **silence stops
counting** — the files it never reached are not cleared, and it is not tallied as
a dissenter on a finding it never saw. Getting this wrong has gone both ways
here: a truncated grok review once scored as complete, and the fix for that then
threw partial reviews away entirely.

So if your CLI can stop early with text already in hand, emit both. `agents.d/grok.sh`
checks `stopReason` and appends the marker after the text; `agents.d/codex.sh`
prints whatever reached its `-o` file before the timeout killed it, then the
marker. Reserve `DID NOT COMPLETE` for the case where you genuinely have nothing.

Then, before you trust it:

```
agentcall --print-command mycli -d . "hello"   # is the invocation right?
agentcall --probe mycli                        # does it authenticate?
```

`--print-command` exists because every adapter bug found so far was invisible
until output further downstream looked wrong.

### The two traps that have caught every CLI so far

1. **A diff-sized prompt exceeds `ARG_MAX`.** Prefer stdin over argv. The
   failure surfaces as a generic CLI error, not as a size complaint.
2. **Silent tool-call cancellation.** Several CLIs deny tool calls headless
   unless you pass an approval flag, and then return a confident review of a
   diff they never opened. It is indistinguishable from a lazy review. Find that
   flag before you trust the adapter. `agents.d/grok.sh` (`--always-approve`)
   and `agents.d/opencode.sh` (`--auto`) are two worked examples, and
   `grok.sh` also shows how to detect an early stop and say so loudly rather
   than returning quiet, short, plausible output.

Other things worth checking once:

- Does it exit 0 on failure? (CodeRabbit does: its adapter reads a completion
  record instead.)
- Does it stream its reasoning to stdout? (Codex does without `-o FILE`: 152KB
  of trace on a 4-file diff.)
- Does it need per-directory trust before it will read the repo's agent
  instructions file?

## Overriding a shipped adapter

A file in `$CADRE_HOME/agents.d/` **wins** over the same filename in the repo's
`agents.d/`. When a CLI changes a flag upstream, fix it in your own directory -
you get the fix without a merge conflict on every pull.

## Then grade it

```
cadre run mycli 2
```

Adapters for CLIs that turn out not to be reviewers are still worth keeping,
with the finding recorded in `notes_`. One CLI on the machine this was built on
auto-denies its own tool calls when pointed at a directory, so it can never read
its own input, and refuses any security-framed prompt outright: it is a fine
text cruncher on stdin and a useless reviewer. That is a result. Write it down
so nobody re-derives it.
