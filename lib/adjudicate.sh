# The OPEN track: are the reviewer's findings real? Sourced by bin/cadre.
# shellcheck shell=bash
#
# The keyed track asks "did it find the defect we planted". That measures agreement
# with the one fix an author happened to ship, and nothing else. Measured on a real
# 1,842-line feature commit: a reviewer scored 0/2 on the key while stating five real
# defects, one of which the author later shipped a repair for. The key is a FLOOR.
#
# This track adjudicates EVERY finding a review states against the checkout it
# reviewed, and reports three counts rather than one ratio. A single ratio hides the
# shape: five vague findings plus one false one is not "1 in 6 wrong", it is six items
# nobody can act on.
#
# ★ The adjudicator never sees the answer key. It is not checking agreement with the
# key, it is checking claims against code, and handing it the key would invite it to
# confirm the key instead.

ADJ_UNUSABLE='{"findings":[],"unusable":true}'

# adjudicate_one <checkout> <review-file> <out.json> <agent> <model>
adjudicate_one() {
  local checkout="$1" review="$2" out="$3" agent="$4" model="$5"
  local raw attempt=1 w tmp
  [ -s "$review" ] || { echo "$ADJ_UNUSABLE" > "$out"; return; }

  tmp=$(mktemp)
  { cat "$CADRE_ROOT/lib/prompts/adjudicate.md"
    echo
    echo "=============== THE REVIEW ==============="
    cat "$review"
  } > "$tmp"

  local m=(); [ -n "$model" ] && m=(-M "$model")
  local SCRUB; mapfile -t SCRUB < <(scrubbed_env)

  # Same retry rule as every other model call here: retry THIS adjudicator, never
  # substitute another. An adjudication filed under the wrong model is the
  # mislabeling this whole tool exists to catch.
  while :; do
    raw=$("${SCRUB[@]}" CADRE_AGENTS_D="${CADRE_AGENTS_D:-$CADRE_HOME/agents.d}" \
      "$CADRE_ROOT/bin/agentcall" "$agent" -d "$checkout" -m ro "${m[@]}" < "$tmp" 2>&1)
    printf '%s' "$raw" > "$out.tmp"
    rate_limited "$out.tmp" || { rm -f "$out.tmp"; break; }
    rm -f "$out.tmp"
    [ "$attempt" -ge "${CADRE_RETRIES:-3}" ] && break
    w=$(retry_wait "$attempt")
    echo "    adjudicator rate limited, waiting ${w}s (attempt $((attempt + 1))/${CADRE_RETRIES:-3})" >&2
    sleep "$w"
    attempt=$((attempt + 1))
  done
  rm -f "$tmp"

  printf '%s' "$raw" | extract_json > "$out" 2>/dev/null
  # Keep what it actually said when it does not parse. UNUSABLE with no record is
  # indistinguishable from a broken adjudicator, a bad prompt, and a real refusal --
  # the same lesson the judge path had to learn.
  jq -e '.findings' "$out" >/dev/null 2>&1 || {
    printf '%s' "$raw" > "$out.adj-raw"
    echo "$ADJ_UNUSABLE" > "$out"
  }
}

