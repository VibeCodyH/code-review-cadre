# CLI reference

Where the vendor documents each CLI on the roster, what version of it was
working here, and the exact call cadre makes. One place to look when an upstream
release changes a flag and an adapter stops behaving.

**This file is a pointer, not a source of truth.** The measured quirks live in
`notes_<agent>()` inside each `agents.d/*.sh` and are printed by `cadre agents`.
Duplicating them here would guarantee the two disagree. What is here instead:
links that were fetched and confirmed to exist, and the version each adapter was
last known good against.

Versions captured **2026-07-26** on the machine cadre was built on. `agentcall
--installed` reported all 13 adapters installed, and `$CADRE_HOME/agents.d/`
(`~/.local/state/cadre/agents.d/` here, per `lib/common.sh:18`) did not exist, so
every row below is a shipped adapter with no local override in front of it.

## Mining verification

`cadre setup <repo-dir> [limit] [--verify]` mines candidates without executing
code by default. `--verify` or `CADRE_VERIFY_PAIRS=1` enables the optional
green-at-fix/red-with-source-reverted check. The shortlist TSV appends a
`verification` column (`verified`, `unverified`, or `no-test-cmd`). Existing
columns keep their positions. `CADRE_TEST_CMD` overrides detection;
`CADRE_VERIFY_TIMEOUT` is a positive integer in seconds (default 120 per arm).

Verification retains tests, configuration and other non-source files at the
fix revision. Source means the miner's supported code extensions outside test
paths, conventional Go/Python/Ruby/Java test filenames, and type declarations.
This is file-level separation. Rust source containing `test` or `doctest` is
left unverified because its assertions may be embedded in the source being
reverted. Other embedded-test conventions are not detected; inspect the saved
patch before treating the result as a test of the original assertion.
It handles additions, deletions and renames by
reversing their source-file patch. Separate fresh copies avoid generated-file
contamination between arms. No dependencies are installed automatically.
See the README execution warning before enabling this on a third-party repo.

## Roster

