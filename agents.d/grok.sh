# agentcall adapter: grok  (xAI Grok CLI)

notes_grok() {
  cat <<'NOTES'
★ The prompt goes in a file via --prompt-file, NOT on argv. -p/--single takes
it as an ARGUMENT, and Linux caps a single argv entry at ~128KB
(MAX_ARG_STRLEN), well under the 2MB total ARG_MAX. Measured: grok as the
SYNTHESIZER over a 179KB panel died with "Argument list too long" before the
model ran -- exactly when merging matters most, since that is a panel that
produced a lot of text.
★ Without --always-approve every tool call is SILENTLY cancelled headless:
you get progress narration, stopReason "Cancelled", and output that is
indistinguishable from a lazy short review. That cost two graded rounds.
--sandbox no-ops headless. Adapter reads .text out of --output-format json
and shouts when the run stopped early rather than returning a quiet pass.
NOTES
}

# ★ grok executes the OPERATOR's Claude hooks. It reads ~/.claude/settings.json
# AND settings.local.json through its Claude-compat path, despite its own hook
# discovery logging total_hooks=0. Measured: a PostToolUse hook of Cody's ran 28
# times inside one review. Every call failed (`command not found`) so no corpus
# run was contaminated -- but that is luck, not containment. A UserPromptSubmit
# hook that emits text would inject operator context into every grok review and
# leave no trace in the review itself. Same class as claude's advisor: capability
# the benchmark never declared, arriving through a door nobody opened on purpose.
#
# CLAUDE_CONFIG_DIR does NOT close it (tested: hooks still ran, both settings
# files still read). A HOME with no .claude in it does, and grok keeps its auth
# and session history because .grok is symlinked back in.
grok_sandbox_home() {
  local h="${XDG_CACHE_HOME:-$HOME/.cache}/cadre/grok-home"
  mkdir -p "$h" || return 1
  [ -e "$h/.grok" ] || ln -sfn "$HOME/.grok" "$h/.grok"
  printf '%s' "$h"
}

# ★ A FINISHED review can still come back empty (#62). Measured on the private
# review bot this was built for, at 329d8e0, 2026-09-05: grok's session log has the final
# assistant message -- verdict written -- at 14:18:17, and the CLI had not
# emitted its JSON by the 900s kill at 14:19:33. The adapter saw no text and
# filed DID NOT COMPLETE over a complete review. Other grok runs on the same
# box take 515-754s, so the clock is tight for this seat, but raising it only
# moves the cliff. The log is the record that survives a slow exit.
#
# The session is pinned to a UUID cadre generates (--session-id), so the log
# is found by name rather than by guessing "newest directory" -- which under
# --jobs is another seat's. The turn is read back ONLY when events.jsonl says it
# ENDED and COMPLETED: a log whose last turn is still open, or ended in error
# or cancelled (both in the corpus), is a review that really was cut off, and
# stays DID NOT COMPLETE.
grok_session_id() {
  cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || true
}

