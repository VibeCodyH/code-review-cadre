# agentcall adapter: qwen  (Qwen Code CLI)

notes_qwen() {
  cat <<'NOTES'
Prompt on STDIN, which is what its own docs recommend and what keeps a big
synthesis off argv (see docs/ADDING-AN-AGENT.md). -p appends to stdin rather
than replacing it, so do not pass both.
★ --yolo or every tool call is denied and you get a confident review of a diff
it never opened. Same trap as opencode --auto and grok --always-approve.
--output-format json is an ARRAY of messages; the answer is the last one with
type=="result". 130 is SIGINT.
⚠ The documented budget exits (53 --max-session-turns, 55 wall-time/tool-calls)
look like they should produce a PARTIAL review, and they do not. Measured on
0.21.0: hitting the turn cap replaces the whole array with a bare
{"error":{...,"code":53}} and no result message, so there is nothing to salvage
and it correctly lands in `failed`. The 53/55 branch below is kept for a future
version that emits both, and is unreachable today -- do not read it as evidence
qwen can produce a degraded reviewer. It cannot, same as every adapter here
except grok.
NOTES
}

run_qwen() {
  local out errf rc text sub err m=()
  [ -n "$model" ] && m=(--model "$model")
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" qwen "${m[@]}" --yolo --output-format json
    return 0
  fi
  out=$(mktemp); errf=$(mktemp)
  # ★ stderr goes to its OWN file, not 2>&1 into the JSON. Every other adapter
  # here merges them because their output is prose and the extra lines are just
  # noise; this one is a parsed stream, and one warning line ahead of the array
  # makes jq fail, which the adapter then reports as "no result" -- a working
  # reviewer filed as a dead one. Measured: the yolo notice does exactly that.
  # The env var is qwen's own documented way to silence it; cadre is not
  # sandboxing either way, and each reviewer gets a disposable checkout.
  #
  # No working-directory flag exists, so cd. That disposable checkout is also
  # why the missing read-only mode is survivable: the worst it can edit is a
  # copy cadre is about to delete.
  ( cd "$dir" && printf '%s' "$prompt" \
      | QWEN_CODE_SUPPRESS_YOLO_WARNING=1 timeout -k 30 "$TIMEOUT" \
        qwen "${m[@]}" --yolo --output-format json ) > "$out" 2> "$errf"
  rc=$?
  text=$(jq -r 'if type=="array" then ([.[] | select(.type=="result")] | last | .result // "") else "" end' "$out" 2>/dev/null)
  sub=$(jq -r 'if type=="array" then ([.[] | select(.type=="result")] | last | .subtype // "") else "" end' "$out" 2>/dev/null)
  err=$(jq -r 'if type=="array" then ([.[] | select(.type=="result")] | last | .is_error // false) else false end' "$out" 2>/dev/null)

  if [ -z "$text" ]; then
    # No parseable answer. Say so and show what came back: an empty string reads
    # downstream as a reviewer that looked and found nothing. stderr first --
    # when qwen refuses (auth, quota, a bad model name) the reason is there and
    # the JSON is absent, which is the case worth diagnosing.
    echo "DID NOT COMPLETE, no result message (exit $rc). Raw:"
    head -c 1000 "$errf"
    head -c 1000 "$out"
    rm -f "$out" "$errf"
    return 0
  fi

  echo "$text"
  rm -f "$out" "$errf"
  # ⚠ UNREACHABLE on 0.21.0 and kept anyway. A budget exit currently replaces
  # the whole message array with a bare error object, so $text is empty and the
  # branch above already returned. If a later qwen emits the result message AND
  # the budget code -- which is the shape the docs imply -- this keeps the
  # partial review instead of discarding it. Nonzero as well as the marker,
  # because a synthesizer's marker cannot be trusted: a merge is asked to quote
  # truncated reviewers. See docs/ADDING-AN-AGENT.md. Do not cite this branch as
  # working; it has never fired.
  case "$rc" in
    53|55)
      echo
      echo "_TRUNCATED, qwen stopped at a run budget (exit $rc); this review is INCOMPLETE, not a clean pass._"
      return 1 ;;
  esac
  # A result message can carry an error while still holding text worth keeping.
  if [ "$err" = true ] || { [ -n "$sub" ] && [ "$sub" != success ]; }; then
    echo
    echo "_TRUNCATED, qwen reported subtype=${sub:-unknown} is_error=$err; this review is INCOMPLETE, not a clean pass._"
    return 1
  fi
  return 0
}
