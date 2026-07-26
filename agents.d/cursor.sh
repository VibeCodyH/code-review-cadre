# agentcall adapter: cursor  (Cursor Agent CLI)

notes_cursor() {
  cat <<'NOTES'
Prompt on STDIN even though --help shows it as a positional, so a big synthesis
stays off argv. --output-format json is ONE object, not an array: .result holds
the answer, .subtype and .is_error say whether to trust it.
★ -f/--force or tool calls are not approved and you get a confident review of a
diff it never opened. Same trap as opencode --auto and grok --always-approve.
★ HONORS ro: --mode plan is a real read-only mode, which most adapters here do
not have. It also nudges the model toward planning prose, so if reviews come
back shaped like proposals rather than findings, that is why.
★★ DECORRELATION WARNING, read before you roster it. Most of --list-models is
gpt-5.x, claude-*, and cursor-grok-*, which are the SAME model families as the
codex, claude and grok adapters. `--roster claude,cursor:claude-opus-5-thinking-high`
looks like two reviewers and is one lineage twice, which is the exact failure
this tool exists to avoid. The lineage you cannot get elsewhere is composer-2.5,
Cursor's own model. Prefer it, or pick a family no other roster slot covers.
⚠ Some models are marked NO ZDR in --list-models. Reviewers are shown your code.
Pick deliberately.
NOTES
}

run_cursor() {
  local out errf rc text sub err m=() md=()
  [ -n "$model" ] && m=(--model "$model")
  # A read-only mode that actually exists, so use it rather than relying on the
  # disposable checkout to absorb an edit.
  [ "$mode" = ro ] && md=(--mode plan)
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" agent -p --output-format json \
      --force --workspace "$dir" "${m[@]}" "${md[@]}"
    return 0
  fi
  out=$(mktemp); errf=$(mktemp)
  # stderr kept OUT of the JSON: this is a parsed stream, and one stray line
  # ahead of the object makes jq return nothing, which the adapter would then
  # report as a dead reviewer. Same reason as agents.d/qwen.sh.
  printf '%s' "$prompt" \
    | timeout -k 30 "$TIMEOUT" agent -p --output-format json \
        --force --workspace "$dir" "${m[@]}" "${md[@]}" > "$out" 2> "$errf"
  rc=$?
  text=$(jq -r '.result // ""' "$out" 2>/dev/null)
  sub=$(jq -r '.subtype // ""' "$out" 2>/dev/null)
  err=$(jq -r '.is_error // false' "$out" 2>/dev/null)

  if [ -z "$text" ]; then
    echo "DID NOT COMPLETE, no result in the response (exit $rc). Raw:"
    head -c 1000 "$errf"
    head -c 1000 "$out"
    rm -f "$out" "$errf"
    return 0
  fi

  echo "$text"
  rm -f "$out" "$errf"
  # The object carries its own verdict, so believe it over the exit code: a
  # response that says it errored still holds text worth keeping, and silence
  # about the rest of the diff is not a clean bill of health.
  if [ "$err" = true ] || { [ -n "$sub" ] && [ "$sub" != success ]; }; then
    echo
    echo "_TRUNCATED, cursor reported subtype=${sub:-unknown} is_error=$err; this review is INCOMPLETE, not a clean pass._"
    return 1
  fi
  [ "$rc" -ne 0 ] && return 1
  return 0
}
