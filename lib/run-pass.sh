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
ok_runs=0; bad_runs=0; dead_agents=""; windows=""

for r in "${reviewers[@]}"; do
  agent=$(spec_agent "$r"); model=$(spec_model "$r")
  # Not installed is not "nothing was asked for". Every requested run is a run
  # that produced nothing, and the caller has to hear that in the exit code.
  agent_installed "$agent" || {
    echo "  $r: NOT INSTALLED, $runs requested run(s) produced nothing"
    bad_runs=$((bad_runs + runs)); dead_agents="$dead_agents  $r: not installed"$'\n'
    continue
  }
  m=(); [ -n "$model" ] && m=(-M "$model")
  budget=""; window=""
  for n in $(seq 1 "$runs"); do
    f="$OUT/$(slug "$r")-run$n.md"
    [ -s "$f" ] && { echo "  $r run$n: already have it, skipping"; ok_runs=$((ok_runs + 1)); continue; }
    echo "  $r run$n ..."
    start=$(date +%s)
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
      "${SCRUB[@]}" CADRE_AGENTS_D="${CADRE_AGENTS_D:-$CADRE_HOME/agents.d}" \
        CADRE_PASS_BASE="$BASE" \
        "$CADRE_ROOT/bin/agentcall" "$agent" -d "$CHECKOUT" -m ro "${m[@]}" \
        < "$PROMPT" > "$f.part" 2>&1
      rc=$?
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
    case "$(classify_run "$f.part" "$rc")" in
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
      *)
        mv "$f.part" "$f.failed"
        bad_runs=$((bad_runs + 1))
        echo "    FAILED after ${took}s (rc=$rc), kept as $(basename "$f.failed"), not counted as a run" ;;
    esac

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
      echo "    ⏸ $r's usage window is CLOSED, not a rate limit and not a budget."
      echo "cadre: $r hit a provider usage window on pass $label. Waiting clears it; see the reset time above." >&2
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
if [ "$ok_runs" -eq 0 ] && [ "$bad_runs" -gt 0 ]; then
  # ★ 6 before 4. Both mean "this pass measured nothing", and they prescribe
  # opposite next moves: 4 says the cause is a defect to fix, 6 says the cause is
  # a clock that will clear itself. Reporting a closed window as a failed
  # measurement is how a sweep four minutes short of resuming got a report
  # reading "Fix the cause and re-run" with nothing to fix.
  if [ -n "$windows" ]; then
    {
      echo "cadre: pass '$label' measured NOTHING because a provider usage window closed."
      printf '%s' "$windows"
      echo "Nothing is wrong with the tool, the key, or the candidate, and nothing"
      echo "already on disk was lost. Resume after the reset time quoted above."
    } >&2
    exit 6
  fi
  {
    echo "cadre: NO usable review on pass '$label'. $bad_runs requested run(s), none produced one."
    [ -n "$dead_agents" ] && printf '%s' "$dead_agents"
    echo "This is a failed measurement, not a result. Nothing here should be scored."
  } >&2
  exit 4
fi
exit 0
