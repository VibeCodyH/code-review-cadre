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

Edit the stub. It has two functions:

- `notes_mycli()`, one paragraph, printed by `cadre agents`. Write **measured**
  quirks here, not the vendor's description. This file is where the next person
  finds out that a flag silently no-ops.
- `run_mycli()`. `$dir`, `$mode` (`ro`/`rw`), `$model`, `$prompt` and `$TIMEOUT`
  are in scope. Print the agent's **final text** on stdout and nothing else.

### Say which kind of nothing you have

An adapter that returns "" when its CLI dies reads downstream as *a reviewer that
looked and found no defects*. That is the worst thing an adapter can do, so the
output contract has three cases and **only the adapter can tell them apart** —
nothing further down the pipe can see the difference between an empty answer and
an empty failure.

| you have | print | cadre records it as |
|---|---|---|
| a complete review | the review, nothing else | `ok` |
| review text, cut short | the text, then a line starting `_TRUNCATED` | `degraded` |
| no review at all | a line starting `DID NOT RUN` or `DID NOT COMPLETE`, then any raw output that helps diagnose it | `failed` |

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
