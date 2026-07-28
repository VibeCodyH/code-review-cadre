# agentcall adapter: codex  (OpenAI Codex CLI)

notes_codex() {
  cat <<'NOTES'
-s read-only. Needs -o FILE or it streams its entire reasoning trace to
stdout (152KB measured on a 4-file diff) instead of the review.
Prompt goes on stdin via the trailing '-'.
★ Refuses to start outside a git repo without --skip-git-repo-check. The judge
and keygen steps run in a scratch dir, so without that flag codex-as-judge
fails on every call and every grade comes back UNUSABLE.
Builds differ: some have ONLY -s/--sandbox and error on
--ask-for-approval / --search. --print-command before you trust it.
★ ro adds --ignore-user-config WHERE THE BUILD HAS IT, so a review does not
inherit $CODEX_HOME/config.toml -- mcp_servers and model overrides included.
That is parity with claude's --strict-mcp-config; without it the benchmark
compares one model without your MCP servers against another with them. If your
model normally comes from config.toml, name it with -M or the run uses codex's
default. Auth is unaffected, it still reads CODEX_HOME.
★ Slow on whole-repo briefs. Measured: killed at the default 900s with the -o
file still empty, which the adapter used to return as an empty review. It now
reports the timeout. Raise CADRE_TIMEOUT for anything bigger than a diff.

★★ UNCLOSED, KNOWN, AND MEASURED: under `-s read-only` codex still holds
`collaboration.spawn_agent`, `send_message`, `list_agents`, `wait_agent` and
`web.run`. Probed 2026-07-28 by asking it to enumerate its own tools. That is
the SAME class of hole as claude's `advisor`: a candidate that can consult
another model is not a peer of one that cannot, and it voided a whole benchmark
round the last time it went unnoticed.

The sandbox does not close it. `-s read-only` governs model-generated SHELL
commands, not the model's tool registry, and none of `--disable multi_agent`,
`--disable multi_agent_v2` or `--disable collaboration_modes` removed a single
one of those tools -- all three probed, all three no-ops here. If you find a
mechanism that does, that is the fix; until then this is recorded rather than
assumed away, because an unrecorded asymmetry is what makes a comparison wrong
while it still looks right.

Treat a codex seat as POSSIBLY-ASSISTED when you compare it against claude,
which denies its equivalents by name. Whether any given run reached for those
tools is not something the harness can see, which is exactly why claude.sh
denies rather than trusts.
NOTES
}

# ★ PROBED, never assumed. This adapter's notes already record that codex builds
# differ and error on flags they do not have, and an unknown flag here would fail
# every codex call and read downstream as a dead reviewer rather than as a bad
# adapter. Cached: --help on every run is a process per review.
CODEX_IGNORE_USER_CFG=""
codex_ignore_user_config() {
  [ -n "$CODEX_IGNORE_USER_CFG" ] || {
    if codex exec --help 2>&1 | grep -q -- '--ignore-user-config'; then
      CODEX_IGNORE_USER_CFG=yes
    else
      CODEX_IGNORE_USER_CFG=no
    fi
  }
  [ "$CODEX_IGNORE_USER_CFG" = yes ]
}

run_codex() {
  local last ro=() m=()
  # ★ PARITY with claude.sh's --strict-mcp-config, and the same reasoning.
  # claude drops the OPERATOR's MCP servers in ro mode; codex was still loading
  # $CODEX_HOME/config.toml, which can define mcp_servers and model overrides.
  # A benchmark comparing the two was therefore comparing "claude without your
  # MCP servers" against "codex with them" -- a property of the machine the
  # benchmark ran on, not of either model, and invisible in the report.
  # Auth is unaffected: it still reads CODEX_HOME.
  if [ "$mode" = ro ]; then
    ro=(-s read-only)
    codex_ignore_user_config && ro+=(--ignore-user-config)
  fi
  # Dropping $model runs the default and files it under the requested one. A
  # benchmark that mislabels what it measured is worse than one that refuses.
  [ -n "$model" ] && m=(-m "$model")
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" codex exec "${ro[@]}" "${m[@]}" --skip-git-repo-check -C "$dir" -o OUTFILE -
    return 0
  fi
  last=$(mktemp); : > "$last"
  printf '%s' "$prompt" | timeout -k 30 "$TIMEOUT" codex exec "${ro[@]}" "${m[@]}" --skip-git-repo-check -C "$dir" -o "$last" - >/dev/null 2>&1
  local rc=$?
  # ★ Measured here: the 900s default killed codex with -o still empty and the
  # adapter returned "". Downstream that reads as "found nothing", the worst
  # thing an adapter can do. Say what happened instead.
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    # Killed. If -o holds anything, emit it and mark it _TRUNCATED rather than
    # discarding it: the text is a real review, and its silence about a file
    # means "never got there", not "clean". docs/ADDING-AN-AGENT.md.
    # ⚠ Measured on codex 0.145.0, where -o is --output-last-message and is
    # written only at final completion: a mid-turn kill leaves it EMPTY, so in
    # practice this branch almost always falls through to the else. Keep it --
    # it costs nothing and a future codex that flushes incrementally would be
    # silently throwing findings away without it -- but do not read it as
    # evidence that codex streams partial reviews to -o today. It does not.
    if [ -s "$last" ]; then
      cat "$last"
      echo
      echo "_TRUNCATED, codex was killed at the ${TIMEOUT}s timeout; this review is INCOMPLETE, not a clean pass. Raise CADRE_TIMEOUT._"
      # ★ Nonzero as well as the marker, so this adapter stays usable as a
      # SYNTHESIZER: there the marker cannot be trusted, because a synthesis is
      # asked to discuss truncated reviewers and may quote one. agents.d/grok.sh
      # carries the same pair and the full reasoning.
      rm -f "$last"; return 1
    else
      echo "DID NOT COMPLETE, codex was killed at the ${TIMEOUT}s timeout with no output. Raise CADRE_TIMEOUT."
    fi
  elif [ ! -s "$last" ]; then
    echo "DID NOT COMPLETE, codex exited $rc and wrote no output."
  else
    cat "$last"
  fi
  rm -f "$last"
}
