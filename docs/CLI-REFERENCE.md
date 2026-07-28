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
