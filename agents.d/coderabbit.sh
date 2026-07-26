# agentcall adapter: coderabbit  (CodeRabbit CLI)

notes_coderabbit() {
  cat <<'NOTES'
Takes NO prompt, it ships its own review contract, so it cannot be given
the same brief as everyone else. Note that when you compare it.
★ Success is the type:"complete" JSON record, NEVER the exit code: it exits 0
with findings and without.
Reviews $CADRE_PASS_BASE..HEAD. A history-truncated benchmark checkout has no
`main` ref, and the default base would make it review nothing and report zero
findings, a silent clean pass that is really "never ran".
NOTES
}

# Declaring this makes the prompt optional for this agent.
noprompt_coderabbit() { :; }

run_coderabbit() {
  local raw c
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" coderabbit review --committed --base "${CADRE_PASS_BASE:-main}" --agent
    return 0
  fi
  raw=$(mktemp)
  ( cd "$dir" && timeout -k 30 "$TIMEOUT" coderabbit review --committed \
      --base "${CADRE_PASS_BASE:-main}" --agent ) > "$raw" 2>&1
  c=$(jq -rc 'select(.type=="complete")' "$raw" 2>/dev/null | tail -1)
  if [ -z "$c" ]; then
    jq -r 'select(.type=="error") | "DID NOT RUN, \(.errorType): \(.message)"' "$raw" 2>/dev/null | tail -1
    [ -s "$raw" ] || echo "DID NOT RUN, no output"
  else
    echo "findings=$(jq -r '.findings' <<<"$c")"
    jq -r 'select(.type=="finding") | "- [\(.severity)] \(.fileName)\n  \(.codegenInstructions)"' "$raw" 2>/dev/null
  fi
  rm -f "$raw"
}

# No model flag on this CLI. Refuse agent:model instead of running the
# default and filing the result under a model that never ran.
nomodel_coderabbit() { :; }
