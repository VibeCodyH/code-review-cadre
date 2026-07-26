# agentcall adapter: grok  (xAI Grok CLI)

notes_grok() {
  cat <<'NOTES'
★ -p is --single and CONSUMES the next argument, so it must come last.
★ Without --always-approve every tool call is SILENTLY cancelled headless:
you get progress narration, stopReason "Cancelled", and output that is
indistinguishable from a lazy short review. That cost two graded rounds.
--sandbox no-ops headless. Adapter reads .text out of --output-format json
and shouts when the run stopped early rather than returning a quiet pass.
NOTES
}

run_grok() {
  local out stop text m=()
  [ -n "$model" ] && m=(--model "$model")
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" grok --cwd "$dir" "${m[@]}" \
      --always-approve --no-auto-update --no-alt-screen \
      --output-format json -p "$prompt"
    return 0
  fi
  out=$(mktemp)
  ( cd "$dir" && timeout -k 30 "$TIMEOUT" grok --cwd "$dir" "${m[@]}" \
      --always-approve --no-auto-update --no-alt-screen \
      --output-format json -p "$prompt" ) > "$out" 2>&1
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
      *) echo; echo "_TRUNCATED, grok stopped early (stopReason=$stop); this review is INCOMPLETE, not a clean pass._" ;;
    esac
  fi
  rm -f "$out"
}
