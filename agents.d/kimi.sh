# agentcall adapter: kimi  (Moonshot Kimi CLI)

notes_kimi() {
  cat <<'NOTES'
No read-only mode. Emits its raw reasoning with no verdict contract, 45KB+
of thinking for a small diff, so the judge step has to dig for a conclusion.
Grade it before you slot it; long output is not the same as thorough output.
NOTES
}

run_kimi() {
  local m=(); [ -n "$model" ] && m=(--model "$model")
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" kimi "${m[@]}" -p "$prompt"
    return 0
  fi
  argv_prompt_ok || return 0
  ( cd "$dir" && timeout -k 30 "$TIMEOUT" kimi "${m[@]}" -p "$prompt" 2>&1 )
}
