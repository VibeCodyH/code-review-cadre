# agentcall adapter: opencode  (multi-provider front-end)

notes_opencode() {
  cat <<'NOTES'
Multi-provider front-end: -M is provider/model (`opencode models`), so ONE
adapter can occupy several distinct reviewer slots via agent:provider/model.
This is the cheapest way to add a model lineage your other CLIs cannot reach,
which is what decorrelation needs, see docs/METHOD.md.
★ --auto is required or tool calls are denied and you get a confident review
of a diff it never opened.
NOTES
}

run_opencode() {
  local om=()
  [ -n "$model" ] && om=(-m "$model")
  _run timeout -k 30 "$TIMEOUT" opencode run --dir "$dir" "${om[@]}" --auto "$prompt" 2>&1
}
