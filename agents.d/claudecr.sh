# agentcall adapter: claudecr  (Claude Code's built-in /code-review, per effort level)

notes_claudecr() {
  cat <<'NOTES'
Runs Claude Code's own `/code-review <level>` skill headless in the checkout.
Takes NO prompt: the skill ships its own review strategy, and the level is the
whole point -- low = one pass over the diff, medium = read changed code in
context + several finder passes + verify each finding, high = finders and
verifiers as fresh-context subagents, xhigh = also sweeps for impact outside
the change. The level rides in the MODEL slot of the spec: claudecr:high.
No level is refused, not defaulted: a benchmark row that does not say which
strategy it measured is worse than one that refuses. `ultra` is not offered:
it is user-triggered, billed, and cloud-only.
★ Probed 2026-08-29 (claude 2.1.251) on a two-commit detached checkout with
no branch and no remote, i.e. exactly what run-review.sh builds:
  - `/code-review low` reviews HEAD against its parent and found the planted
    double-charge. That IS the change under review, by construction.
  - passing the base commit as a target (`/code-review low <sha>`) makes it
    review NOTHING and print "(none)": the skill reads a target as a path or
    PR, not a base. Never pass one.
  - the Skill tool being denied does not stop a slash command in -p mode.
  - with untracked files run-review.sh's checkout is THREE commits and the
    skill would see only the last; the adapter checks out a squashed
    two-commit view for the call and restores HEAD after.
`agentcall --probe claudecr` reports unclear: the generic probe passes no
level and a level is required. Probe by hand: agentcall claudecr -M low.
  - text after the slash command is honoured: the format contract below
    produced bold severity labels and a Verdict: line, which the classifier
    reads. Without it the output is bare `file:line -- text`, findings=0 and
    no verdict, filed inconclusive.
★ High and xhigh dispatch SUBAGENTS by design. That is the same class of
asymmetry codex.sh records for spawn_agent: a seat that consults other models
is not a peer of one that cannot. Recorded, not assumed away -- it is what
you are measuring when you pick this seat.
Same ro rails as claude.sh: --strict-mcp-config, advisorModel="", and the
CLAUDE_DENY list, which is why that adapter must stay loaded.
★ The seat inherits the CLI's DEFAULT model: the spec's model slot is spent
on the level, and --model is deliberately NOT added (#51, decided: record it,
don't control it). The adapter asks for --output-format json and reads the
served model out of `modelUsage`, then declares it with cadre_model, so the
run record and the slots.tsv row name what actually ran -- every model that
served, comma-joined, since high and xhigh dispatch subagents. A sweep whose
default model changes mid-run shows up as two rows in `cadre receipts`, not
as one averaged number. If the CLI's output is not the JSON object (older CLI,
no jq on the box), the text passes through as before and the field stays
EMPTY -- never a default. When a model's weekly tier runs out the CLI says
"You've reached your <Model> limit. Switch to another model to continue.",
which cadre reads as a usage window and not as a measurement (#48).
NOTES
}

# The binary is `claude`, not `claudecr`: without this, agentcall's installed
# check looks for a `claudecr` command and every dispatch is NOT INSTALLED.
bin_claudecr() { printf 'claude'; }

# The skill brings its own brief; the shared prompt is not delivered.
noprompt_claudecr() { :; }

cannot_claudecr() {
  # It ignores the prompt, so it cannot merge reviews or grade against a key,
  # and a security-audit brief never reaches it.
  echo role:synth
  echo role:judge
  echo prompt:security-audit
}

# ★ The one lever on the shape that arrives (issue #33, same as pi.sh): the
# classifier reads a bold severity label and a closing Verdict: line, and the
# skill's native output has neither.
claudecr_output_contract() {
  cat <<'CONTRACT'
Format contract: state each finding under a bold severity label on its own
line -- **blocking**, **should-fix**, or **nit** -- keep file:line references,
and end the whole review with a final line starting with `Verdict:` followed
by one of: blocking, should-fix, no defects found.
CONTRACT
}

run_claudecr() {
  local level="$model" ro=() rc out
  case "$level" in
    low|medium|high|xhigh) ;;
    '')  echo "DID NOT RUN, misconfigured: claudecr needs a level in the model slot (claudecr:low|medium|high|xhigh)"; return 0 ;;
    *)   echo "DID NOT RUN, misconfigured: claudecr level '$level' is not one of low|medium|high|xhigh"; return 0 ;;
  esac
  if [ "$mode" = ro ]; then
    # ★ Refuse rather than fail open: with CLAUDE_DENY unset the deny list
    # would be empty and Edit/Write/Agent/Workflow silently back in reach.
    [ -n "${CLAUDE_DENY:-}" ] || { echo "DID NOT RUN, misconfigured: CLAUDE_DENY is unset; agents.d/claude.sh must be loaded alongside claudecr"; return 0; }
    # shellcheck disable=SC2206
    ro=(--strict-mcp-config --settings '{"advisorModel":""}' --disallowedTools $CLAUDE_DENY)
  fi
  local arg; arg="/code-review $level"$'\n\n'"$(claudecr_output_contract)"
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" claude -p "$arg" --output-format json "${ro[@]}"
    return 0
  fi
  # ★ The skill reviews HEAD against its parent, and nothing else (probed: a
  # base passed as a target makes it review nothing). run-review.sh builds
  # base -> snapshot, but with untracked files it adds a third commit on top,
  # and HEAD^..HEAD would then be the untracked files alone, silently dropping
  # every tracked change. So when HEAD's parent is not the base, check out a
  # squashed view -- HEAD's tree on top of the base -- for the duration of the
  # call. This checkout is the seat's own disposable copy (run-review.sh gives
  # every reviewer its own and deletes it after), so moving HEAD costs nothing
  # and is restored anyway. Found by the codex review of this adapter.
  local orig="" base="${CADRE_PASS_BASE:-}" parent squash
  if [ -n "$base" ] && git -C "$dir" rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1; then
    parent=$(git -C "$dir" rev-parse -q --verify HEAD^ 2>/dev/null || true)
    if [ "$parent" != "$(git -C "$dir" rev-parse "$base")" ]; then
      orig=$(git -C "$dir" rev-parse HEAD)
      squash=$(git -C "$dir" -c user.name=cadre -c user.email=cadre@localhost -c commit.gpgsign=false                  commit-tree "HEAD^{tree}" -p "$base" -m "cadre: change under review (squashed for /code-review)")         && git -C "$dir" checkout -q --detach "$squash" 2>/dev/null         || { echo "DID NOT RUN, could not build the two-commit view /code-review needs in $dir"; return 1; }
    fi
  fi
  # < /dev/null: with nothing on stdin the CLI waits 3s and prints a warning
  # that would become line 1 of every review.
  # ★ JSON, for one field: `modelUsage` names the model(s) that actually served
  # the call, which is the only honest source for a seat that pins none (#51).
  # stderr is kept out of the object (a stray line ahead of it and jq sees
  # nothing, the cursor.sh rule) and appended afterwards, so a CLI error still
  # reaches the review text the way it did under 2>&1.
  local errf models; errf=$(mktemp)
  out=$( cd "$dir" && timeout -k 30 "$TIMEOUT" claude -p "$arg" --output-format json "${ro[@]}" < /dev/null 2>"$errf" ); rc=$?
  [ -n "$orig" ] && git -C "$dir" checkout -q --detach "$orig" 2>/dev/null
  # Anything that is not the result object passes through untouched: an older
  # CLI printing plain text, a box without jq. The model field stays EMPTY then,
  # which is the truth -- it was not determined.
  local err sub
  if command -v jq >/dev/null 2>&1 \
     && printf '%s' "$out" | jq -e 'type == "object" and has("result")' >/dev/null 2>&1; then
    models=$(printf '%s' "$out" | jq -r '(.modelUsage // {}) | keys | join(",")' 2>/dev/null)
    [ -n "$models" ] && cadre_model "$models"
    err=$(printf '%s' "$out" | jq -r '.is_error // false')
    sub=$(printf '%s' "$out" | jq -r '.subtype // "success"')
    out=$(printf '%s' "$out" | jq -r '.result // ""')
    # ★ The object carries its own verdict: an error that exited 0 is still an
    # error, and its text -- a usage-window notice, say -- must not be read as
    # a review that happens to lack findings.
    if [ "$rc" -eq 0 ] && { [ "$err" = true ] || [ "$sub" != success ]; }; then rc=1; fi
  fi
  # ★ Empty/partial is judged on what the CLI RETURNED, never on its stderr:
  # a diagnostic line on a clock kill is not a partial review.
  local diag=""; [ -s "$errf" ] && diag=$(cat "$errf"); rm -f "$errf"
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    # Whatever arrived before the kill is a review, cut short: the partial
    # contract, same as codex.sh and grok.sh. Nonzero as well as the marker.
    if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
      [ -n "$diag" ] && printf '%s\n' "$diag"
      printf '%s\n\n' "$out"
      echo "_TRUNCATED, claudecr:$level was killed at the ${TIMEOUT}s timeout; this review is INCOMPLETE, not a clean pass. Raise CADRE_TIMEOUT; high and xhigh run subagents and take longer._"
    else
      echo "DID NOT COMPLETE, claudecr:$level was killed at the ${TIMEOUT}s timeout with no output. Raise CADRE_TIMEOUT; high and xhigh run subagents and take longer."
      [ -n "$diag" ] && printf '%s\n' "$diag"
    fi
    return 1
  fi
  if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
    echo "DID NOT COMPLETE, claudecr:$level printed no review (exit $rc)."
    [ -n "$diag" ] && printf '%s\n' "$diag"
    return 1
  fi
  # stderr FIRST, as under 2>&1: the CLI's diagnostics precede its result, and
  # the Verdict: line the classifier reads at the tail stays last.
  [ -n "$diag" ] && printf '%s\n' "$diag"
  printf '%s\n' "$out"
  return "$rc"
}
