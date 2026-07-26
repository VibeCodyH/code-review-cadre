# agentcall adapter: devin  (Devin CLI, Cognition)

notes_devin() {
  cat <<'NOTES'
Prompt via --prompt-file, so no argv ceiling: fine as a --synth.
-p/--print is non-interactive. --permission-mode dangerous, or it stops to ask
and a headless run hangs. "auto" only auto-approves READ tools, and a reviewer
has to run git, so auto is not usable here. Containment is the disposable
checkout, as with kimi and opencode.
⚠ NOT a free tier. Every model is metered per token (Opus 5 at $5/$25 per MTok,
GLM-5.2 at $0.7/$2.2). Do not put this in a free-fallback rotation -- that is
what kiro and opencode's free models are for.
★ 37 families, and nearly all of them -- claude-*, gpt-*, gemini-*, grok-*,
kimi-*, glm-*, deepseek-*, nemotron-* -- are lineages other adapters here
already reach. Rostering those beside the adapter that owns them is one lineage
in two seats; cadre warns. What is genuinely only here is Cognition's own
swe-1.7 / swe-1.6 and inkling -- and measured on a free account, `--model
swe-1.7` answers "/upgrade to access this model". So the one thing this adapter
uniquely reaches is the one thing a free account cannot use. The default model
works. Weigh that before you spend a roster slot on it.
`devin models list` prints families with prices. --model takes a family slug, an
alias, or a model UID.
NOTES
}

run_devin() {
  local pf m=()
  [ -n "$model" ] && m=(--model "$model")
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" devin -p --permission-mode dangerous "${m[@]}" --prompt-file PROMPTFILE
    return 0
  fi
  pf=$(mktemp); printf '%s' "$prompt" > "$pf"
  ( cd "$dir" && timeout -k 30 "$TIMEOUT" devin -p --permission-mode dangerous \
      "${m[@]}" --prompt-file "$pf" 2>&1 )
  local rc=$?
  rm -f "$pf"
  return "$rc"
}
