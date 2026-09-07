# Pin adapters and prompts before a benchmark

`cadre run` checks `cadre.lock.json` before dispatching a reviewer or judge.
Changed, added, missing, or unreadable inputs stop the run. This check needs
Python 3. The shipped lock covers every `agents.d/*.sh`, the Markdown files in
`lib/prompts`, and the four source/package files used by the Pi SDK adapter.

```bash
cadre selfcheck
# After reviewing an intentional adapter or prompt change:
cadre lock --update
git diff -- cadre.lock.json
```

`lock --update` writes sorted JSON with no timestamp, preserving optional
`source` and `skillPath` attribution on existing entries. Add those fields when
copying a file from an upstream project. Each `computedHash` is the full SHA-256
of that file's bytes. Missing or malformed locks fail explicitly; an update
doesn't overwrite a malformed lock.

## User adapters and custom prompts

Every shell file in `CADRE_AGENTS_D` (default `$CADRE_HOME/agents.d`) is an input,
because `agentcall` loads the whole directory. A new override therefore needs a
new pin even if its filename belongs to a different seat. `CADRE_PROMPT_FILE`
adds the custom review brief to the input set. Use a separate lock to keep your
local inputs out of the shipped lock:

```bash
export CADRE_LOCK_FILE="$CADRE_HOME/experiment.lock.json"
export CADRE_PROMPT_FILE="$PWD/review-brief.md"
cadre lock --update
cadre selfcheck
cadre run codex 2
```

Keep that environment for subsequent runs. The lock uses logical names such as
`root:agents.d/codex.sh`, `user:codex.sh`, and `custom:review-prompt`, so moving an
unchanged checkout doesn't change its identity. Removing a custom prompt or an
override also changes the input set and requires an intentional lock update.

## Run receipts

The benchmark runner checks again before each new run and refuses a lock update
during the pass. Its `runs.jsonl` dispatch and completion records carry the full
`lock_sha`, plus `lock_adapter_sha` and `lock_prompt_sha`. Completion records also
carry the measured `adapter_sha` and `prompt_source_sha`; these must match the
corresponding locked values before dispatch.

The short adapter/source fingerprints use the existing #37 ordered-digest
format. `prompt_sha` still identifies the rendered prompt actually sent, which
can differ from the source template after checkout context is inserted.
Promptless adapters still record an empty `prompt_sha`.

```bash
jq -c 'select(.event == "complete" and .lock_sha != null) |
  {seat, run, lock_sha,
   adapter_matches: (.adapter_sha == .lock_adapter_sha),
   prompt_source_matches: (.prompt_source_sha == .lock_prompt_sha)}' runs.jsonl
```

This query shows pinned runs; older records have no lock fields.
The lock path is scrubbed from all agent environments. The lock checks local
file drift; it doesn't pin external CLI installations, provider behavior, or
rendered checkout context. Keep the input tree unchanged during a run. This is
not protection against concurrent file edits after a check or an operator who
changes the code that enforces it.

`cadre review` remains available without a lock. `cadre grade` can regrade
historical artifacts without requiring today's source tree to match the inputs
that produced them. Existing review artifacts and their receipts are preserved.
