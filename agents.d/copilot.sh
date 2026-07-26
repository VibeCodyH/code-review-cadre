# agentcall adapter: copilot  (GitHub Copilot CLI)

notes_copilot() {
  cat <<'NOTES'
No read-only mode. Subject to a monthly request quota, when it runs out the
CLI still exits 0, so `agentcall --probe copilot` before a graded run rather
than discovering it in the scores.
NOTES
}

run_copilot() {
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" copilot -p "$prompt"
    return 0
  fi
  argv_prompt_ok || return 0
  ( cd "$dir" && timeout -k 30 "$TIMEOUT" copilot -p "$prompt" 2>&1 )
}

# No model flag on this CLI. Refuse agent:model instead of running the
# default and filing the result under a model that never ran.
nomodel_copilot() { :; }
