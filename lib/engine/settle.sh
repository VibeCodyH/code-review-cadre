#!/usr/bin/env bash
# lib/engine/settle.sh -- the settled-decisions ledger, and splitting a review
# into NEW vs already-settled.
#
# ENGINE, not benchmark, and that placement is the answer to the open question on
# #25. Settle is a LIVE-LOOP concern: it exists so that re-running a review on a
# branch stops re-raising what a human already dismissed. Nothing about it has an
# opinion on how good a reviewer is, and the benchmark never calls it.
#
# ★★ IT WRITES findings[], NEVER claims[]. A settle disposition is one human's
# judgement about one repo, so a `status` or `ledger_id` stamped onto the graded
# layer would make a reviewer's benchmark score a function of Cody's dismissals
# -- and it would keep looking like a score. engine_findings() puts both fields
# on findings[] as nulls for exactly this reason: settle has a place to write
# that is not the place we grade. tests/engine-seam.sh asserts both halves.
#
# ★ And the ledger stays HUMAN-WRITTEN. Nothing here appends to it. A tool that
# files its own dismissals will eventually dismiss something real, and the whole
# value of the file is that a person decided. Folding settle into the engine does
# not change that; if a later change gives the engine a way to write the ledger,
# the treadmill it was built to stop comes back with cadre's signature on it.

# ---- the settled-decisions ledger --------------------------------------------
#
# ★ Cadre reviews once and stops, so on its own it cannot treadmill. The moment
# something WRAPS it in a loop, which is the normal way people use a review tool
# on a branch, every re-run re-raises findings the human already dismissed. The
# reviewers have no memory; the human is the only thing that remembers, and
# making them remember is how a review loop becomes unbearable.
#
# The ledger is a human-written file. Nothing writes to it automatically: a tool
# that files its own dismissals will eventually dismiss something real, and the
# whole value here is that a person decided. `cadre settle` only READS it.
LEDGER_HELP='One finding per line:

    <id> | <disposition> | <description>

  L1 | wontfix  | timestamps are strings from neon-http, callers wrap them
  L2 | accepted | missing test for the retry path, tracked in #412

disposition is yours; cadre does not interpret it.'

ledger_path() { echo "${CADRE_LEDGER:-$CADRE_HOME/ledger}"; }

cmd_ledger() {
  local lp; lp=$(ledger_path)
  case "${1:-show}" in
    show)
      if [ ! -s "$lp" ]; then
        echo "no ledger at $lp"; echo; echo "$LEDGER_HELP"; return 0
      fi
      echo "$lp"; echo
      # Comments and blanks are the user's; print the file as they wrote it.
      cat "$lp" ;;
    path) echo "$lp" ;;
    *) die "ledger: expected 'show' or 'path'" ;;
  esac
}

