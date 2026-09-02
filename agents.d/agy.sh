# agentcall adapter: agy  (Antigravity CLI)

# Machine-checkable incapability. cadre preflight / dispatch refuse a doomed
# seat before spending tokens. See docs/ADDING-AN-AGENT.md.
cannot_agy() {
  # A broad "audit this codebase for vulnerabilities" brief comes back as a
  # refusal, not a review. Scoped security wording on a bounded target is fine;
  # the check only matches audit-shaped briefs, not "security" in a priority list.
  echo "prompt:security-audit"
}

notes_agy() {
  cat <<'NOTES'
★ Fronts THREE vendor lineages, not just Gemini: `agy models` lists
gemini-3.{1,5,6}-*, claude-sonnet-4-6, claude-opus-4-6-thinking, and
gpt-oss-120b-medium. Probed 2026-08-02 -- three flag values returned three
distinct vendor self-reports (Google / Anthropic / OpenAI), so --model really
does switch backends. Vendor routing is MEASURED; the version digit is
VENDOR-ASSERTED only. claude-sonnet-4-6 self-reports "claude-sonnet-4-5-20251219",
which is a model being wrong about itself rather than evidence of misrouting --
there is no external probe for the version, so do not file version claims as
measured. --effort applies to the gemini slots ONLY (it is encoded in their
-high/-medium/-low ids); the other three hard-error "--effort is not supported".

★★ THE TRAP THAT POISONS A RUN: `-p` takes the prompt as an ARGV ARGUMENT, so
`agy -p --model X` makes the literal string "--model" the prompt, silently
swallows the flag, and runs the DEFAULT model (Gemini 3.6 Flash High) while the
result gets filed under X. Measured -- it answered "the currently active model
is Gemini 3.6 Flash (High)". This adapter therefore always passes a non-empty
instruction string to -p. Never write a bare -p in front of a flag here. A bad
model id is safe by contrast: the CLI hard-fails with status ERROR and prints
the available list rather than falling back.

★ Prompt transport is a FILE, not argv and not stdin. Both alternatives are
dead ends: a 150KB single argv entry dies at the shell with "argument list too
long" (MAX_ARG_STRLEN, the same ~128KB wall that killed grok as synthesizer),
and stdin is simply NOT INGESTED -- piping text in and asking the model to
repeat a codeword from it returns NONE. So the adapter writes the prompt to a
temp dir, adds that dir to the workspace, and passes a short argv pointer at it.
Measured good to 140KB.

★ `cd` does NOT set the workspace; --add-dir does. An earlier version of this
adapter cd'd into the checkout and concluded agy's classifier was blocking
headless repo reads. It was not -- with no workspace set, agy asks which
directory you mean. Given --add-dir plus --dangerously-skip-permissions it reads
a checkout fine, which is what promoted this seat from grading-only to a
REVIEWER. --add-dir is repeatable, so the prompt file stays out of the checkout.

★ The old "refuses security-flavoured analysis" limit was misdiagnosed too. The
refusal tracks SCOPE, not subject: "audit this codebase for vulnerabilities"
against a 411k-line repo comes back as a deflection naming context limits and
offering to narrow, while the SAME security wording aimed at a bounded target
("check the API routes for missing auth, hardcoded secrets, weak input
validation") runs without complaint and returns real findings. Keep review
prompts scoped and this seat does security work fine.

⚠️ ro IS UNENFORCED. --mode plan does NOT block writes: under plan mode it still
created the file it was told to create (measured). There is no --disallowed-tools
equivalent, and --dangerously-skip-permissions is required for it to read at all,
so this seat can edit, write, and shell out in EVERY mode. The only containment
is that cadre hands adapters a disposable checkout. Do not cite this seat's runs
as read-only, and do not point it at a live working tree by hand.

⚠️ COMPARABILITY: this seat receives its prompt BY REFERENCE. Every other
adapter hands the model the brief directly; this one hands it a path and asks it
to go read it, because argv and stdin are both closed. That is a delivery
difference applied to agy seats and to nobody else in the corpus, so if an agy
score sits next to a direct-delivery score, the gap includes however much the
indirection costs in instruction-following. Measured once already: the pointer's
original closing sentence suppressed the brief's own verdict line.

⚠️ It wanders. Given a loose target it has read files outside the directory it
was pointed at. Scope it with --add-dir and keep the prompt specific.

★ Flaky close: the print stream sometimes ends status=ERROR with the full review
already written. The adapter retries the same model up to CADRE_AGY_RETRIES (3)
times, never past cadre's clock or agy's own; the count lands in runs.jsonl as
adapter_attempts. Read adapter_attempts>1 as a transport retry, not a second review.

Line attribution runs about one off (reported 860 lines for an 859-line file),
so sanity-check its file:line citations before grading it on them.
NOTES
}

run_agy() {
  local pd pf out status text rc=0 m=() ptr
  [ -n "$model" ] && m=(--model "$model")

  # The prompt lives in its own temp dir, added to the workspace alongside the
  # checkout, so a panel-sized prompt never touches argv and never lands in the
  # tree under review.
  pd=$(mktemp -d "${TMPDIR:-/tmp}/cadre-agy.XXXXXXXX") || {
    echo "DID NOT RUN, cannot create a temp dir for the prompt file."; return 0; }
  pf="$pd/PROMPT.md"
  printf '%s' "$prompt" > "$pf"
  # ★ The pointer must not compete with the brief. An earlier version ended
  # "Reply with the finished result only", and the first graded run came back
  # INCONCLUSIVE with no verdict line -- review-live.md asks reviewers to END
  # with a one-line verdict, which is exactly what "the finished result only"
  # reads as trailing chatter. Keep this wording deferential to the file, and
  # say out loud that its formatting instructions bind.
  ptr="Read the file $pf. Its contents are your complete task. Follow every instruction in it exactly, including anything it says about your output format and how your reply should end."

  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" agy -p "$ptr" "${m[@]}" \
      --add-dir "$dir" --add-dir "$pd" \
      --dangerously-skip-permissions --output-format json
    rm -rf "$pd"
    return 0
  fi

  out=$(mktemp)
  # ★ --print-timeout defaults to 5m0s, INSIDE whatever cadre allows. Measured:
  # a 900s TIMEOUT bought nothing because agy gave up on itself at 297s and
  # returned status=ERROR "timeout waiting for response" with 13k output tokens
  # already generated and discarded. The outer `timeout` never fired, so this
  # read as a model failure rather than a clock. Align them, and leave the outer
  # one as the backstop for a CLI that hangs without honouring its own flag.
  #
  # ★ And it FLAKES. The print stream intermittently ends status=ERROR ("timeout
  # waiting for response") with a complete review already in .response, minutes
  # inside both clocks. Measured twice: 2026-08-19 (ERROR at 185s, identical
  # retry SUCCESS at 155s) and 2026-09-02 (ERROR at 425s, retry SUCCESS at
  # 390s; 1 flake in 13 calls). Under runs=1 that flake zeroes the pass and
  # `cadre run` aborts the whole sweep on it (exit 4), so an unattended agy
  # sweep could not finish. Retry the SAME model on the SAME prompt when the run
  # did not end SUCCESS, with two exclusions that keep a retry from masking
  # something real: the outer clock fired (rc >= 124: cadre's timeout, a hang,
  # not a flake), or agy's own clock did (the attempt ran out most of TIMEOUT,
  # so another attempt just triples the wait). A refusal comes back as SUCCESS
  # text and is never retried. Attempts are recorded over the meta channel and
  # land in runs.jsonl as adapter_attempts, never on stderr: run-pass merges
  # stderr into the review and a judge would read it.
  local attempt=0 max="${CADRE_AGY_RETRIES:-3}" t0
  # A knob that is not a whole number would print bash's arithmetic diagnostic
  # INTO the review and never satisfy -ge; fall back to the default instead.
  case "$max" in ''|*[!0-9]*) max=3 ;; esac
  while :; do
    attempt=$((attempt + 1)); t0=$SECONDS
    timeout -k 30 "$TIMEOUT" agy -p "$ptr" "${m[@]}" \
      --add-dir "$dir" --add-dir "$pd" --print-timeout "${TIMEOUT}s" \
      --dangerously-skip-permissions --output-format json >"$out" 2>/dev/null
    rc=$?
    status=$(jq -r '.status // "MISSING"' "$out" 2>/dev/null)
    [ "$status" = SUCCESS ] && break
    [ "$rc" -ge 124 ] && break
    [ $((SECONDS - t0)) -ge $((TIMEOUT * 9 / 10)) ] && break
    [ "$attempt" -ge "$max" ] && break
  done
  # Generic key: run-pass / run-review copy it onto the complete record as
  # adapter_attempts, beside the harness's own rate-limit `attempts`.
  [ -n "${CADRE_RUN_META:-}" ] && printf 'attempts=%s\n' "$attempt" >> "$CADRE_RUN_META"

  text=$(jq -r '.response // ""' "$out" 2>/dev/null)

  if [ -n "$text" ] && [ "$status" = SUCCESS ]; then
    printf '%s\n' "$text"
    rc=0
  elif [ -n "$text" ]; then
    # Text in hand but the run did not end clean. Its findings still count; its
    # SILENCE must not. Marker for the reviewer slot, nonzero exit for the synth
    # slot -- see docs/ADDING-AN-AGENT.md.
    printf '%s\n' "$text"
    echo
    echo "_TRUNCATED, agy ended with status=$status (exit $rc); this review is INCOMPLETE, not a clean pass._"
    rc=1
  else
    # Empty output reads downstream as "reviewer found nothing", which is the
    # worst thing this adapter can say. Name the failure instead.
    if [ "$rc" -ge 124 ]; then
      echo "DID NOT COMPLETE, agy hit the ${TIMEOUT}s timeout with no text returned."
    else
      echo "DID NOT COMPLETE, no text returned (status=$status, exit $rc). Raw:"
      head -c 2000 "$out"
    fi
    rc=1
  fi

  rm -f "$out"; rm -rf "$pd"
  return "$rc"
}
