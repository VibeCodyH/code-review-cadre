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

for r in "${reviewers[@]}"; do
  agent=$(spec_agent "$r"); model=$(spec_model "$r")
  command -v "$agent" >/dev/null 2>&1 || { echo "  $r: not installed, skipping"; continue; }
  m=(); [ -n "$model" ] && m=(-M "$model")
  for n in $(seq 1 "$runs"); do
    f="$OUT/$(slug "$r")-run$n.md"
    [ -s "$f" ] && { echo "  $r run$n: already have it, skipping"; continue; }
    echo "  $r run$n ..."
    start=$(date +%s)
    # ★ .failed only. Deleting .partial here threw away real findings the moment
    # a retry produced nothing -- the previous attempt's partial review was the
    # only copy, and this feature exists because those findings are worth
    # keeping. It is cleared on SUCCESS instead, below.
    rm -f "$f.failed"
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
        echo "    $(wc -c < "$f") bytes in ${took}s" ;;
      degraded)
        mv "$f.part" "$f.partial"
        echo "    DEGRADED after ${took}s, stopped early, kept as $(basename "$f.partial"), not scored" ;;
      *)
        mv "$f.part" "$f.failed"
        echo "    FAILED after ${took}s (rc=$rc), kept as $(basename "$f.failed"), not counted as a run" ;;
    esac

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
