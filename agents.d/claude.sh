# agentcall adapter: claude  (Anthropic Claude Code CLI)

notes_claude() {
  cat <<'NOTES'
Prompt MUST go on stdin, never argv, a diff-sized prompt exceeds ARG_MAX
and the failure looks like a CLI error, not a size problem.
ro mode allowlists read tools only.
NOTES
}

run_claude() {
  local ro=() m=()
  [ "$mode" = ro ] && ro=(--allowedTools "Read,Grep,Glob,LS,WebFetch,WebSearch")
  [ -n "$model" ] && m=(--model "$model")
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" claude -p "${m[@]}" "${ro[@]}"
    return 0
  fi
  ( cd "$dir" && printf '%s' "$prompt" | timeout -k 30 "$TIMEOUT" claude -p "${m[@]}" "${ro[@]}" 2>&1 )
}
