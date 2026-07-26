# agentcall adapter: vibe  (Mistral vibe CLI)

notes_vibe() {
  cat <<'NOTES'
Needs --trust per directory or it ignores the repo's agent instructions file.
Needs MISTRAL_API_KEY in the environment; agentcall never reads it from disk.
NOTES
}

run_vibe() {
  # --print-command must work without credentials: it exists to inspect the
  # invocation, and an auth check in front of it defeats that.
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" vibe --trust --prompt "$prompt"
    return 0
  fi
  [ -n "${MISTRAL_API_KEY:-}" ] || { echo "DID NOT RUN. MISTRAL_API_KEY is not set"; return 0; }
  ( cd "$dir" && timeout -k 30 "$TIMEOUT" vibe --trust --prompt "$prompt" 2>&1 )
}

# No model flag on this CLI. Refuse agent:model instead of running the
# default and filing the result under a model that never ran.
nomodel_vibe() { :; }
