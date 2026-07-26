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
  # ★ Strip opencode's own chrome: colour escapes and a "> build <model>"
  # banner it prints around the model's text. Left in, a run that returned NO
  # review is still a non-empty file, so it is filed as a clean review by a
  # reviewer that found nothing. Only the adapter knows which lines are the
  # CLI talking rather than the model, so it belongs here. classify_run has a
  # backstop for the same shape, since every CLI does some version of this.
  # ★ The banner delete is anchored HARD: only in the first few lines, and only
  # with opencode's " · " separator. `/^> build /d` alone ate a reviewer's own
  # markdown blockquote -- "> build the release pipeline silently fails" -- which
  # is silent loss of review content, worse than the chrome it was removing.
  # ★ A literal escape byte, not `\x1b`, and the brace block split across -e
  # fragments: both `\x1b` and `{cmd;}` on one line are GNU sed extensions, so
  # on BSD sed (macOS) the strip silently matched nothing and the banner delete
  # errored. lib/common.sh carries the same fix and the same reason.
  # ★ Prompt on STDIN, not argv. `opencode run` takes the message as a
  # positional and Linux caps ONE argv entry near 128KB (MAX_ARG_STRLEN), well
  # under the 2MB total ARG_MAX -- so this adapter died on a big prompt with
  # `Argument list too long` from timeout, an error naming neither opencode nor
  # the cause. Measured on the sibling case: a 184KB synthesis over a 3-reviewer
  # panel. Reviews are small and never hit it; SYNTHESIS is the whole panel
  # concatenated, so the failure lands exactly when merging matters most, and
  # opencode is the free route the README sends people down first.
  local esc; esc=$(printf '\033')
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" opencode run --dir "$dir" "${om[@]}" --auto
    return 0
  fi
  printf '%s' "$prompt" \
    | timeout -k 30 "$TIMEOUT" opencode run --dir "$dir" "${om[@]}" --auto 2>&1 \
    | sed -e "s/${esc}\[[0-9;]*[a-zA-Z]//g" -e '1,5{' -e '/^> build · /d' -e '}'
}
