#!/usr/bin/env bash
# Collect reviewer outputs for ONE pass. Same prompt, same checkout, no scoring.
#
#   run-pass.sh <label> <sha> <runs> <agent-spec ...>
#
#   CADRE_PASS_DIR    checkout to review, already at <sha>. Required.
#   CADRE_PASS_BASE   rev the target is diffed against (default HEAD~1).
#   CADRE_PROMPT_FILE replace the brief entirely (whole-feature review).
#   CADRE_STACK       one line of context added to the brief.
#   CADRE_TEST_CMD    override the detected test command.
#
# Outputs: $CADRE_HOME/<label>/<agent-slug>-run<N>.md
set -uo pipefail

LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CADRE_ROOT="${CADRE_ROOT:-$(dirname "$LIB_DIR")}"
# shellcheck source=lib/common.sh
. "$LIB_DIR/common.sh"

label="${1:?usage: run-pass.sh <label> <sha> <runs> <agent-spec ...>}"
sha="${2:?need a sha}"
runs="${3:-1}"
shift 3 2>/dev/null || shift $#
reviewers=("$@")
[ ${#reviewers[@]} -gt 0 ] || die "no reviewers given"
for reviewer in "${reviewers[@]}"; do
  case "$reviewer" in *\?*) die "seat gates are for 'cadre review'; a graded pass needs every seat present" ;; esac
done

CHECKOUT="${CADRE_PASS_DIR:?CADRE_PASS_DIR must point at the checkout to review}"
BASE="${CADRE_PASS_BASE:-HEAD~1}"
export CADRE_PASS_BASE="$BASE"   # adapters that need it (coderabbit) read this

OUT="$CADRE_HOME/$label"
# ★ Same record shape and the same name as the panel path's (lib/run-review.sh).
# The benchmark side had NO record at all: grade.sh reconstructed every run's
# state by probing which suffix existed on disk -- .failed, .partial,
# .inconclusive -- which is a state machine encoded in filenames and cannot
# carry a duration, an exit code or a prompt size at all. One record shape for
# both callers, so a consumer does not need to know which command produced a run.
RUNLOG="$OUT/runs.jsonl"

# Outputs must not land inside the reviewed tree or reviewer #1's findings
# become reviewer #2's input. docs/METHOD.md §5.
# readlink -m, not -f: this runs before mkdir, so OUT does not exist yet.
out_abs=$(readlink -m "$OUT"); chk_abs=$(readlink -m "$CHECKOUT")
if [ "$out_abs" = "$chk_abs" ]; then
  die "output dir is the reviewed checkout ($OUT). Pick a different <label>"
fi
case "$out_abs/" in
  "$chk_abs"/*) die "output dir is inside the reviewed checkout. Pick a different <label>" ;;
esac
# Both directions. If OUT contains CHECKOUT, every previous reviewer's findings
# sit one `ls ..` away from the tree under review.
case "$chk_abs/" in
  "$out_abs"/*) die "the checkout is inside the output dir ($OUT). Pick a different <label>" ;;
esac

mkdir -p "$OUT"

# ★ Not under $CADRE_HOME either. There the agent's own cwd spells out where
# the keys are and `cat ../../keys/...` reaches them by relative path, with no
# environment variable involved. This is the hole that made scrubbing the
# environment insufficient on its own.
case "$chk_abs/" in
  "$(readlink -m "$CADRE_HOME")"/*)
    die "the checkout is inside CADRE_HOME ($CHECKOUT).
     The agent could reach the answer keys by relative path from its own cwd.
     Re-create the pass with 'cadre make-pass', which puts checkouts under
     \$CADRE_WORK (${CADRE_WORK:-unset}), a separate tree." ;;
esac

have=$(git -C "$CHECKOUT" rev-parse --short HEAD 2>/dev/null) || die "not a git checkout: $CHECKOUT"
case "$sha" in "$have"*) ;; *) die "$CHECKOUT is at $have, not $sha" ;; esac

secrets_preflight "$CHECKOUT"

PROMPT="$OUT/prompt.txt"
if [ -n "${CADRE_PROMPT_FILE:-}" ]; then
  cp "$CADRE_PROMPT_FILE" "$PROMPT"
else
  render_review_prompt "$CADRE_ROOT/lib/prompts/review.md" "$BASE" "$CHECKOUT" > "$PROMPT"
fi

echo "pass $label @ ${sha:0:9} | reviewers: ${reviewers[*]} | $runs run(s)"

# The agent must not inherit the path to the keys or to the other reviewers'
# output. CADRE_AGENTS_D is passed back in below on purpose: it points at
# adapters, not at keys, and user overrides need it.
mapfile -t SCRUB < <(scrubbed_env)

# ★ Count outcomes. This script used to end on `echo` and therefore always
# exited 0, which is why run_gauntlet's `|| return 1` had never once fired: a
# candidate that produced NOTHING reported the same success as one that produced
# everything, and the driver above it wrote COMPLETED across a sweep where 27 of
# 30 requested reviews did not exist. Silence and success must not share an exit
# code.
ok_runs=0; bad_runs=0; dead_agents=""; windows=""; windows_reset=""; no_output_runs=0; misconfigured_runs=0

for r in "${reviewers[@]}"; do
  agent=$(spec_agent "$r"); model=$(spec_model "$r")
  # Not installed is not "nothing was asked for". Every requested run is a run
  # that produced nothing, and the caller has to hear that in the exit code.
  agent_installed "$agent" || {
    echo "  $r: NOT INSTALLED, $runs requested run(s) produced nothing"
    bad_runs=$((bad_runs + runs)); dead_agents="$dead_agents  $r: not installed"$'\n'
    misconfigured_runs=$((misconfigured_runs + runs))
    continue
  }
  # Capability preflight: a doomed seat must not burn the graded-pass budget.
  # Graded passes need every seat present (gates are refused at parse time);
  # a capability block is the same class of refusal, recorded as failed runs.
  pblock=""; pdecl=""; preason=""
  if pblock=$(capability_block "$r" reviewer "$PROMPT"); then
    IFS=$'\t' read -r pdecl preason <<< "$pblock"
    echo "  $r: SKIPPED by capability preflight ($pdecl: $preason)"
    bad_runs=$((bad_runs + runs))
    dead_agents="$dead_agents  $r: capability preflight ($pdecl: $preason)"$'\n'
    continue
  fi
  m=(); [ -n "$model" ] && m=(-M "$model")
  budget=""; window=""
  for n in $(seq 1 "$runs"); do
    f="$OUT/$(slug "$r")-run$n.md"
    [ -s "$f" ] && { echo "  $r run$n: already have it, skipping"; ok_runs=$((ok_runs + 1)); continue; }
    echo "  $r run$n ..."
    start=$(date +%s)
    # Measured at dispatch, never reconstructed: the prompt is on disk now and
    # its size cannot be recovered from an artifact later.
    prompt_bytes=$(wc -c < "$PROMPT" 2>/dev/null | tr -d ' ')
    # ★ Before the attempt loop, so a sweep killed mid-run still proves this run
    # was dispatched. Same guarantee, same shape, as the panel path.
    record_event "$RUNLOG" event=dispatch pass="$label" \
      seat="$r" family="$(spec_family "$r")" slug="$(slug "$r")" "run#=$n" \
      "prompt_bytes#=$prompt_bytes" "ts#=$start"
    # ★ .failed and .inconclusive, never .partial. Deleting .partial here threw
    # away real findings the moment a retry produced nothing -- the previous
    # attempt's partial review was the only copy, and this feature exists
    # because those findings are worth keeping. It is cleared on SUCCESS
    # instead, below. An .inconclusive carries no findings by definition, so it
    # is a stale artifact with nothing to protect: left behind, it would let
    # grade.sh name a run inconclusive on the strength of an earlier
    # invocation's file.
    rm -f "$f.failed" "$f.inconclusive"
    # ★ Retry the SAME model on a rate limit. Never substitute a different one:
    # filing model B's review under model A is the mislabeling this whole tool
    # exists to catch. Free tiers are the reason this loop exists, see README.
    attempt=1
    while :; do
      # Same channel as the panel path, same reason for the temp path: $OUT
      # holds every other run's output and the adapter must not learn it.
      # Private dir, not a bare temp file: see the note in lib/run-review.sh.
      metad=$(mktemp -d); meta="$metad/state"; rm -f "$f.part.meta"
      "${SCRUB[@]}" CADRE_AGENTS_D="${CADRE_AGENTS_D:-$CADRE_HOME/agents.d}" \
        CADRE_PASS_BASE="$BASE" CADRE_RUN_META="$meta" \
        "$CADRE_ROOT/bin/agentcall" "$agent" -d "$CHECKOUT" -m ro "${m[@]}" \
        < "$PROMPT" > "$f.part" 2>&1
      rc=$?
      [ -s "$meta" ] && mv "$meta" "$f.part.meta"
      rm -rf "$metad"
      # ★ Same order as the review path, same reason: the adapter's own verdict
      # outranks a keyword scan. A short partial that merely DISCUSSES rate
      # limiting used to drive real retries and then get cadre's own note
      # appended after its _TRUNCATED marker. See lib/run-review.sh.
      [ "$(classify_run "$f.part" "$rc")" = failed ] || break
      # ★ Three refusals, asked most-specific first, and every step of that order
      # was paid for by a sweep.
      #
      # A usage WINDOW leads. Backoff cannot outwait a reset hours away, so it is
      # not a rate limit -- but the reset is real, so it is not a budget either,
      # and quota_exhausted's `usage limit` pattern would otherwise claim it and
      # drop the agent for the whole sweep. See provider_window_closed().
      provider_window_closed "$f.part" && { window=1; break; }
      # Then BUDGET before rate limit. A spend cap or an empty account is not a
      # throughput ceiling: no backoff inside this sweep clears it, so retrying
      # is waste and attempting this agent on the REMAINING passes is a
      # guaranteed hour of writing 102-byte failures. See quota_exhausted().
      quota_exhausted "$f.part" && { budget=1; break; }
      rate_limited "$f.part" || break
      if [ "$attempt" -ge "${CADRE_RETRIES:-3}" ]; then
        { echo "DID NOT COMPLETE, rate limited, gave up after $attempt attempts."
          cat "$f.part"; } > "$f.part.tmp" && mv "$f.part.tmp" "$f.part"
        break
      fi
      w=$(retry_wait "$attempt")
      echo "    rate limited, waiting ${w}s then retrying $r (attempt $((attempt + 1))/${CADRE_RETRIES:-3})"
      sleep "$w"
      attempt=$((attempt + 1))
    done
    took=$(( $(date +%s) - start ))
    # ★ A failed run must not leave an artifact the next invocation counts as
    # "already have it". An auth error is non-empty and the judge grades it.
    # NO minimum length: "findings=0" and a bare "No defects found." are valid
    # reviews the brief asks for, and a length rule threw them away. Exit
    # status, an empty file, and the adapters' failure markers instead.
    # ★ _TRUNCATED is its own state, not a failure. agents.d/grok.sh appends it
    # AFTER partial review text when the model stopped early, so the file is
    # non-empty, rc is 0, and the marker is not on the first line. Counting that
    # as a complete run understated the candidate, which is why classify_run
    # exists. ★ A degraded run is still NOT SCORED: a benchmark number is a
    # per-model claim, and a run cut short is not a fair sample of the model.
    # It is kept as .partial so the report can say WHICH kind of nothing it was.
    state=$(classify_run "$f.part" "$rc")
    case "$state" in
      ok)
        mv "$f.part" "$f"
        # Now, and only now, last attempt's partial is genuinely superseded.
        rm -f "$f.partial"
        ok_runs=$((ok_runs + 1))
        echo "    $(wc -c < "$f") bytes in ${took}s" ;;
      degraded)
        mv "$f.part" "$f.partial"
        bad_runs=$((bad_runs + 1))
        echo "    DEGRADED after ${took}s, stopped early, kept as $(basename "$f.partial"), not scored" ;;
      # ★ Not scored, for the same reason a degraded run is not: a benchmark
      # number is a per-model claim, and a run that never produced a review is
      # not a sample of how that model reviews. Kept apart from FAILED in the
      # record because the distinction is the whole point of a benchmark here --
      # "cannot hold the review contract" is a finding ABOUT the model, where a
      # crashed CLI is a finding about the adapter.
      inconclusive)
        mv "$f.part" "$f.inconclusive"
        bad_runs=$((bad_runs + 1))
        echo "    INCONCLUSIVE after ${took}s, returned text but no review, kept as $(basename "$f.inconclusive"), not scored" ;;
      # ★ One bucket, three messages (#12). A clock kill with a live adapter
      # behind it, a provider that returned nothing, and a refusal all land in
      # .failed and they call for opposite responses -- raise the timeout, wait
      # out the outage, drop the seat. failure_phrase reads the discriminator
      # classify_run already computed; the BUCKET is deliberately unchanged.
      *)
        mv "$f.part" "$f.failed"
        bad_runs=$((bad_runs + 1))
        # Counted here so the pass can exit with the provider's cause rather
        # than a generic 4. See the exit-7 block at the bottom of this file.
        case "$(failure_kind "$f.failed" "$rc")" in
          no-output)     no_output_runs=$((no_output_runs + 1)) ;;
          misconfigured) misconfigured_runs=$((misconfigured_runs + 1)) ;;
        esac
        echo "    $(failure_phrase "$f.failed" "$rc" "$took"), kept as $(basename "$f.failed"), not counted as a run" ;;
    esac

    # ★ After the `mv`, so `bytes` describes the artifact under its final name --
    # the same rule the panel path follows. `run` is the field the benchmark
    # side has and the panel side does not: a pass asks the SAME seat for N
    # runs, so seat alone does not identify a row here.
    art="$f"
    [ -s "$art" ] || art="$f.partial"
    [ -s "$art" ] || art="$f.inconclusive"
    [ -s "$art" ] || art="$f.failed"
    run_bytes=$(wc -c < "$art" 2>/dev/null | tr -d ' ')
    record_event "$RUNLOG" event=complete pass="$label" \
      seat="$r" family="$(spec_family "$r")" slug="$(slug "$r")" "run#=$n" \
      state="$state" "rc#=$rc" "secs#=$took" "bytes#=${run_bytes:-0}" \
      "prompt_bytes#=$prompt_bytes" "attempts#=$attempt" "ts#=$(date +%s)"
    # Same rule as the panel path: the declaration is consumed, the state lives
    # in runs.jsonl, and a stale .meta would classify the NEXT attempt at this
    # slot by this one's field.
    rm -f "$f.part.meta"

    # Out of budget: stop this agent HERE. The remaining runs of this pass, and
    # every later pass in the sweep, would produce the same refusal. Loud, and
    # on stderr as well, because the driver that hid this last time was piping
    # stdout to /dev/null.
    if [ -n "$budget" ]; then
      bad_runs=$((bad_runs + (runs - n)))
      dead_agents="$dead_agents  $r: out of budget after run$n -- $(head -c 200 "$f.failed" | tr '\n' ' ')"$'\n'
      echo "    ⛔ $r is OUT OF BUDGET, not a rate limit. Skipping its remaining run(s)."
      echo "cadre: $r refused for budget reasons on pass $label, not retrying it" >&2
      break
    fi

    # Usage window closed: same stop, different meaning, and the reset time is
    # quoted verbatim because it is the one fact the operator or driver needs to
    # schedule the resumption. NOT parsed into a sleep here: a 12-hour clock, a
    # timezone name and a midnight crossing are three ways to hang a sweep for
    # hours instead of failing it, so the decision belongs to the caller.
    if [ -n "$window" ]; then
      bad_runs=$((bad_runs + (runs - n)))
      windows="$windows  $r: usage window closed after run$n -- $(head -c 200 "$f.failed" 2>/dev/null | tr '\n' ' ')"$'\n'
      # ★ Asked of the REFUSAL, not of the line above it (#48). That line
      # carries the agent name and a 200-byte excerpt, so an agent called
      # `resetter` would supply the word and a reset past the excerpt would be
      # missed -- both of them wrong about the only thing this flag decides.
      grep -qi 'reset' "$f.failed" 2>/dev/null && windows_reset=1
      echo "    ⏸ $r's usage window is CLOSED, not a rate limit and not a budget."
      echo "cadre: $r hit a provider usage window on pass $label. Waiting clears it; the refusal is quoted above." >&2
      break
    fi

    # Several CLIs have no read-only mode and the brief invites running tests.
    # A reviewer that edits a file changes what every later reviewer sees.
    # Safe to restore: this checkout is a disposable clone.
    if [ -n "$(git -C "$CHECKOUT" status --porcelain 2>/dev/null)" ]; then
      echo "    ⚠ $r modified the checkout. Restoring it so later runs see the same tree:"
      git -C "$CHECKOUT" status --porcelain | head -5 | sed 's/^/      /'
      git -C "$CHECKOUT" reset --hard --quiet 2>/dev/null
      git -C "$CHECKOUT" clean -fdq 2>/dev/null
    fi
  done
done

echo "done. Outputs in $OUT"
echo "  $ok_runs usable, $bad_runs not usable, of $((ok_runs + bad_runs)) requested run(s)"

# ★ Exit 4 only when NOTHING is usable, not on any failure. A candidate that
# managed 2 of 3 runs still has something to grade and the report already records
# which run was UNUSABLE, so aborting there would throw away real reviews over a
# flake. Zero of N is the other case entirely: there is nothing to measure, and
# the next pass will almost certainly go the same way. 4, because 2 is a usage
# error and 3 is the credential refusal.
# ★ 4 is the GENERIC "measured nothing", and two causes are pulled out of it
# because the operator's next move is different: 6, the provider's usage window
# closed (wait for the reset), and 7, every run came back empty (check the
# endpoint is up). Both mean "nothing is wrong here to fix", which 4 does not.
# 9 is the operator's own fault (#31): the seat never ran on this box.
# (8 is taken by bin/cadre's review claim and means "already running".)
# This comment is the only table of these codes; add to it when you add one.
if [ "$ok_runs" -eq 0 ] && [ "$bad_runs" -gt 0 ]; then
  # ★ 9 before all of them (#31): a requested seat that NEVER RAN because of
  # a fault on this box. Every later pass fails the same way, the fix is the
  # operator's, and nothing about the candidate was observed -- so it must
  # not read as 4's "defect to fix in the tool" nor as 6/7's "wait it out".
  # Fail closed, the way addyosmani/factory's MISCONFIGURED gate refuses
  # rather than scoring around a gate that was declared and never dispatched.
  if [ "$misconfigured_runs" -eq "$bad_runs" ]; then
    {
      echo "cadre: pass '$label' measured NOTHING because the seat is MISCONFIGURED on this box."
      [ -n "$dead_agents" ] && printf '%s' "$dead_agents"
      echo "The reviewer was never called, so this is not evidence about it. Fix the roster"
      echo "entry or the install and re-run; nothing here scores the candidate either way."
    } >&2
    exit 9
  fi
  # ★ 6 before 4. Both mean "this pass measured nothing", and they prescribe
  # opposite next moves: 4 says the cause is a defect to fix, 6 says the cause is
  # a clock that will clear itself. Reporting a closed window as a failed
  # measurement is how a sweep four minutes short of resuming got a report
  # reading "Fix the cause and re-run" with nothing to fix.
  # ★ ...and not when a misconfigured seat is in the mix: "nothing is wrong
  # with the tool" would be false, and the operator would wait out a window
  # for a seat that can never run.
  if [ -n "$windows" ] && [ "$misconfigured_runs" -eq 0 ]; then
    {
      echo "cadre: pass '$label' measured NOTHING because a provider usage window closed."
      printf '%s' "$windows"
      echo "Nothing is wrong with the tool, the key, or the candidate, and nothing"
      echo "already on disk was lost."
      # ★ Not every window states its reset (#48): a model-tier limit names a
      # REMEDY instead, and the reset only exists in the provider's usage API.
      # Printing "resume after the reset time quoted above" over text that
      # quotes no time sends the operator hunting for a line nobody wrote.
      if [ -n "$windows_reset" ]; then
        echo "Resume after the reset time quoted above."
      else
        echo "This refusal does not state its reset; check the provider's usage"
        echo "page for when the window reopens, then resume."
      fi
    } >&2
    exit 6
  fi
  # ★ 7 before 4, for the reason 6 comes before both: same "this pass measured
  # nothing", opposite next move. Every single run came back EMPTY, which is a
  # statement about the PROVIDER -- measured when every opencode-go model hung on
  # `Reply with exactly: OK` while a direct-provider model answered instantly.
  # Reported as 4, the operator goes hunting for a defect in a healthy tool and,
  # worse, reads "not one usable review" as a property of the candidate.
  # ★ The whole reason this lives HERE and not only in the grader: `cadre run`
  # ABORTS on this exit code and never reaches grading, so a verdict computed
  # downstream is one the common command can never print. 6 already had to solve
  # exactly this; 7 solves it the same way.
  # ★ Requires ALL of them. bad_runs also counts agents that were never
  # installed and runs skipped after a budget stop, neither of which produced an
  # artifact -- so a partial match here would blame a provider that was, in the
  # missing-agent case, never called at all.
  if [ "$no_output_runs" -eq "$bad_runs" ]; then
    {
      echo "cadre: pass '$label' measured NOTHING and every run came back EMPTY."
      echo "$bad_runs of $bad_runs requested run(s) returned no content at all. That is"
      echo "evidence about the PROVIDER, not about the candidate: a model answering"
      echo "normally does not return zero bytes to every seat. Check the endpoint is up -- a"
      echo "trivial prompt against the same route answers instantly when it is -- then"
      echo "re-run. Nothing here scores the candidate either way."
    } >&2
    exit 7
  fi
  {
    echo "cadre: NO usable review on pass '$label'. $bad_runs requested run(s), none produced one."
    [ -n "$dead_agents" ] && printf '%s' "$dead_agents"
    echo "This is a failed measurement, not a result. Nothing here should be scored."
  } >&2
  exit 4
fi
exit 0