| adapter | binary | version here | docs | changelog |
|---|---|---|---|---|
| claude | `claude` | 2.1.220 | [CLI reference](https://code.claude.com/docs/en/cli-reference) | [CHANGELOG.md](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md) |
| coderabbit | `coderabbit` | 0.7.0 | [CLI overview](https://docs.coderabbit.ai/cli/overview) | [Changelog](https://docs.coderabbit.ai/changelog) |
| codex | `codex` | codex-cli 0.145.0 | [Non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode) | [Releases](https://github.com/openai/codex/releases) |
| copilot | `copilot` | 1.0.75 | [Programmatic reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference) | — |
| cursor | `agent` | 2026.07.23-e383d2b | [Parameters](https://cursor.com/docs/cli/reference/parameters) | [CLI Changelog](https://cursor.com/docs/cli/changelog) |
| devin | `devin` | 3000.2.17 | [Commands & Flags](https://docs.devin.ai/cli/reference/commands) | [Recent Updates](https://docs.devin.ai/release-notes) (product-wide) |
| grok | `grok` | 0.2.112 | [Headless & Scripting](https://docs.x.ai/build/cli/headless-scripting) | — |
| kimi | `kimi` | 0.29.1 | [kimi Command](https://moonshotai.github.io/kimi-code/en/reference/kimi-command.html) ⚠ | [Releases](https://github.com/MoonshotAI/kimi-code/releases) |
| kiro | `kiro-cli` | kiro-cli 2.14.2 | [Headless mode](https://kiro.dev/docs/cli/headless/), [CLI commands](https://kiro.dev/docs/cli/reference/cli-commands/) | — |
| opencode | `opencode` | 1.18.5 | [CLI](https://opencode.ai/docs/cli/) | [Releases](https://github.com/anomalyco/opencode/releases) |
| pi | `pi` | 0.82.1 | [CLI Reference](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/usage.md) | [CHANGELOG.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/CHANGELOG.md) |
| qwen | `qwen` | 0.21.0 | [Headless Mode](https://qwenlm.github.io/qwen-code-docs/en/users/features/headless/) | [Releases](https://github.com/QwenLM/qwen-code/releases) |
| vibe | `vibe` | vibe 2.18.0 | [Work with the CLI](https://docs.mistral.ai/vibe/code/cli/work-with-cli) | [CHANGELOG.md](https://github.com/mistralai/mistral-vibe/blob/main/CHANGELOG.md) |

Two adapters do not install under their own name: **cursor** is `agent` (also
`cursor-agent`) and **kiro** is `kiro-cli`. Both declare it with `bin_<agent>()`,
so `agentcall --installed` finds them and `command -v cursor` does not.

## `cadre review` roster gates

The review roster comes from `--roster`, then `$CADRE_ROSTER`, then
the target repository's `.cadre/roster`, then `$CADRE_HOME/roster`. The project
file is looked up at the target's Git root, including linked worktrees and
`--full` file or subdirectory targets, regardless of where Cadre is invoked.
Non-Git targets use the global roster when neither override is set.

A project roster selects which reviewer adapters run: only review projects
whose policy you trust, or use `--roster` to select your own panel. The file is
parsed as data with the same validation as the other layers; it is never sourced
as shell code. An empty, comment-only, unreadable, or malformed project roster
fails explicitly instead of falling back. The report and `manifest.txt` record
`roster-layer` (`explicit`, `environment`, `project`, or `global`) and
`roster-path` (shell-escaped; empty for flag/environment selections).

Each comma- or newline-separated entry is an agent spec followed by optional
gate tokens; `#` starts a comment:

```
codex ?min-lines=200
opencode:meta/muse-spark-1.1 ?min-files=5 ?untested
claude ?paths=auth/ ?min-lines=20
```

- `?min-lines=N` — run when added plus deleted lines are at least N. Binary
  files add zero lines.
- `?min-files=N` — run when at least N files are touched.
- `?untested` — run when at least one non-test file and no test file changed.
  Deliberately crude: a path is a test when its basename or any directory
  segment contains `test` or `spec`, case-insensitively.
- `?paths=TEXT` — run when any changed repository-relative path contains the
  nonempty, case-sensitive literal substring TEXT. This is not a glob or regex;
  `?paths=*.ts` searches for an actual `*.ts` in a filename. Gate tokens cannot
  contain whitespace, commas, or `#`, which delimit the roster syntax.

Gates measure the diff including tracked edits, deletions, and untracked
non-ignored files. Renames count as one touched file; both old and new names
participate in path matching and test classification. Paths retain their raw
bytes, including spaces, tabs, newlines, and Unicode.

Multiple gates are ANDed. `--all-seats` ignores them. `--full` has no diff to
measure, so every gated seat runs and the report states that gates do not apply.
Malformed gates are refused while parsing the roster.

Intent declarations and checks that a change fulfills them belong to issue #8;
project rosters only select seats and gate them on the diff.

## Capability preflight

Adapters may declare what they **cannot** do via optional `cannot_<agent>()`
(and model-level quirks via `model_cannot` in `lib/common.sh`). Dispatch checks
every seat before spending tokens and skips a doomed one with the declaration
named in the report and `slots.tsv`. Undeclared = unrestricted — a missed
declaration wastes a paid call, it does not lose a review. See
`docs/ADDING-AN-AGENT.md` for the tag list.

```
cadre preflight [--roster a,b,c]
```

prints the table. Seed declarations today: `agy` refuses
security-audit-shaped prompts; `cerebras/*` works as a judge but not a reviewer.
Preflight uses the same roster precedence, with the current Git root as its
project target; without any roster it lists all adapter declarations.

For a behavioral check against a saved tool-call response, use
`cadre contract-snapshot response.json --compare known-good-snapshot.json`.
It runs offline and exits nonzero on a mismatch. See
[contract snapshots](CONTRACT-SNAPSHOT.md) for capture conditions and limits.

Other review flags are `--base <rev>`, `--full`, `--roster a,b,c`, `--jobs N`,
`--synth <spec>`, `--label <name>`, and `--prerun <cmd>`.

## The call cadre makes

Generated with `agentcall --print-command <agent> -d . "hello"`, which is the
authoritative answer for the adapter as shipped — so if this block and an
adapter disagree, the adapter is right and this block is stale. Re-run it after
touching `agents.d/`. `$CLAUDE_DENY` is the deny list in `agents.d/claude.sh`,
spelled out there rather than here because it changes whenever a probe finds a
tool that did not exist before. `TIMEOUT` is `CADRE_TIMEOUT`
(900 default); `OUTFILE`/`PROMPTFILE` are `mktemp` paths. The prompt argument is
shown here as `"$prompt"` where the dry run prints the literal probe string, and
kiro's dry run omits the argument entirely — its real call passes the prompt as
the last argv word.

```
claude       claude -p --strict-mcp-config --settings '{"advisorModel":""}' \
                  --disallowedTools $CLAUDE_DENY                          [prompt on stdin]
claudecr     claude -p "/code-review <level>" --strict-mcp-config \
                  --settings '{"advisorModel":""}' --disallowedTools $CLAUDE_DENY
                  (level = the model slot: claudecr:low|medium|high|xhigh)  [takes no prompt]
coderabbit   coderabbit review --committed --base $CADRE_PASS_BASE --agent     [takes no prompt]
codex        codex exec -s read-only --ignore-user-config \
                  --skip-git-repo-check -C . -o OUTFILE -                  [prompt on stdin]
copilot      copilot -p "$prompt"                                             [argv]
cursor       agent -p --output-format json --force --workspace . --mode plan   [prompt on stdin]
devin        devin -p --permission-mode dangerous --prompt-file PROMPTFILE     [file]
grok         env HOME=$CADRE_GROK_HOME grok --cwd . \
                  --disallowed-tools edit,write --no-subagents \
                  --always-approve --no-auto-update --no-alt-screen \
                  --output-format json --prompt-file PROMPTFILE                [file]
kimi         kimi -p "$prompt"                                                [argv]
kiro         kiro-cli chat --no-interactive --trust-all-tools "$prompt"        [argv]
opencode     opencode run --dir . --auto                                       [prompt on stdin]
pi           pi -p                                                             [prompt on stdin]
qwen         qwen --yolo --max-session-turns -1 --output-format json           [prompt on stdin]
vibe         vibe --trust --prompt "$prompt"                                   [argv]
```

The three argv-bound adapters (`copilot`, `kimi`, `vibe`) plus `kiro` call
`argv_prompt_ok` first, because a synthesis prompt exceeds `MAX_ARG_STRLEN`.
See [ADDING-AN-AGENT.md](ADDING-AN-AGENT.md#say-which-kind-of-nothing-you-have).

## Where the docs and the CLI disagree

Recorded because each one cost time to find, and because a docs link is only
useful if you know where it lies.

- **kimi** ⚠ There are TWO Moonshot CLIs and the obvious docs site is the wrong
  one. `MoonshotAI/kimi-cli` (`moonshotai.github.io/kimi-cli/`) is the legacy
  product; what is installed here is `MoonshotAI/kimi-code`, a native binary in
  `~/.kimi-code/`, and its `kimi migrate` subcommand exists to import a legacy
  `kimi-cli` install. Both sites are titled "Kimi Code CLI Docs" and both serve a
  page at the same `/en/reference/kimi-command.html` path, so the wrong one looks
  right: it documents `--print` and `--afk` and changelogs a 1.49.x series, while
  the installed binary takes `-p/--prompt`, `--yolo`, `--auto` and reports 0.29.1.
  Link `kimi-code`, not `kimi-cli`. `kimi --help` prints its own docs URL as the
  tiebreak.
- **kiro** The `chat` reference does not document a `--model` flag, only
  `--list-models`. The CLI accepts `--model` anyway and the adapter depends on
  it — one adapter holds several roster slots that way. The measured model list
  is in `notes_kiro()` and is shorter than what kiro.dev advertises.
- **copilot** `-p/--prompt`, `--allow-all-tools` and `--model` are on the
  *programmatic* reference, not the CLI command reference or the "Using GitHub
  Copilot CLI" how-to. Both of those omit them.
- **cursor** The CLI overview page documents almost no flags. Everything cadre
  passes (`--print`, `--output-format`, `--force`, `--workspace`, `--mode`) is
  on the Parameters page.
- **codex** `docs/exec.md` in the repo is a one-line stub pointing off-site.
  Two redirects deep: `developers.openai.com/codex/*` → `learn.chatgpt.com`.
- **claude** `docs.claude.com/en/docs/claude-code/*` 301s to `code.claude.com/docs/en/*`.
- **opencode** `github.com/sst/opencode` now serves as `anomalyco/opencode`.
- **grok** No published changelog or release notes found; `xai-org/grok-build`
  has no GitHub releases. `grok --version` is the only version signal, and the
  adapter passes `--no-auto-update` so the binary does not move under a run.
- **devin** No CLI-specific changelog. The product release notes mention the CLI
  only in passing.

## Refreshing this file

```sh
bin/agentcall --installed
for c in claude codex copilot cursor-agent grok kimi opencode qwen vibe \
         coderabbit devin kiro-cli pi; do
  printf '== %-12s ' "$c"; command -v "$c" >/dev/null && "$c" --version 2>&1 | head -1
done
for a in $(bin/agentcall --installed); do
  echo "== $a"; bin/agentcall --print-command "$a" -d . "hello"
done
```

Re-fetch every link when you do. A vendor moving a docs page is the ordinary
case, not the exception — six of the thirteen above had moved or were on a page
other than the obvious one at the time of writing.
