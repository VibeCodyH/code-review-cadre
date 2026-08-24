# agentcall adapter: muse  (Meta Muse Code CLI)

notes_muse() {
  cat <<'NOTES'
★ Bad flag combos dump help text and EXIT 0, so the adapter greps the output
for a help dump instead of trusting the exit code. Prompt goes in a file via
--prompt-file: -p/--single is argv and hits MAX_ARG_STRLEN on a diff-sized
prompt, the same ceiling grok's adapter documents.
An unqualified muse seat runs muse-spark-1.2-contributor, stated explicitly
so the report never files a run under a model the CLI silently defaulted.
Contributor tier trains on inputs; do not seat it on a private corpus without
the repo owner's say-so. 60 RPM. Untrusted workspaces skip AGENTS.md rules
(warns, continues), which is correct for a review checkout.
NOTES
}

run_muse() {
  local out pf m=() ro=()
  m=(--model "${model:-muse-spark-1.2-contributor}")
  # Sandbox is ON by default; ro additionally drops write and web tools.
  # Shell reads stay allowed: the review prompt sanctions running targeted
  # tests, same line grok's adapter draws.
  [ "$mode" = ro ] && ro=(--disable-write --disable-web-tools)
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" muse exec "${m[@]}" "${ro[@]}" \
      --workspace "$dir" --disable-approval --prompt-file PROMPTFILE
    return 0
  fi
  pf=$(mktemp); printf '%s' "$prompt" > "$pf"
  out=$(mktemp)
  ( cd "$dir" && timeout -k 30 "$TIMEOUT" muse exec "${m[@]}" "${ro[@]}" \
      --workspace "$dir" --disable-approval --prompt-file "$pf" ) > "$out" 2>&1
  rm -f "$pf"
  # The help-dump-on-exit-0 trap: a run that "succeeded" into usage text is a
  # run that never happened.
  if head -5 "$out" | grep -qE '^(Usage: muse|muse exec \[)'; then
    echo "DID NOT RUN, CLI dumped help text (bad flag combo). Raw:"
    head -c 2000 "$out"
  else
    cat "$out"
  fi
}