# run_adjudication <adjudicator-spec> <candidate-spec> <runs> [pass-label]
run_adjudication() {
  local adj="$1" cand="$2" runs="$3" only="${4:-}"
  local asl; asl=$(slug "$adj")
  local csl; csl=$(slug "$cand")
  local agent; agent=$(spec_agent "$adj")
  local model; model=$(spec_model "$adj")
  agent_installed "$agent" || die "adjudicator '$adj' but '$agent' is not installed"

  local report="$CADRE_HOME/open-$csl-by-$asl.md"
  : > "$report"
  { echo "# Open track: $cand, adjudicated by $adj"
    echo
    # ★ Say who judged whom. The "adjudicator is not one of the agents under test"
    # rule cannot be enforced here -- this command does not know the roster -- so
    # it is named in the artifact instead and left to the reader.
    if [ "$(spec_agent "$adj")" = "$(spec_agent "$cand")" ]; then
      echo "⚠ **The adjudicator and the candidate are the same agent.** This is a"
      echo "reviewer grading its own findings. Treat every number below as unusable"
      echo "for ranking; re-run with a different adjudicator."
      echo
    fi
  } >> "$report"

  local real_change=0 real_repo=0 false_n=0 unfal=0 adjudicated=0 unusable=0 passes=0
  local label sha dir base key
  while IFS='|' read -r label sha dir base key; do
    case "$label" in ''|\#*) continue ;; esac
    [ -z "$only" ] || [ "$only" = "$label" ] || continue
    [ -d "$dir" ] || { echo "  $label: checkout is gone, skipping" >&2; continue; }
    passes=$((passes + 1))
    { echo "## $label"; echo; } >> "$report"

    local n
    for n in $(seq 1 "$runs"); do
      local rf="$CADRE_HOME/$label/$csl-run$n.md"
      # No review is not "no findings". Say which, the same way grading does.
      [ -s "$rf" ] || { echo "- run $n: no review to adjudicate" >> "$report"; continue; }
      # ★ The adjudicator is IN the filename. Keyed on the candidate alone, a second
      # adjudicator finds the first one's file, skips its own call, and reports the
      # FIRST one's verdicts under its own name -- filing model B's judgement under
      # model A, the mislabeling this whole tool exists to catch. It also silently
      # blocks the one workflow that validates this track: run two adjudicators over
      # the same reviews and compare.
      local af="$CADRE_HOME/$label/$csl-run$n.by-$asl.adj.json"
      [ -s "$af" ] || { echo "  $label run$n: adjudicating …" >&2
                        adjudicate_one "$dir" "$rf" "$af" "$agent" "$model"; }

      if [ "$(jq -r '.unusable // false' "$af")" = true ]; then
        unusable=$((unusable + 1))
        local why="the review was empty or truncated"
        [ -s "$af.adj-raw" ] && why="the adjudicator's reply did not parse, see $(basename "$af").adj-raw"
        echo "- run $n: **UNUSABLE** ($why)" >> "$report"
        continue
      fi

      local rc rr f u
      rc=$(jq -r '[.findings[]? | select(.verdict=="REAL" and .scope=="change")] | length' "$af")
      rr=$(jq -r '[.findings[]? | select(.verdict=="REAL" and .scope!="change")] | length' "$af")
      f=$(jq -r  '[.findings[]? | select(.verdict=="FALSE")] | length' "$af")
      u=$(jq -r  '[.findings[]? | select(.verdict=="UNFALSIFIABLE")] | length' "$af")
      real_change=$((real_change + rc)); real_repo=$((real_repo + rr))
      false_n=$((false_n + f));          unfal=$((unfal + u))
      adjudicated=$((adjudicated + rc + rr + f + u))
      echo "- run $n: **$rc real** (change) · $rr real (repo-wide) · $f false · $u unfalsifiable" >> "$report"
      # ★ Print the evidence, not just the verdict. An adjudication nobody can
      # re-check is worth nothing: this harness has caught three separate grading
      # failures by re-reading the artifact, and every one was catchable only
      # because the artifact said where to look. FALSE verdicts get it too -- those
      # are the ones that silently delete a reviewer's credit.
      jq -r '.findings[]? | select(.verdict=="REAL" and .scope=="change")
             | "  - \(.severity // "?"): \(.claim)\n    ↳ \(.evidence // "NO EVIDENCE GIVEN")"' "$af" >> "$report"
      jq -r '.findings[]? | select(.verdict=="FALSE")
             | "  - false: \(.claim)\n    ↳ \(.evidence // "NO EVIDENCE GIVEN")"' "$af" >> "$report"
      # A verdict with no evidence cannot be audited, so say so where it is counted
      # rather than leaving the total looking as solid as an evidenced one.
      local noev; noev=$(jq -r '[.findings[]? | select((.evidence // "") == "")] | length' "$af")
      [ "$noev" -eq 0 ] || echo "  ⚠ $noev of these carry NO evidence and cannot be re-checked" >> "$report"
    done
    echo >> "$report"
  done < "$CADRE_HOME/passes.conf"

  [ "$passes" -gt 0 ] || { echo "no passes adjudicated. Check 'cadre passes'"; return 1; }

  { echo "## Totals"
    echo
    echo "- real, specific to the change: **$real_change**"
    echo "- real, but true of the repo generally: $real_repo"
    echo "- false: $false_n"
    echo "- unfalsifiable: $unfal"
    echo "- adjudicated: $adjudicated · unusable runs: $unusable"
    echo
    # ★ Three counts, no derived ratio. A single "false positive rate" hides the
    # shape it is supposed to expose: five vague findings and one false one is not
    # "1 in 6 wrong", it is six items nobody can act on.
    echo "Read these together, not as a ratio. **Real-and-specific is the value**;"
    echo "false plus unfalsifiable is the cost of reading this reviewer. A repo-wide"
    echo "finding (\"there are no tests\") is true and carries no information about"
    echo "the reviewer, because every candidate can make it without reading the diff."
    echo
    echo "This does NOT feed the slot recommendation. The keyed score is a floor and"
    echo "this is a separate measurement beside it."
  } >> "$report"

  cat "$report"
  echo
  echo "saved: $report"
}