# Split one review into SETTLED / NEW against the ledger. Read-only, and it
# never edits the review: the finding stays on disk exactly as written.
cmd_settle() {
  local review="" judge="${CADRE_JUDGE:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --judge) judge="${2:?--judge needs an agent spec}"; shift 2 ;;
      -*) die "settle: unknown option '$1'" ;;
      *)  review="$1"; shift ;;
    esac
  done
  [ -n "$review" ] || die "usage: cadre settle <review-file-or-dir> [--judge spec]"

  # A review directory is the normal thing to have: point at the report.
  [ -d "$review" ] && review="$review/report.md"
  [ -s "$review" ] || die "no review to read at $review"

  local lp; lp=$(ledger_path)
  [ -s "$lp" ] || die "no ledger at $lp, so there is nothing settled yet.

     $LEDGER_HELP"

  [ -n "$judge" ] || { pick_judge || true; judge="${CADRE_JUDGE:-}"; }
  [ -n "$judge" ] || die "settle needs a judge. Set \$CADRE_JUDGE or pass --judge."

  # ★ Strip comments and blanks before the model sees it. A '#' line is a note
  # to the human, and feeding it as an entry invites a match against a comment.
  local entries; entries=$(grep -vE '^[[:space:]]*(#|$)' "$lp")
  [ -n "$entries" ] || die "$lp has no entries, only comments."

  local pf; pf=$(mktemp)
  { cat "$CADRE_ROOT/lib/prompts/settle.md"; echo
    echo "===== LEDGER ====="; printf '%s\n' "$entries"; echo
    echo "===== REVIEW ====="; cat "$review"
  } > "$pf"

  local a m mm=() raw rc
  a=$(spec_agent "$judge"); m=$(spec_model "$judge")
  [ -n "$m" ] && mm=(-M "$m")
  echo "matching against $(printf '%s\n' "$entries" | wc -l) ledger entries with $judge …"
  raw=$("$CADRE_ROOT/bin/agentcall" "$a" "${mm[@]}" -d /tmp -m ro < "$pf" 2>&1); rc=$?
  rm -f "$pf"

  # ★ Fail loudly. A settle pass that silently returns nothing looks exactly
  # like "everything here is already settled", which would hide a live finding
  # behind a judge that never ran.
  # ★ Models fence their JSON. `sed -n '/{/,$p'` took the first { to EOF, which
  # carries the CLOSING ``` along with it, and jq rejects the trailing fence --
  # so a judge that answered perfectly was reported as one that "failed or
  # stopped early". Measured with qwen as judge on a real panel: the correct
  # findings were printed in the error's own diagnostic lines, which is as close
  # to self-refuting as a message gets.
  # Take the first { to the LAST }, after dropping fence lines. That survives
  # prose on either side of the block and braces inside strings, which a
  # brace-counting scan does not. Anything that still is not JSON -- no object
  # at all, or a truncated one -- fails jq and is refused below, which is the
  # direction that has to stay safe.
  local js
  js=$(printf '%s' "$raw" \
       | sed -e '/^[[:space:]]*```/d' \
       | awk 'BEGIN{RS="\0"} {
             i=index($0,"{"); if(!i) exit; s=substr($0,i);
             for(k=length(s);k>0;k--) if(substr(s,k,1)=="}") { printf "%s", substr(s,1,k); exit }
           }' \
       | jq -c . 2>/dev/null) || js=""
  # ★ Two causes, one message, so say both. An adapter that truncates now exits
  # nonzero even when the JSON it printed parses fine, and reporting that as
  # "did not return usable JSON" describes the wrong problem to whoever has to
  # fix it. A partial match is still refused either way: settle's exit code is a
  # stopping rule, and half a match reads as "nothing new is left".
  if [ "$rc" -ne 0 ] || [ -z "$js" ]; then
    echo "cadre: the judge failed or stopped early, so nothing was matched." >&2
    printf '%s\n' "$raw" | head -5 | sed 's/^/     /' >&2
    return 1
  fi

  local total new
  total=$(printf '%s' "$js" | jq '.findings | length')
  new=$(printf '%s' "$js" | jq '[.findings[] | select(.status != "SETTLED")] | length')
  echo
  if [ "$total" -eq 0 ]; then echo "no findings in that review."; return 0; fi

  if [ "$new" -gt 0 ]; then
    echo "NEW ($new of $total):"
    printf '%s' "$js" | jq -r '.findings[] | select(.status != "SETTLED") | "  - \(.summary)"'
  fi
  if [ "$new" -lt "$total" ]; then
    echo
    echo "already settled ($((total - new)) of $total), shown so you can check the match:"
    printf '%s' "$js" | jq -r '.findings[] | select(.status == "SETTLED")
                               | "  - [\(.ledger_id // "?")] \(.summary)"'
  fi
  echo
  echo "The review itself is unchanged at $review."
  # ★ The exit status is the useful part for a wrapper: 0 means nothing new to
  # look at, so a loop can stop. Non-zero means a human still has something to
  # read. That is the stopping rule, and it is deliberately not automatic.
  [ "$new" -eq 0 ]
}
