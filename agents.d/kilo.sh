# agentcall adapter: kilo  (opencode fork, multi-provider front-end)

notes_kilo() {
  cat <<'NOTES'
Kilo is an opencode fork, so this adapter is opencode.sh with two measured
divergences. Its gateway reaches lineages opencode's own free tier does not --
poolside/laguna, stepfun/step-3.7, cohere/north-mini-code -- which is the point:
a model family your other CLIs cannot get to, see docs/METHOD.md. Spec is
kilo:kilo/<provider>/<model>, e.g. kilo:kilo/stepfun/step-3.7-flash:free (the
model half keeps its own `:free` suffix; cadre splits agent from model on the
FIRST colon, so the suffix survives -- verified).
★ --auto is required or tool calls are DENIED headless and you get a confident
review of a diff the model never opened. Measured: with --auto, laguna Glob'd
and Read the file and caught a planted bug; the flag is load-bearing.
★ The banner verb is `> code · <model>`, not opencode's `> build · <model>` --
kilo's default agent is named `code`. A clean copy of opencode.sh leaves that
banner in, and a run that returned NO review is then a non-empty file filed as a
clean review by a reviewer that found nothing. That single word is the whole
divergence that matters.

★★ MEASURED (2026-08-14, `cadre run` over the 12 keyed passes, runs=1, judges
grok+codex): the three current free lineages are CODEGEN-CAPABLE BUT NOT USABLE
PANEL REVIEWERS as of this date. All three write correct code on a toy prompt;
none holds a reviewer seat. Reported as reliability, then accuracy:
 - poolside/laguna-s-2.1:free -- 0/12 scorable. Every pass FAILED at the 900s
   ceiling (rc=124). Mechanism is RUNAWAY TOOL-USE, not slow first token: the
   .failed artifact is the model running `node`, reproducing the diff, and
   dumping stdio until the timeout kills it, never converging to a review. A
   longer TIMEOUT likely just runs longer. Reviewer-unusable as configured.
 - stepfun/step-3.7-flash:free -- ~2-3/12 scorable, 0/2 blocking key items HIT.
   INCONSISTENT: on the passes that scored, BOTH judges independently read
   "no defects found" on code with a planted bug. On ref-execa-allignore it
   produced a review that DID nail K1 (two consumers of one readable -> `all`
   empty) -- but that run was classed `inconclusive` (unscored): the finding was
   buried in a 1651-line tool/execution transcript with no bottom-line verdict.
   So it CAN review deeply and CANNOT reliably emit the verdict the panel needs.
 - cohere/north-mini-code:free -- ~6/12 scorable (most complete of the three),
   0/4 blocking key items HIT, no UNRESOLVED splits (two-judge agreement on every
   MISS). Failure mode is a FIREHOSE of 10-26 unranked out-of-key "extras" per
   pass while missing the planted defect. Verbose false-positives, low signal.
Do not put these on the free-panel table as recommended seats. This is the
result, per docs/ADDING-AN-AGENT.md: a CLI that turns out not to be a reviewer
is worth keeping with the finding written down so nobody re-derives it.
NOTES
}

run_kilo() {
  local om=()
  [ -n "$model" ] && om=(-m "$model")
  # ★ Strip kilo's chrome: colour escapes and a "> code · <model>" banner it
  # prints around the model's text. Left in, a run that returned NO review is
  # still a non-empty file, so it is filed as a clean review by a reviewer that
  # found nothing. Only the adapter knows which lines are the CLI talking rather
  # than the model, so it belongs here. classify_run has a backstop for the same
  # shape, since every CLI does some version of this.
  # ★ The banner delete is anchored HARD: only in the first few lines, and only
  # with kilo's " · " separator. Deleting `/^> code /` unanchored would eat a
  # reviewer's own markdown blockquote -- "> code that silently fails" -- which
  # is silent loss of review content, worse than the chrome it was removing.
  # ★ A literal escape byte, not `\x1b`, and the brace block split across -e
  # fragments: both `\x1b` and `{cmd;}` on one line are GNU sed extensions, so on
  # BSD sed (macOS) the strip silently matched nothing and the banner delete
  # errored. lib/common.sh and agents.d/opencode.sh carry the same fix.
  # ★ Prompt on STDIN, not argv. Linux caps ONE argv entry near 128KB
  # (MAX_ARG_STRLEN), well under the 2MB total ARG_MAX, so a big synthesis prompt
  # dies with `Argument list too long` naming neither kilo nor the cause. kilo
  # `run` takes stdin (verified) even though its help documents a positional.
  local esc; esc=$(printf '\033')
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" kilo run --dir "$dir" "${om[@]}" --auto
    return 0
  fi
  printf '%s' "$prompt" \
    | timeout -k 30 "$TIMEOUT" kilo run --dir "$dir" "${om[@]}" --auto 2>&1 \
    | sed -e "s/${esc}\[[0-9;?]*[a-zA-Z]//g" -e '1,5{' -e '/^> code · /d' -e '}'
}
