# Byte-identity gate

A harness change that claims to be behavior-neutral (a prompt refactor, a
dispatch rework, a renderer split) has to leave every artifact of a fixed
fixture byte-identical. `tests/byte-identity.sh` makes that a gate rather than
a hope. It needs what the rest of the suite needs (Bash, Git, `jq`, Python 3)
and runs in about ten seconds.

```sh
bash tests/byte-identity.sh            # check; exit 1 with a unified diff on mismatch
bash tests/byte-identity.sh --accept   # regenerate the goldens after an INTENDED change
```

`bash test.sh` runs it with the rest of the suite.

## What it replays

Stub adapters only. No model is called and nothing touches the network. The
fixture is one two-commit repository and one answer key, and two stages:

1. **A live panel**: `cadre review` with a seat for each delivery state the
   renderers branch on (`ok`, `degraded`, `failed`, `inconclusive`,
   misconfigured, a repeated seat unioned from two rolls, a seat skipped by a
   roster gate), then a synthesis, then `cadre receipts`.
2. **A graded pass**: `cadre run` of a candidate for two runs under a pinned
   input lock, graded by a stub judge that reads the review it is handed, then
   `cadre panel`.

The synthesizer and the judge save the prompt they were given. The brief a
model receives is the harness's first output, and a refactor that moves it is
not neutral even when every score stays put.

## What is compared

Every file the two stages leave, not a chosen subset, so an artifact that
appears or vanishes is a diff too. The goldens live in
`tests/fixtures/byte-identity/`:

- `panel/`: the whole review directory: `report.md`, `manifest.txt`,
  `prompt.txt`, `diff.patch`, `diff.sha256`, `runs.jsonl`, `slots.tsv`,
  `synthesis.md`, `findings.json`, and every seat and roll artifact.
- `graded/`: the pass's candidate outputs, `prompt.txt`, `runs.jsonl` and
  grades; the gauntlet report; and its saved table (`manifest.json`,
  `results.json`, `report.md` and the grade snapshots). `passes.conf` and the
  key are kept too, so a harness that started rewriting its inputs would show.
- `captured/`: the synthesizer's and the judge's prompts, and the console
  output of `review`, `receipts`, `run` and `panel`.

Left out: dot-files (the claim, the gauntlet mutex), the fixture's own input
lock (it hashes the shipped adapters, which the fixture never runs), and the
stub adapters.

## Pinned inputs

These are set, not normalized. Everything derived from them is then compared
byte for byte:

- `env -i`, then `PATH`, `HOME`, `TZ=UTC` and `LC_ALL=C.UTF-8`, so a
  contributor's exported settings cannot leak into the goldens.
- `GIT_AUTHOR_*` and `GIT_COMMITTER_*` names, emails and dates, and no global
  or system git config. Every fixture commit, and every synthetic commit
  `run-review.sh` builds from them, gets the same sha on every machine, and so
  does every prompt that names one.
- Stub adapters whose bytes never contain the sandbox path. An adapter's bytes
  are hashed onto the run record (`adapter_sha`), so a baked path would move
  that hash on every run. The capturing stubs find their output directory from
  `BASH_SOURCE` instead.
- One job, fixed labels, a fixed roster, `CADRE_RETRY_WAIT=0`.

## Normalized fields, exactly

Nothing else is rewritten. Each item is either a clock, a temp path, or the
identity of the code under test, which by design changes on every edit the
gate exists to check:

| What | Where | Becomes | Why |
| --- | --- | --- | --- |
| The sandbox directory | every file | `<SANDBOX>` | `mktemp -d` differs per run |
| `ts`, `secs`, `wall_secs`, `seat_secs`, `prerun_secs`, `unattributed_secs` | `runs.jsonl` (panel and pass) | `<n>` | wall clock; `null` stays `null`, so measured versus unmeasured is still compared |
| column 6 (`secs`), when numeric | `slots.tsv` | `<n>` | wall clock; an empty field stays empty |
| the `secs` cell of each Receipts row and the `panel total` row | `report.md` | `<n>` | wall clock |
| the three figures in the `Wall clock:` line | `report.md` | `<n>` | wall clock; the sentence itself is compared |
| `bytes in Ns`, `DEGRADED/FAILED/INCONCLUSIVE after Ns` | console output only | `<n>s` | wall clock |
| `SECS` column (characters 80-87), when numeric | `cadre receipts` output | `<n>` | wall clock |
| `harness_sha` | `runs.jsonl`, `slots.tsv` column 11 | `<harness_sha>` | content hash of the harness itself |
| `harness:` line | `manifest.txt`, `report.md` | `<harness>` | same hash |
| `Harness: every row ran against …` | `cadre receipts` output | `<harness_sha>` | same hash |
| `cadre:` line | `manifest.txt`, `report.md` | `<cadre>` | the git revision of this checkout |
| `lock_sha` | pass `runs.jsonl` | `<lock_sha>` | hash of the fixture's input lock, which covers every shipped adapter |

Not normalized, because they are deterministic and a change in them is a
behavior change: `prompt_sha`, `adapter_sha`, `lock_adapter_sha`,
`lock_prompt_sha`, `prompt_source_sha`, the manifest's `prompt:` checksum, base
and reviewed tree ids, `diff-sha256`, the table's `results_sha256` and
`report_sha256`, byte counts and token estimates.

## When the gate fails

It prints `diff -ru golden actual` and exits 1. Either the change is not the
behavior-neutral change it claimed to be, or it is intended. For an intended
change:

```sh
bash tests/byte-identity.sh --accept
git add tests/fixtures/byte-identity
git diff --cached --stat -- tests/fixtures/byte-identity
```

The golden diff is then part of the commit, and a reviewer reads what moved
instead of taking "should not change results" on trust. A change that moves a
golden and says it is neutral is the case the gate exists for.

## Limits

The gate replays the deterministic parts of the harness only. It cannot see a
change that shows up only with a real model (a prompt that reads the same but
lands differently), a real adapter (none runs), `--jobs` above one, a
`--full` review, the adjudication track, or anything the fixture does not
exercise. A pass means the fixture's artifacts did not move; it is not
evidence that grades on real reviews did not. Wall-clock fields are compared
for presence (a number or `null`), not value, so a change to what a timer
measures, rather than whether it measured, passes.
