# agentcall adapter: codex  (OpenAI Codex CLI)

notes_codex() {
  cat <<'NOTES'
-s read-only. Needs -o FILE or it streams its entire reasoning trace to
stdout (152KB measured on a 4-file diff) instead of the review.
Prompt goes on stdin via the trailing '-'.
★ Refuses to start outside a git repo without --skip-git-repo-check. The judge
and keygen steps run in a scratch dir, so without that flag codex-as-judge
fails on every call and every grade comes back UNUSABLE.
Builds differ: some have ONLY -s/--sandbox and error on
--ask-for-approval / --search. --print-command before you trust it.
★ Slow on whole-repo briefs. Measured: killed at the default 900s with the -o
file still empty, which the adapter used to return as an empty review. It now
reports the timeout. Raise CADRE_TIMEOUT for anything bigger than a diff.
NOTES
}

run_codex() {
  local last ro=() m=()
  [ "$mode" = ro ] && ro=(-s read-only)
  # Dropping $model runs the default and files it under the requested one. A
  # benchmark that mislabels what it measured is worse than one that refuses.
  [ -n "$model" ] && m=(-m "$model")
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" codex exec "${ro[@]}" "${m[@]}" --skip-git-repo-check -C "$dir" -o OUTFILE -
    return 0
  fi
  last=$(mktemp); : > "$last"
  printf '%s' "$prompt" | timeout -k 30 "$TIMEOUT" codex exec "${ro[@]}" "${m[@]}" --skip-git-repo-check -C "$dir" -o "$last" - >/dev/null 2>&1
  local rc=$?
  # ★ Measured here: the 900s default killed codex with -o still empty and the
  # adapter returned "". Downstream that reads as "found nothing", the worst
  # thing an adapter can do. Say what happened instead.
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    # ★ Killed, but -o may already hold review text. Printing only the timeout
    # line threw those findings away. Emit them, then _TRUNCATED: the review is
    # real but its silence about a file means "never got there", not "clean".
    # docs/ADDING-AN-AGENT.md, "Say which kind of nothing you have".
    if [ -s "$last" ]; then
      cat "$last"
      echo
      echo "_TRUNCATED, codex was killed at the ${TIMEOUT}s timeout; this review is INCOMPLETE, not a clean pass. Raise CADRE_TIMEOUT._"
    else
      echo "DID NOT COMPLETE, codex was killed at the ${TIMEOUT}s timeout with no output. Raise CADRE_TIMEOUT."
    fi
  elif [ ! -s "$last" ]; then
    echo "DID NOT COMPLETE, codex exited $rc and wrote no output."
  else
    cat "$last"
  fi
  rm -f "$last"
}