# grok_recover <sessions-root> <session-id>: the final assistant text of a
# turn the CLI itself recorded as completed, or nothing (exit 1).
grok_recover() {
  local d text
  d=$(find "$1" -mindepth 2 -maxdepth 2 -type d -name "$2" 2>/dev/null | head -1)
  [ -n "$d" ] && [ -s "$d/chat_history.jsonl" ] && [ -s "$d/events.jsonl" ] || return 1
  tail -1 "$d/events.jsonl" \
    | jq -e '.type == "turn_ended" and .outcome == "completed"' >/dev/null 2>&1 || return 1
  # The LAST assistant entry, and only if it is a text turn: one carrying
  # tool_calls is the model mid-work, whatever the events file says.
  text=$(jq -rs '[.[] | select(.type == "assistant")] | last | select(. != null)
                 | select(((.tool_calls // []) | length) == 0 and (.content | type) == "string")
                 | .content' "$d/chat_history.jsonl" 2>/dev/null)
  [ -n "$text" ] || return 1
  printf '%s\n' "$text"
}


run_grok() {
  local out pf stop text trunc=0 m=() ro=() sbh sid sopt=()
  sbh=$(grok_sandbox_home) || sbh="$HOME"
  sid=$(grok_session_id); [ -n "$sid" ] && sopt=(--session-id "$sid")
  [ -n "$model" ] && m=(--model "$model")
  # ★ ro was previously UNENFORCED here: --always-approve was passed in every
  # mode, so a "read-only" review could edit, write, and shell out. Its
  # --sandbox flag no-ops headless, so the deny-list is the only thing that
  # actually holds. Found alongside the claude adapter's ro being decorative --
  # the same bug in two of three adapters, while codex had a real -s read-only
  # sandbox the whole time. An unenforced mode is worse than no mode: it reads
  # as a guarantee in every report that cites it.
  # bash stays ALLOWED (the review prompt sanctions running targeted tests, and
  # grok demonstrably used it -- `tsc --noEmit` -- in graded passes). What must
  # go is the SECOND MODEL: grok ships subagents ON by default (--agents,
  # --no-subagents), the same class of hole as claude's advisor. No grok review
  # in the corpus shows subagent use, so its existing numbers stand; this closes
  # the door for future runs.
  # ★ The REAL tool names (#62). `edit` and `write` were the names claude uses;
  # grok's built-ins are search_replace, write, read_file, grep, search_tool,
  # list_dir, run_terminal_command (every one observed in its session logs),
  # and a ro review on the live bot created files under /tmp via
  # search_replace with the old list in force. --disallowed-tools removes
  # built-ins BY NAME and says nothing about a name it does not have, so a deny
  # list of aliases is no deny list at all. Not verified against a live grok
  # call when written: the balance was out (402). The names are from the logs.
  [ "$mode" = ro ] && ro=(--disallowed-tools 'search_replace,write' --no-subagents)
  if [ -n "$DRY" ]; then
    _run env HOME="$sbh" timeout -k 30 "$TIMEOUT" grok --cwd "$dir" "${m[@]}" "${ro[@]}" \
      --session-id SESSIONID --always-approve --no-auto-update --no-alt-screen \
      --output-format json --prompt-file PROMPTFILE
    return 0
  fi
  pf=$(mktemp); printf '%s' "$prompt" > "$pf"
  out=$(mktemp)
  ( cd "$dir" && HOME="$sbh" timeout -k 30 "$TIMEOUT" grok --cwd "$dir" "${m[@]}" "${ro[@]}" "${sopt[@]}" \
      --always-approve --no-auto-update --no-alt-screen \
      --output-format json --prompt-file "$pf" ) > "$out" 2>&1
  rm -f "$pf"
  stop=$(jq -r '.stopReason // "unknown"' "$out" 2>/dev/null)
  text=$(jq -r '.text // ""' "$out" 2>/dev/null)
  if [ -z "$text" ] && [ -n "$sid" ] && text=$(grok_recover "$sbh/.grok/sessions" "$sid"); then
    # A completed turn the CLI never returned: the review, with the recovery
    # on the record. No stopReason to read, so no _TRUNCATED contract to apply;
    # the log's own turn_ended/completed is the stop evidence, and the text
    # goes through classify_run like any other clean exit.
    [ -n "${CADRE_RUN_META:-}" ] && printf 'note=%s\n' \
      "recovered from grok session log $sid; the CLI returned no JSON (stopReason=$stop)" >> "$CADRE_RUN_META"
    echo "$text"
  elif [ -z "$text" ]; then
    # Bad JSON or no text, and no completed turn in the log. Surface the raw
    # output. An empty string reads downstream as "reviewer found nothing".
    echo "DID NOT COMPLETE, no text returned (stopReason=$stop). Raw:"
    head -c 2000 "$out"
  else
    echo "$text"
    # Success is exactly "EndTurn" (measured). Case-insensitive: a false
    # "incomplete" is as damaging as a missed truncation.
    case "$(printf '%s' "$stop" | tr 'A-Z' 'a-z')" in
      endturn|end_turn|completed|stop|"") ;;
      # ★ Marker AND a nonzero exit, because the marker alone cannot be read in
      # every context. As a REVIEWER the marker decides and this rc is ignored.
      # As a SYNTHESIZER the marker cannot decide: the synthesis is supposed to
      # discuss truncated reviewers, so its own text may legitimately end in a
      # quoted _TRUNCATED line, and a text check there bins a good merge. The
      # exit status says the same thing in a channel the model cannot forge.
      # See docs/ADDING-AN-AGENT.md: text alone qualifies an adapter for a
      # reviewer slot, not a synth slot.
      *) echo; echo "_TRUNCATED, grok stopped early (stopReason=$stop); this review is INCOMPLETE, not a clean pass._"
         trunc=1 ;;
    esac
  fi
  rm -f "$out"
  return "$trunc"
}
