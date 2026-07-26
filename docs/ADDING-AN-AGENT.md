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
