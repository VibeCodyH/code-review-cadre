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

run_grok() {
  local out pf stop text trunc=0 m=() ro=()
  [ -n "$model" ] && m=(--model "$model")
  # ★ ro was previously UNENFORCED here: --always-approve was passed in every
  # mode, so a "read-only" review could edit, write, and shell out. Its
  # --sandbox flag no-ops headless, so the deny-list is the only thing that
  # actually holds. Found alongside the claude adapter's ro being decorative --
  # the same bug in two of three adapters, while codex had a real -s read-only
  # sandbox the whole time. An unenforced mode is worse than no mode: it reads
  # as a guarantee in every report that cites it.
  [ "$mode" = ro ] && ro=(--disallowed-tools 'edit,write,bash')
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" grok --cwd "$dir" "${m[@]}" "${ro[@]}" \
      --always-approve --no-auto-update --no-alt-screen \
      --output-format json --prompt-file PROMPTFILE
    return 0
  fi
  pf=$(mktemp); printf '%s' "$prompt" > "$pf"
  out=$(mktemp)
  ( cd "$dir" && timeout -k 30 "$TIMEOUT" grok --cwd "$dir" "${m[@]}" "${ro[@]}" \
      --always-approve --no-auto-update --no-alt-screen \
      --output-format json --prompt-file "$pf" ) > "$out" 2>&1
  rm -f "$pf"
  stop=$(jq -r '.stopReason // "unknown"' "$out" 2>/dev/null)
  text=$(jq -r '.text // ""' "$out" 2>/dev/null)
  if [ -z "$text" ]; then
    # Bad JSON or no text. Surface the raw output. An empty string reads
    # downstream as "reviewer found nothing".
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
