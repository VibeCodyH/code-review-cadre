# Grading and slot recommendation. Sourced by bin/cadre.
# shellcheck shell=bash

# shellcheck source=lib/table-manifest.sh
. "$CADRE_ROOT/lib/table-manifest.sh"

# HIT / DEFER / MISS, and DEFER on a blocking item disqualifies.
# Why: docs/METHOD.md §3.

judge_prompt() {
  local keyfile="$1" review="$2"
  cat "$CADRE_ROOT/lib/prompts/judge.md"
  echo
  echo "=============== ANSWER KEY ==============="
  cat "$keyfile"
  echo
  echo "=============== REVIEW ==============="
  cat "$review"
}

UNUSABLE='{"unusable":true,"items":{},"extras":[]}'

# The LAST brace-balanced object in whatever the judge said. Two simpler
# versions fail SILENTLY, as a jq error the caller records as UNUSABLE:
#   sed -n '/{/,/}/p'      stops at the first "}", truncating pretty JSON
#   first "{" to last "}"  starts inside a code snippet the judge echoed back
# Does not track braces inside JSON strings. The judge's format never has them.
extract_json() {
  awk '
    { for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") { if (d == 0) buf = ""; d++ }
        if (d > 0) buf = buf c
        if (c == "}" && d > 0) { d--; if (d == 0) last = buf }
      }
      if (d > 0) buf = buf "\n" }
    END { if (last != "") print last; else exit 1 }
  '
}

grade_one() {
  local keyfile="$1" review="$2" out="$3" raw attempt=1 w
  [ -s "$review" ] || { echo "$UNUSABLE" > "$out"; return; }
  # The judge is on a rate limit too, and a limited judge scores every candidate
  # UNUSABLE. Same rule as a reviewer: retry this judge, never swap in another.
  while :; do
    raw=$(judge_prompt "$keyfile" "$review" | judge_call 2>&1)
    printf '%s' "$raw" > "$out.tmp"
    rate_limited "$out.tmp" || { rm -f "$out.tmp"; break; }
    rm -f "$out.tmp"
    [ "$attempt" -ge "${CADRE_RETRIES:-3}" ] && break
    w=$(retry_wait "$attempt")
    echo "    judge rate limited, waiting ${w}s (attempt $((attempt + 1))/${CADRE_RETRIES:-3})" >&2
    sleep "$w"
    attempt=$((attempt + 1))
  done
  # ★ `.items` must exist, not just "any valid JSON". A provider error like
  # {"error":"quota exhausted"} parses fine, `.unusable // false` reads false,
  # and every missing item defaults to MISS -- a judge outage published as a
  # plausible 0/N candidate score. Requiring the one key the rubric promises
  # turns that into UNUSABLE with the raw reply kept.
  local parsed=0
  printf '%s' "$raw" | extract_json > "$out" 2>/dev/null
  jq -e '.items' "$out" >/dev/null 2>&1 && parsed=1
  # ★ The fallback for what the scan above cannot parse: an UNBALANCED brace
  # inside a JSON string. "The judge's format never has them" stopped being true
  # the day `quotes` became required -- a verbatim reviewer sentence about shell
  # or C code carries a lone { or } routinely, the depth count never returns to
  # zero, and a valid grade was recorded UNUSABLE with the judge blamed for it.
  # extract_json_slice() is the same code cmd_settle uses, one copy in
  # lib/common.sh (#26). Tried SECOND, not first, because on a reply that echoes
  # prompt text with braces the balanced scan finds the clean object and this
  # slice would not.
  if [ "$parsed" -eq 0 ]; then
    printf '%s' "$raw" | extract_json_slice > "$out" 2>/dev/null
    jq -e '.items' "$out" >/dev/null 2>&1 && parsed=1
  fi
  # ★ Keep what the judge actually said when it does not parse. UNUSABLE with no
  # record is indistinguishable from a broken judge, a bad key, and a real
  # refusal. Measured: a judge CLI that will not start outside a git repo failed
  # on every call and reported UNUSABLE across the board with no reason given.
  [ "$parsed" -eq 1 ] || {
    printf '%s' "$raw" > "$out.judge-raw"
    echo "$UNUSABLE" > "$out"
  }
}

# ---- regrade ledger (#39) ----------------------------------------------------
# `cadre grade` re-grades in place, so the prior verdict is the one thing the
# swap destroys. Every replacement of an existing grade appends ONE line here,
# beside the grade and never over it: the prior items, the new items, the keys
# whose verdict moved, and the hashes of the two inputs that could have moved
# them (the answer key; the harness with its rubric, the same digest #37 put on
# the run record). A regrade that changed nothing is recorded too -- "same
# answer on a second reading" is evidence, and it is the cheap kind.
# ★ Returns 1 when the line could not be written, and the caller then REFUSES
# the swap: a regrade whose prior cannot be kept is the overwrite this exists
# to stop. No prior on disk is not an error; there is nothing to keep.
regrade_ledger() { # <grade> <new-grade> <judge> <keyfile> <kept-prior 0|1>; sets REGRADE_CHANGED, REGRADE_CHANGES
  local gf="$1" new="$2" judge="$3" keyfile="$4" kept="$5" led="$1.regraded.jsonl" pj nj ksha="" hsha line
  REGRADE_CHANGED=0 REGRADE_CHANGES=""
  [ -s "$gf" ] || return 0
  pj=$(jq -c . "$gf" 2>/dev/null) || pj=null
  nj=$(jq -c . "$new" 2>/dev/null) || nj=null
  [ -f "$keyfile" ] && ksha=$(table_manifest_hash "$keyfile" 2>/dev/null || true)
  hsha=$(harness_sha)
  line=$(jq -cn --argjson prior "$pj" --argjson next "$nj" --arg judge "$judge" \
    --arg key "$ksha" --arg harness "$hsha" --argjson kept "$([ "$kept" = 1 ] && echo true || echo false)" --argjson ts "$(date +%s)" '
    def items(g): if g == null or (g | type) != "object" or (g.unusable // false) == true
                  then null else (g.items // {}) end;
    items($prior) as $pi | items($next) as $ni
    | ([ (($pi // {}) + ($ni // {})) | keys[] ] | unique) as $keys
    | {ts:$ts, judge:$judge,
       key_sha256:(if $key == "" then null else $key end),
       harness_sha:(if $harness == "" then null else $harness end),
       prior_unusable:($pi == null), unusable:($ni == null), kept_prior:$kept,
       prior_items:$pi, items:$ni,
       changed:(if $pi == null or $ni == null then {} else
         ([ $keys[] | . as $k
            | {key:$k, before:($pi[$k] // "MISS"), after:($ni[$k] // "MISS")}
            | select(.before != .after) ]
          | map({(.key):{before:.before, after:.after}}) | add // {}) end)}
  ') || return 1
  printf '%s\n' "$line" >> "$led" || return 1
  REGRADE_CHANGED=$(jq -r '.changed | length' <<< "$line")
  REGRADE_CHANGES=$(jq -r '.changed | to_entries | map("\(.key) \(.value.before)→\(.value.after)") | join(", ")' <<< "$line")
}

# Count key item headings the review reproduced word for word. The backstop for
# an agent that went looking for the key. docs/METHOD.md §5.
leak_check() {
  local keyfile="$1" review="$2" n=0 line txt
  while IFS= read -r line; do
    txt=$(printf '%s' "$line" | sed -E 's/^#+ *//; s/^K[0-9]+ *[-.:] *//; s/^(BLOCKING|SHOULD-FIX|NIT) *[-.:] *//I')
    [ "${#txt}" -ge 25 ] || continue
    grep -qiF -- "$txt" "$review" && n=$((n + 1))
  done < <(grep -E '^#+ *K[0-9]+\b' "$keyfile")
  echo "$n"
}

# Inspect the current artifact before allowing an operator exclusion. Failed
# output can leak the key too; an invalid marker must never hide that evidence.
scan_run_evidence() { # <keyfile> <review-path> <last-recorded-rc>
  local keyfile="$1" rf="$2" rc="$3" artifact="" suffix
  RUN_LEAKED=0 RUN_INVALID_REASON="" RUN_INVALID_ERROR="" RUN_FAILURE_KIND="" RUN_DELIVERY_KIND=""
  for suffix in '' .failed .inconclusive .partial; do
    if [ -s "$rf$suffix" ] || { [ "$suffix" = .failed ] && [ -e "$rf$suffix" ]; }; then
      artifact="$rf$suffix"; break
    fi
  done
  [ ! -s "$artifact" ] || RUN_LEAKED=$(leak_check "$keyfile" "$artifact")
  [ "$RUN_LEAKED" -lt 2 ] || return 0
  if [ -e "$rf.invalid.json" ]; then
    if ! RUN_INVALID_REASON=$(jq -ser '
      if length != 1 then error("expected one object") else .[0] end
      | if type != "object" or (.reason | type) != "string"
        then error("reason must be a string") else .reason end
      | gsub("\\s+"; " ") | sub("^ +"; "") | sub(" +$"; "")
      | if length == 0 then error("reason is empty") else . end
      | if (explode | any(. < 32 or . == 127)) then error("control character in reason") else . end
      ' "$rf.invalid.json" 2>/dev/null); then
      RUN_INVALID_REASON=""
      RUN_INVALID_ERROR="$(basename "$rf").invalid.json must contain one JSON object with a nonblank string reason; exclusion rejected"
    else
      return 0
    fi
  fi
  if [ ! -s "$rf" ] && [ -e "$rf.failed" ]; then
    RUN_FAILURE_KIND=$(failure_kind "$rf.failed" "$rc")
    RUN_DELIVERY_KIND="$RUN_FAILURE_KIND"
    # The renderer calls empty timeouts no-output. Arithmetic must still
    # exclude a known harness clock kill, preserving the original wording.
    case "$rc" in 124|137) RUN_DELIVERY_KIND="" ;; esac
  fi
}

hit_rate_cell() { # <hit> <total> <unresolved>
  local hit="$1" total="$2" unresolved="$3"
  if [ "$total" -eq 0 ]; then echo '- (no eligible items)'
  elif [ "$unresolved" -gt 0 ]; then echo "$hit to $((hit + unresolved)) / $total ($unresolved UNRESOLVED)"
  else echo "$hit / $total"; fi
}

# These subsections belong AFTER Verdict, where the panel parser stops reading
# matrix rows. An operator's explanation can itself contain text like K1=HIT.
report_run_exclusions() { # <invalid-notes> <invalid-errors> <suspect-notes> <count>
  if [ -n "$1" ]; then
    echo "### Operator-invalid runs"
    echo
    echo "$4 run(s) excluded from both hit rates by operator assertion:"
    echo
    printf '%s\n' "$1"
  fi
  if [ -n "$2" ]; then
    echo "### Rejected invalid-run markers"
    echo
    printf '%s\n' "$2"
    echo "No exclusion was applied for these markers. Fix or remove them and re-grade."
    echo
  fi
  if [ -n "$3" ]; then
    echo "### Suspected answer-key leaks"
    echo
    printf '%s\n' "$3"
  fi
}

# review_findings() lives in lib/common.sh now: classify_run uses it too.

# ★ A judge that credits nothing in the key, lists no extras, and is reading a
# review that states two or more findings did not read that review. Measured: on
# a private pass one reviewer stated SEVEN findings, its own first heading being
# "1. blocking - autosave shows Saved without a successful save", and the judge
# returned verdict "no defects found" with extras []. Both of its key items
# really were misses by hand audit, which is exactly what makes it dangerous --
# the run scores plausibly while `extras`, the ONLY record of a reviewer finding
# a real defect the key never asked about, was silently zeroed. Across the 45
# runs graded before this check existed it fires once, with no false positives:
# every other empty-extras run credited a key item, so the judge demonstrably
# read those. HIT or DEFER both count as having read it -- a DEFER means the
# judge located the item and weighed it.
judge_incoherent() {
  local gf="$1" rf="$2"
  [ -s "$gf" ] && [ -s "$rf" ] || return 1
  [ "$(jq -r '[.items[]? | select(. == "HIT" or . == "DEFER")] | length' "$gf")" -eq 0 ] || return 1
  [ "$(jq -r '(.extras // []) | length' "$gf")" -eq 0 ] || return 1
  [ "$(review_findings "$rf")" -ge 2 ]
}

in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ★ Greedy 1:1 -- one finding may be credited to at most one key item. Stolen
# from mountainowl/bubo's benchmark matcher, whose rule is that duplicate
# comments cannot inflate true positives.
#
# Cadre's exposure runs the OTHER way from bubo's. Scoring is per key item, so N
# copies of one finding already credit an item once; what nothing stops is ONE
# vague sentence credited against SEVERAL items -- "this file has error-handling
# problems" against all three error-handling items in that file.
#
# `quotes` makes that checkable with no schema change. It is the reviewer's
# verbatim sentence behind each HIT/DEFER, so the SAME sentence under two items
# IS the collision. It was made mandatory to diagnose judge splits; this is the
# second thing it buys, and the comparison is the one at the split gate below
# transposed -- that asks one item across judges, this asks one judge across
# items.
#
# ★ Flag, never demote. One sentence can legitimately describe two key items
# ("both handlers swallow the exception"), so demoting the second to MISS would
# manufacture a false MISS -- worse than the inflation it fixes, because it
# penalises a correct review for being concise. Collided items go UNRESOLVED and
# are reported, the same no-tie-break posture as a judge split.
#
# Empty quotes are the trivial false positive here and are dropped before
# grouping: "" is what a MISS records, and treating it as a shared sentence
# would collide every miss in the pass with every other.
#
# ★ Measured on the 203 grade files on this box: it fires on ZERO of them -- but
# the honest denominator is 8, not 203. Only 8 files carry two or more QUOTED
# credits and are therefore even eligible to collide; 117 have no quoted credit
# at all, predating the day `quotes` became mandatory, and can never fire by
# construction. So this gate is cheap and has no observed false positives, and
# it is also close to unvalidated -- 0 of 8 is not the evidence 0 of 203 would
# look like. Recheck the number once a keyed corpus has grown.
quote_collisions() {
  local gf="$1"
  [ -s "$gf" ] || return 0
  jq -r '
    (.quotes // {}) as $q
    | [ (.items // {}) | to_entries[]
        | select(.value == "HIT" or .value == "DEFER")
        | { k: .key,
            q: (($q[.key] // "") | gsub("\\s+"; " ") | sub("^ +"; "") | sub(" +$"; "")) } ]
    | map(select(.q != "" and .q != "null"))
    | group_by(.q) | map(select(length > 1)) | flatten | map(.k) | .[]
  ' "$gf" 2>/dev/null
}

# ★ The EMPTY-receipt rule, pulled out of the report block so it can be proved.
# Its three "-" branches are not reachable through the gauntlet fixtures --
# `cadre run` writes prompt.txt itself, so an end-to-end test can never observe
# a missing receipt. Measured: the first cut of this feature shipped an
# "empty receipt is a dash" test that the run satisfied with a 1469-byte prompt,
# so it would have passed on a broken implementation and failed on a correct
# one. A rule that only ever runs in production is a rule nobody has checked.
#
# "-" is the answer for every case where a number would be a claim the
# measurement does not support:
#   no receipt at all      -- reconstructed rows carry EMPTY prompt_bytes, and a
#                             fabricated 0 would print the seat as free
#   any run missing one    -- one silent zero mixed into a real total averages
#                             the seat toward the floor, which is why slots.tsv
#                             leaves reconstructed prompt_bytes blank
#   zero blocking hits     -- a zero denominator is not infinite efficiency
# Never 0 and never a division result in those cases: both read as measurements.
cost_per_hit() {
  local bytes="$1" hits="$2" have="$3" empty="$4"
  [ -z "$empty" ] || { echo "-"; return; }
  [ "$have" -eq 0 ] && { echo "-"; return; }
  [ "$hits" -eq 0 ] && { echo "-"; return; }
  echo $(( bytes / 4 / hits ))
}

# Read only the grader's anchored footer fields. Missing/ambiguous legacy fields
# stay unavailable; never reconstruct spend or turn an unresolved range exact.
grade_report_metrics() { # <report>; sets METRIC_{LOW,HIGH,TOTAL,COST,PARTIAL,RATE,SPREAD,CAP,ROUNDS}
  local fields
  fields=$(awk '
    /^## Verdict: / {
      footer=1
      if ($0 ~ /^## Verdict: (INVALID|NOTHING|NOT MEASURED)/) unscored=1
      if ($0 ~ /^## Verdict: INCOMPLETE/) partial=1
    }
    !footer { next }
    /^- blocking items hit:/ { nh++; hits=$0 }
    /^- est\. tokens per blocking item hit:/ { nc++; cost=$0 }
    # Counted on the FIELD NAME, not on the bold marker: a second mention
    # written without ** would otherwise slip past the duplicate gate and let
    # the first line stand as unambiguous. Same rule the hit/cost fields use.
    /^- run-to-run spread \(blocking hit rate\):/ { ns++; sp=$0 }
    /^- output cap:/ { ncap++; capl=$0 }
    /^- rounds per pass behind the blocking hit rate:/ { nr++; rl=$0 }
    END {
      # Spread and cap are read whether or not the table scored: a cap mismatch
      # or a missing floor is a fact about the run, not about the verdict.
      # ★ Anchored END TO END, matching the exact sentence cadre writes.
      # A prefix match reads "- output cap: **2048 tokens** was the old
      # setting; not recorded now" as a measured 2048, which is operator prose
      # promoted to a number -- the failure the hit/cost patterns above are
      # already anchored against. An unrecognised line is "-", never a value.
      spread=cap=rounds="-"
      # Same end-to-end anchoring (#23). Legacy reports predate the line and
      # stay "-": an unknown round count is never read as enough of them.
      if (nr==1 && rl ~ /^- rounds per pass behind the blocking hit rate: \*\*[0-9]+\*\* \(the fewest scored runs any pass had\)(; below the floor of [0-9]+, so no seat is recommended from it)?$/) {
        sub(/^- rounds per pass behind the blocking hit rate: \*\*/, "", rl); sub(/\*\*.*$/, "", rl); rounds=rl
      }
      if (ns==1 && sp ~ /^- run-to-run spread \(blocking hit rate\): \*\*[0-9]+\.[0-9]pp\*\* \(run [0-9]+: [0-9]+\/[0-9]+.*\); a difference between two seats smaller than this is noise$/) {
        sub(/^- run-to-run spread \(blocking hit rate\): \*\*/, "", sp); sub(/pp\*\*.*$/, "", sp); spread=sp
      }
      if (ncap==1) {
        if (capl ~ /^- output cap: \*\*[0-9]+ tokens\*\* \(declared by the adapter on every scored run\)$/) {
          sub(/^- output cap: \*\*/, "", capl); sub(/ tokens\*\*.*$/, "", capl); cap=capl
        } else if (capl ~ /^- output cap: \*\*mixed\*\* \(.*\); the scored runs were not cap-matched, so their rates are not one measurement$/) cap="mixed"
      }
      lo=hi=total=spend="-"
      if (nc==1 && cost ~ /^- est\. tokens per blocking item hit: \*\*([0-9]+|-)\*\* \(partial denominator\)$/) partial=1
      if (!unscored && nh==1) {
        if (hits ~ /^- blocking items hit: \*\*[0-9]+ \/ [0-9]+\*\*$/ ||
            hits ~ /^- blocking items hit: \*\*[0-9]+ to [0-9]+ \/ [0-9]+\*\* \([0-9]+ UNRESOLVED\)$/) {
          sub(/^- blocking items hit: \*\*/, "", hits)
          split(hits, pair, " / ")
          total=pair[2]+0
          split(pair[1], range, " to ")
          lo=range[1]+0; hi=(range[2]=="" ? lo : range[2]+0)
          if (range[2]!="") {
            unresolved=hits
            sub(/^.*\*\* \(/, "", unresolved)
            sub(/ UNRESOLVED\)$/, "", unresolved)
            if (hi==lo || hi-lo!=unresolved+0) badrange=1
          }
          if (total<=0 || lo>hi || hi>total || badrange) lo=hi=total="-"
        }
        if (lo!="-" && lo>0 && nc==1 &&
            cost ~ /^- est\. tokens per blocking item hit: \*\*[0-9]+\*\*( \(partial denominator\))?$/) {
          sub(/^- est\. tokens per blocking item hit: \*\*/, "", cost)
          spend=cost+0
        }
      }
      print lo, hi, total, spend, partial+0, spread, cap, rounds
    }
  ' "$1")
  read -r METRIC_LOW METRIC_HIGH METRIC_TOTAL METRIC_COST METRIC_PARTIAL METRIC_SPREAD METRIC_CAP METRIC_ROUNDS <<< "$fields"
  METRIC_RATE='-'
  if [ "$METRIC_TOTAL" != - ]; then
    METRIC_RATE=$(awk -v lo="$METRIC_LOW" -v hi="$METRIC_HIGH" -v total="$METRIC_TOTAL" 'BEGIN {
      if (lo==hi) printf "%.1f%% (%d / %d)", 100*lo/total, lo, total
      else printf "%.1f%% to %.1f%% (%d to %d / %d; UNRESOLVED)", 100*lo/total, 100*hi/total, lo, hi, total
    }')
  fi
}

# The totals only exist after grading. Insert the summary atomically while
# retaining the first-line title that the panel uses to identify a report.
frontload_grade_cost() { # <finished-report>
  local report="$1" tmp title note=""
  grade_report_metrics "$report"
  [ "$METRIC_PARTIAL" -eq 0 ] || note=' (partial denominator)'
  tmp=$(mktemp "$report.summary.XXXXXX") || return 1
  IFS= read -r title < "$report"
  {
    printf '%s\n\n' "$title"
    echo "## Cost and hits (graded-only)"
    echo
    echo "- est. tokens per credited blocking hit: **$METRIC_COST**$note"
    # The round count on the rate's own line (#23), so no copy of the rate can
    # be lifted without it. A rate of "-" has nothing to qualify.
    if [ "$METRIC_RATE" = - ] || [ "$METRIC_ROUNDS" = - ]; then
      echo "- blocking hit rate: **$METRIC_RATE**$note"
    elif [ "$METRIC_ROUNDS" -lt "$ROUND_FLOOR" ]; then
      echo "- blocking hit rate: **$METRIC_RATE**$note over **$METRIC_ROUNDS** round(s) per pass; below the floor of $ROUND_FLOOR, one round's draw and not a reviewer property"
    else
      echo "- blocking hit rate: **$METRIC_RATE**$note over **$METRIC_ROUNDS** round(s) per pass"
    fi
    if [ "$METRIC_SPREAD" = - ]; then
      echo "- noise floor (run-to-run spread): **not measured**; no delta against another seat is distinguishable from noise"
    else
      echo "- noise floor (run-to-run spread): **${METRIC_SPREAD}pp**; a delta against another seat under this is noise"
    fi
    echo
    echo "Cost uses prompt and review bytes / 4 from scored keyed runs only. Delivery"
    echo "failures and CLEAN probes contribute no spend here. This is an estimate;"
    echo "\`-\` means unavailable or not scored."
    tail -n +2 "$report"
  } > "$tmp" && mv "$tmp" "$report" || { rm -f "$tmp"; return 1; }
}

# ---- coverage-per-changeset (#5) --------------------------------------------
# Deterministic, uncorrelated signal the judges never produce: which files the
# change touched that a reviewer never mentioned. Scores what the reviewer
# DIDN'T look at, not what it found.
#
# ★ Every rail here exists because the naive version manufactures a false
# "you skipped files", and a false skip is worse than a missed real one:
#  - CREDITING a mention is the SAFE direction. Over-crediting only ever shrinks
#    the accusation; it never invents one. So the full-path test is a generous
#    substring, and the aim throughout is to under-accuse, never over-accuse.
#  - Basename matches ONLY as a bare token. `grep -F index.ts` fires inside
#    `src/a/index.ts`, so one full-path mention would silently credit every
#    changed file named index.ts. A shared basename cannot identify a file, so
#    both sharers go to an AMBIGUOUS bucket, counted in neither covered nor
#    uncovered rather than guessed into one.
#  - The escape covers EVERY non-word char. A filename with `+ ( ) { } ? | .`
#    (Next.js `(group)`/`[id]`) would otherwise be read as a regex and an
#    unbalanced `(` would error grep, dropping a real file to `uncovered`.
#  - `case`, never `printf | grep`, for the substring test: under `pipefail` a
#    `grep -q` that exits early SIGPIPEs the producer (exit 141), which on a
#    large review flips a real mention into a false "never mentioned".
#  - Empty denominator (no base, git failure, zero changed files) is "-", never
#    0/0 -- same rule cost_per_hit follows: a number would be a claim the
#    measurement does not support.
# ★ NAMED NON-GOAL: mention detection is TEXT matching, not comprehension. A
# reviewer can name a file without reviewing it. Coverage bounds attention from
# below (never mentioned => never reviewed); it does not certify a read.
changed_files() {  # <dir> <base> <sha> -> relative paths; empty on any failure
  local dir="$1" base="$2" sha="$3"
  [ -n "$base" ] || return 0
  git -C "$dir" diff --name-only "$base...$sha" 2>/dev/null
}

# coverage_scan <review-file> <changed-newline>; sets COV_* for the caller.
coverage_scan() {
  local review="$1" changed="$2"
  COV_TOTAL=0 COV_COVERED=0 COV_AMBIG=0 COV_UNCOVERED=0 COV_UNCOVERED_LIST=""
  [ -n "$changed" ] || return 0          # empty denominator -> caller prints "-"
  local body; body=$(cat "$review" 2>/dev/null)
  local f bn ebn nshare
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    COV_TOTAL=$((COV_TOTAL + 1))
    bn=${f##*/}
    ebn=$(printf '%s' "$bn" | sed 's/[^[:alnum:]_-]/\\&/g')
    if case "$body" in *"$f"*) true ;; *) false ;; esac; then
      COV_COVERED=$((COV_COVERED + 1))
    elif grep -qE -- "(^|[^A-Za-z0-9_/.-])$ebn([^A-Za-z0-9]|\$)" <<<"$body"; then
      nshare=$(printf '%s\n' "$changed" | awk -v b="$bn" 'BEGIN{n=0}{p=$0;sub(/.*\//,"",p);if(p==b)n++}END{print n}')
      if [ "$nshare" -ge 2 ]; then COV_AMBIG=$((COV_AMBIG + 1))
      else COV_COVERED=$((COV_COVERED + 1)); fi
    else
      COV_UNCOVERED=$((COV_UNCOVERED + 1))
      COV_UNCOVERED_LIST="${COV_UNCOVERED_LIST:+$COV_UNCOVERED_LIST, }$f"
    fi
  done <<< "$changed"
}

# Anchor checks deliberately use a separate, stricter matcher than mentions.
# A substring may safely CREDIT attention; it cannot safely accuse drift.
# Only literal full paths / unique basenames and supported line syntax count.
# Per-file diffs avoid inferring file identity from quoted patch headers.
anchor_scan() { # <review> <repo> <base> <sha>; sets ANCHOR_* (advisory only)
  local review="$1" dir="$2" base="$3" sha="$4" paths treepaths oldtree f bn shares blockers patch result
  ANCHOR_CHECKED=0 ANCHOR_DRIFT=0 ANCHOR_DRIFT_LIST=""
  ANCHOR_UNRESOLVED=0 ANCHOR_UNRESOLVED_LIST=""
  [ -n "$base" ] && [ -r "$review" ] || return 0
  # Keep Git's C-quoted unusual paths out of this newline-based interface.
  # Tabs/newlines/backslashes/quotes in names are unavailable, never drift.
  paths=$(git -C "$dir" -c core.quotePath=false diff --name-only --no-renames "$base...$sha" 2>/dev/null) || return 0
  oldtree=$(git -C "$dir" merge-base "$base" "$sha" 2>/dev/null) || return 0
  treepaths=$(git -C "$dir" -c core.quotePath=false ls-tree -r --name-only "$oldtree" 2>/dev/null) || return 0
  treepaths+=$'\n'$(git -C "$dir" -c core.quotePath=false ls-tree -r --name-only "$sha" 2>/dev/null) || return 0
  treepaths=$(LC_ALL=C sort -u <<< "$treepaths")
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in *\\*|*\"*|*$'\t'*) continue ;; esac
    bn=${f##*/}
    shares=$(awk -v b="$bn" '{p=$0; sub(/.*\//,"",p); if(p==b)n++} END{print n+0}' <<< "$treepaths")
    # A space/backtick/apostrophe can be filename text as well as a delimiter.
    # Do not fragment a known longer name into this file's shorter citation.
    blockers=$(awk -v f="$f" -v b="$bn" '
      function suffix(s,t){return length(s)>length(t) && substr(s,length(s)-length(t)+1)==t}
      {p=$0; sub(/.*\//,"",p); if(suffix($0,f) || suffix($0,b)) print; if(suffix(p,b)) print p}
      ' <<< "$treepaths")
    patch=$(git -C "$dir" diff --no-ext-diff --no-textconv --no-renames --unified=3 "$base...$sha" -- ":(literal)$f" 2>/dev/null) || continue
    patch=$(awk '/^@@ /' <<< "$patch")
    local oldlen newlen
    # Line counts at both ends (#80): a coordinate past EOF at both revs was
    # invented, not drifted. NR, not wc -l: a last line with no newline counts.
    oldlen=$(git -C "$dir" cat-file -p "$oldtree:$f" 2>/dev/null | awk 'END { print NR }') || oldlen=0
    newlen=$(git -C "$dir" cat-file -p "$sha:$f" 2>/dev/null | awk 'END { print NR }') || newlen=0
    result=$(CADRE_ANCHOR_PATH="$f" CADRE_ANCHOR_BASENAME="$bn" CADRE_ANCHOR_PATCH="$patch" CADRE_ANCHOR_BLOCKERS="$blockers" \
      awk -v unique="$shares" -v oldlen="$oldlen" -v newlen="$newlen" \
        -f "$CADRE_ROOT/lib/anchor-scan.awk" "$review") || continue
    local checked drift unresolved anchors unresolved_anchors
    IFS=$'\t' read -r checked drift unresolved anchors unresolved_anchors <<< "$result"
    [ "$anchors" = "-" ] && anchors=""
    [ "$unresolved_anchors" = "-" ] && unresolved_anchors=""
    ANCHOR_CHECKED=$((ANCHOR_CHECKED + checked))
    ANCHOR_DRIFT=$((ANCHOR_DRIFT + drift))
    ANCHOR_UNRESOLVED=$((ANCHOR_UNRESOLVED + unresolved))
    [ -z "$anchors" ] || ANCHOR_DRIFT_LIST="${ANCHOR_DRIFT_LIST:+$ANCHOR_DRIFT_LIST, }$anchors"
    [ -z "$unresolved_anchors" ] || ANCHOR_UNRESOLVED_LIST="${ANCHOR_UNRESOLVED_LIST:+$ANCHOR_UNRESOLVED_LIST, }$unresolved_anchors"
  done <<< "$paths"
}

# ★ The round floor (#23). A rate from one round is one draw, not a property of
# the reviewer: nuhuh, where this comes from, published its own reversals --
# a seat at 0% on round one and 4.1% over three, another at 12.5% on round one
# and 6.8% over ninety. A round is one scored run of a pass, and the count
# behind a rate is the FEWEST any keyed pass contributed, because two run slots
# over different passes are one round of each (the equal-denominators trap the
# spread line already refuses). Below the floor a rate is still printed, with
# its round count, but no seat is recommended from it. Two, because it is the
# default run count and the least that can measure a spread at all.
ROUND_FLOOR=2

# Which band a hit count falls in. Named so the range logic can ask the question
# at both ends and compare, rather than duplicating the thresholds.
#
# ★ The bands describe a ROLE, not a rank. They used to be "primary" and
# "secondary", which is the language of first-string and second-string: a reader
# comparing two candidates concluded the primary was the better buy, when the
# whole argument of this tool is that the lower-scoring one may be the more
# valuable addition because it fails in different places. The question a band
# answers is narrower and more useful -- can this reviewer be the ONLY one
# looking at a change? -- so it says that instead.
slot_band() {
  local hit="$1" total="$2"
  if   [ "$total" -eq 0 ];            then echo inconclusive
  elif [ "$hit" -eq "$total" ];       then echo "can review alone"
  elif [ $((hit * 2)) -ge "$total" ]; then echo "needs a second reader"
  else                                     echo "do not slot"
  fi
}

# Severity comes from the key's item heading, so a new pass needs no code change.
key_severity() {
  local keyfile="$1" item="$2"
  grep -iE "^#+ *\*{0,2}$item\b|^\*{0,2}\*\*$item\*\*|^- \*\*$item\*\*" "$keyfile" \
    | head -1 | grep -oiE 'blocking|should-fix|nit' | head -1 | tr 'A-Z' 'a-z'
}

# Numeric order without sort -V, which BSD sort does not have.
key_items() { grep -oE '\bK[0-9]+\b' "$1" | sort -u | sed 's/^K//' | sort -n | sed 's/^/K/'; }

# ★ Every K item must own a HEADING carrying a severity word. Checking the file
# globally ("has a K somewhere, has the word blocking somewhere") passes a key
# whose headings are gone, because the Scoring rules section mentions K1 and K2
# in prose. Measured: a key was clobbered mid-write by a still-running
# make-pass, K1's heading was destroyed, `doctor` said "ok, 2 key items", and
# three graded runs scored that item with NO severity -- so a BLOCKING item was
# silently counted as unweighted and the slot verdict was computed from the
# wrong denominator. Prints one problem per line; empty output means usable.
# ★ A CLEAN pass has NO key items on purpose: nothing was planted, so the only
# thing it measures is what a reviewer wrongly flags. Stolen from
# mountainowl/bubo, whose corpus carries cases with an empty ground-truth array
# for exactly this. Cadre already records out-of-key findings as `extras`, but
# every key so far has items, so extras have only ever been a side channel next
# to a hit rate rather than the whole score.
#
# ★ It must DECLARE itself, and that is the entire design. An empty key file and
# a deliberately-clean one are otherwise byte-identical, and `key_problems`
# rejects an itemless key because of a measured incident: a key clobbered
# mid-write by a still-running make-pass lost K1's heading, `doctor` said "ok",
# and a blocking item was scored with no severity. Accepting "0 items" outright
# would re-open that hole in the worst place -- a clobbered key would score as a
# passed false-positive probe.
#
# ★ NAMED NON-GOAL: this narrows the hole, it does not close it. A write
# truncated AFTER the marker still looks exactly like a clean key. Nothing in
# the file format can tell those apart; what saves you is that the marker is a
# thing an author typed, not a thing a partial write produces.
key_is_clean() { grep -qiE '^#+ *\*{0,2}CLEAN\b' "$1"; }

key_problems() {
  local kf="$1" item sev
  [ -s "$kf" ] || { echo "key file is empty"; return; }
  local items; items=$(key_items "$kf")
  if key_is_clean "$kf"; then
    # Both at once is a contradiction, and silently honouring one of them is how
    # a half-edited key scores. Say which two things disagree.
    [ -z "$items" ] || echo "declares CLEAN but also lists $(printf '%s' "$items" | wc -w) key item(s)"
    return
  fi
  [ -n "$items" ] || { echo "no K1/K2… items"; return; }
  for item in $items; do
    if ! grep -qiE "^#+ *\*{0,2}$item\b" "$kf"; then
      echo "$item is referenced but has no '### $item - SEVERITY - …' heading"
      continue
    fi
    sev=$(key_severity "$kf" "$item")
    [ -n "$sev" ] || echo "$item's heading carries no BLOCKING/SHOULD-FIX/NIT severity word"
  done
}

# ---- two-sided key check (#23) ----------------------------------------------
# An item is only allowed into the benchmark once it is proved on both trees:
# present on the defective one, changed on the clean one. Without that, an item
# no reviewer could ever hit and an item that is not a defect at all look
# identical in the matrix -- both are just a K row -- and both bias the rate.
#
# The judge reads review text, so "the grading flags it" cannot be replayed
# without a model call. What CAN be checked without one is the thing the grade
# stands on: the item's own TARGET citation (keygen.md rule 7).
#   defective side: a cited `path:line` resolves in the target tree, so there
#                   is real code there for a reviewer to be pointed at
#   clean side:     the reference fix changes that line (three lines of
#                   context, the anchor_scan convention), so the clean tree does
#                   not still hold the code the item calls a defect
# One citation passing both is enough; the item's other citations may be
# context. Old side only: the key's coordinates are the target's, and a line
# number that only fits the fix is the rule-7 mistake this should catch.
# ★ NAMED NON-GOAL: this proves the item points at repaired code. It does not
# prove a judge scores a do-nothing review MISS or a review of the clean tree
# MISS; both of those need model calls, and none is made here.

# The item's heading and body, up to the next heading at its level or above.
key_item_text() { # <keyfile> <item>
  awk -v item="$2" '
    /^#/ {
      match($0, /^#+/); lv = RLENGTH
      if (on && lv <= start) exit
      if (!on && $0 ~ ("^#+ *[*]?[*]?" item "([^0-9A-Za-z_]|$)")) { on = 1; start = lv }
    }
    on { print }
  ' "$1"
}

# Prints one problem per line; empty output means every item is proved. Reuses
# lib/anchor-scan.awk, the literal-path citation matcher the grade report uses.
key_two_sided() { # <keyfile> <repo> <target-sha> <fix-sha>
  local kf="$1" dir="$2" target="$3" fix="$4" paths treepaths item text f bn shares blockers patch oldlen result
  local checked drift unresolved anchors unresolved_anchors seen green past outside
  key_is_clean "$kf" && return 0
  git -C "$dir" cat-file -e "$target^{commit}" 2>/dev/null || { echo "the target $target is not in $dir"; return; }
  git -C "$dir" cat-file -e "$fix^{commit}" 2>/dev/null || { echo "the reference fix $fix is not in $dir"; return; }
  # The files the FIX commit changed, diffed against the TARGET: the old side
  # is then in the key's coordinates even when commits landed in between.
  paths=$(git -C "$dir" -c core.quotePath=false diff --name-only --no-renames "$fix^" "$fix" 2>/dev/null) ||
    { echo "cannot read the reference fix $fix in $dir"; return; }
  treepaths=$(git -C "$dir" -c core.quotePath=false ls-tree -r --name-only "$target" 2>/dev/null) ||
    { echo "cannot list the target tree $target in $dir"; return; }
  for item in $(key_items "$kf"); do
    text=$(key_item_text "$kf" "$item")
    seen=0 green=0 past="" outside=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in *\\*|*\"*|*$'\t'*) continue ;; esac
      bn=${f##*/}
      shares=$(awk -v b="$bn" '{p=$0; sub(/.*\//,"",p); if(p==b)n++} END{print n+0}' <<< "$treepaths")
      blockers=$(awk -v f="$f" -v b="$bn" '
        function suffix(s,t){return length(s)>length(t) && substr(s,length(s)-length(t)+1)==t}
        {p=$0; sub(/.*\//,"",p); if(suffix($0,f) || suffix($0,b)) print; if(suffix(p,b)) print p}
        ' <<< "$treepaths")
      patch=$(git -C "$dir" diff --no-ext-diff --no-textconv --no-renames --unified=3 "$target" "$fix" -- ":(literal)$f" 2>/dev/null) || continue
      # Both sides of every hunk become the old side, so the matcher cannot
      # credit a citation that only fits the fixed file's numbering.
      patch=$(sed -nE 's/^@@ -([0-9]+(,[0-9]+)?) \+[0-9]+(,[0-9]+)? @@.*/@@ -\1 +\1 @@/p' <<< "$patch")
      oldlen=$(git -C "$dir" cat-file -p "$target:$f" 2>/dev/null | awk 'END { print NR }') || oldlen=0
      # newlen=0: past the end of the TARGET file is past the end, full stop.
      result=$(CADRE_ANCHOR_PATH="$f" CADRE_ANCHOR_BASENAME="$bn" CADRE_ANCHOR_PATCH="$patch" CADRE_ANCHOR_BLOCKERS="$blockers" \
        awk -v unique="$shares" -v oldlen="${oldlen:-0}" -v newlen=0 \
          -f "$CADRE_ROOT/lib/anchor-scan.awk" <<< "$text") || continue
      IFS=$'\t' read -r checked drift unresolved anchors unresolved_anchors <<< "$result"
      seen=$((seen + checked))
      green=$((green + checked - drift - unresolved))
      [ "$anchors" = - ] || outside="${outside:+$outside, }$anchors"
      [ "$unresolved_anchors" = - ] || past="${past:+$past, }$unresolved_anchors"
    done <<< "$paths"
    [ "$green" -eq 0 ] || continue
    if [ "$seen" -eq 0 ]; then
      echo "$item cites no path:line in a file the reference fix changes ($(printf '%s' "$paths" | paste -sd, - | sed 's/,/, /g')), so nothing ties it to the repair"
    else
      echo "$item has no citation the reference fix changes:${past:+ past the end of the file at the target: $past;}${outside:+ outside every line the fix changes, so the clean tree still holds that code: $outside;}" | sed 's/;$//'
    fi
  done
}

# The per-pass line the grade report prints, from what add-pass recorded.
two_sided_line() { # <label> <keyfile>
  local rec="$CADRE_HOME/passes.d/$1.two-sided" items proved="" added="" k
  items=$(key_items "$2")
  if [ ! -f "$rec" ]; then
    echo "Two-sided key check: not recorded (registered by hand, or before add-pass checked it), so no item here is proved to discriminate"
    return
  fi
  for k in $items; do
    if grep -qx -- "$k" "$rec"; then proved="${proved:+$proved, }$k"
    else added="${added:+$added, }$k"; fi
  done
  if [ -z "$added" ]; then
    echo "Two-sided key check: ${proved:-no item} proved at add-pass (each cites a target line the reference fix changes)"
  else
    echo "Two-sided key check: ${proved:-no item} proved at add-pass; ★ $added added to the key since, with no two-sided proof"
  fi
}

# run_gauntlet <agent-spec> <runs> <rescore 0|1> [pass-label]
run_gauntlet() {
  local spec="$1" runs="$2" rescore="$3" only="${4:-}"
  local requested_runs="$runs"
  local table_selection="${table_selection:-all-runs}" table_freeze="${table_freeze:-0}"
  case "$table_selection" in
    all-runs) ;;
    first-run) runs=1 ;;
    *) die "unknown table selection '$table_selection'" ;;
  esac
  local sl; sl=$(slug "$spec")
  # ★ One gauntlet per candidate at a time. Measured 2026-08-04: two `cadre run`
  # sweeps of the same candidate overlapped for half an hour. Same spec means
  # same artifact paths, so each sweep's classify-and-rename stole the other's
  # `.part` mid-run: the loser logged `mv: cannot stat` and filed FAILED for a
  # review that had completed, `already have it, skipping` and grade reuse then
  # laundered the winner's artifacts into the loser's report, which printed
  # graded rows for a pass its own console called "0 usable". Not one symptom
  # named the actual problem; every one pointed at the adapter. flock releases
  # with the process, so a kill leaves nothing to clean up; the mkdir fallback
  # (macOS has no flock) can leave a stale lock after a crash, and its message
  # says what to remove.
  local lockf="$CADRE_HOME/.gauntlet-$sl.lock"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lockf"
    flock -n 9 || die "another cadre run/grade of '$spec' is already running (lock: $lockf).
Two sweeps of one candidate share artifact paths and silently corrupt each
other's runs, grades, and report. Wait for the other sweep, or kill it, then re-run."
  else
    if ! mkdir "$lockf.d" 2>/dev/null; then
      die "another cadre run/grade of '$spec' appears to be running (lock: $lockf.d).
If it is not -- on systems without flock a crash can leave this behind --
remove that directory and re-run."
    fi
    # No other trap in cadre sets EXIT, so nothing is clobbered here.
    trap 'rmdir "$CADRE_HOME/.gauntlet-'"$sl"'.lock.d" 2>/dev/null' EXIT
  fi
  # ★ The JUDGE is in the grade filename and the report filename, for the reason
  # `1821318` put the adjudicator in the adjudication filename -- a lesson this
  # path had not learned. Keyed on the candidate alone, a second judge DELETES the
  # first one's grades (`rescore=1` does `rm -f "$gf"` right below) and overwrites
  # its report, so the one experiment that can validate this track -- run two
  # graders over the same reviews and compare per item -- destroys its own control
  # group as it runs. Slug the FULL spec, not spec_agent: `opencode:ollama/qwen3-judge`
  # and `opencode:ollama/qwen3:14b` are both `opencode` and would collide.
  local judges=(); mapfile -t judges < <(judge_specs)
  # ★ The slug of the WHOLE judge list, not of the first judge. A report
  # reconciles every judge that graded, so a report named after one of them lets
  # a (A,B) grading overwrite an (A,C) grading -- the same collision that
  # putting the judge in the filename was added to prevent, reintroduced one
  # level up the moment a second judge became possible. Identical to the old
  # name when there is one judge, so existing artifacts keep resolving.
  local jsl; jsl=$(slug "$(IFS=,; printf '%s' "${judges[*]}")")
  local report="$CADRE_HOME/report-$sl-by-$jsl.md"
  # ★ THIRD instance of one bug: a report named after less than what identifies
  # it. `45211c9` put the judge in the name, the block above put the whole judge
  # LIST in it, and the pass scope was still missing -- so `cadre run <spec> N
  # <label>`, the shape every overnight driver uses to sweep passes one at a
  # time, wrote all twelve reports to the same path. Each one truncated the last
  # (the block below opens with `>`), and the surviving artifact described the
  # final pass while being named as if it covered the gauntlet. Measured: a
  # twelve-pass sweep left a 933-byte report reading "0/0 items, 1 unusable run".
  local scoped=""
  if [ -n "$only" ]; then
    scoped=1
    report="$CADRE_HOME/report-$sl-by-$jsl-only-$(slug "$only").md"
  fi
  table_manifest_begin "$report" "$spec" "$requested_runs" "$table_selection" "$table_freeze" "$only" "${judges[@]}" || return 1
  local table_report="$report"
  report="$TABLE_STAGE/working-report.md"
  local blocking_hit=0 blocking_total=0 defer_on_blocking=0
  local total_hit=0 total_items=0 unusable=0 suspect=0 extras_all="" graded_passes=0 reference_used=0
  local delivery_miss=0 delivery_blocking_miss=0 delivery_no_output=0 delivery_failed=0
  local operator_invalid=0 invalid_notes="" invalid_errors="" suspect_notes=""
  local skipped="" nskipped=0 unquoted_defer=0
  local blocking_unresolved=0 total_unresolved=0 split_notes=""
  # Per-pass blocking tallies keyed by the pass's recorded language (#9), for
  # the observational slice at the end. One TSV line per graded pass.
  local lang_rows="" pass_lang="" pass_bhit=0 pass_btotal=0 pass_bunres=0
  # CLEAN passes are counted apart from the keyed score all the way through:
  # they share no denominator with it and must not share a column either.
  local clean_passes=0 clean_fp=0 clean_labels="" clean_extras=""
  # ★ Receipt accumulator for cost-per-hit. Same estimator as cadre receipts and
  # the panel receipt table: (prompt_bytes + review_bytes) / 4. prompt_bytes is
  # EMPTY when the pass never recorded a prompt (fixtures, reconstructed runs),
  # and EMPTY must stay EMPTY -- a fabricated 0 understates spend and makes the
  # seat look cheaper than the measurement supports.
  local receipt_prompt_bytes=0 receipt_review_bytes=0 receipt_empty="" receipt_have=0
  # ★ usable_runs is the only counter that answers "did anything get MEASURED",
  # and nothing tracked it. `graded_passes` counts passes the loop entered, and
  # blocking_total only grows inside the per-item loop a run reaches after every
  # usability check -- so a pass whose every run was UNUSABLE added 0 to the
  # numerator AND 0 to the denominator while still counting as graded. That is
  # the silent-denominator bug the nskipped guard was written for, still live on
  # the one path where it costs most: 11 of 12 passes producing nothing scored
  # 0/0 and reported INCONCLUSIVE, indistinguishable from a registry problem.
  local usable_runs=0 pass_usable=0 aborted="" measurement_failed="" nfiltered=0 window_closed="" misconfigured_seat=""
  # ★ Sweep-wide tally behind the fourth "nothing" verdict (#12). A NO OUTPUT
  # streak across every seat of a sweep is evidence about the PROVIDER, not the
  # candidate -- measured when every opencode-go model hung on `Reply with
  # exactly: OK` while a direct-provider model answered instantly. The existing
  # NOTHING MEASURED wording ("this says nothing about X") is true but reads as a
  # property of the model, which is the misread this issue is about.
  local no_output_runs=0 provider_empty=""
  # ★ The confounds the footer names BEFORE the score (#39). A run the cap cut
  # off or the provider left empty is an auto-fail whatever the model knows, so
  # a seat whose number is carried by them has a cap or provider problem, not a
  # model result. Counted here, printed above the hit line, never folded in.
  local cutoff_runs=0 empty_runs=0 capped_scored=0 caps_seen="" cap_unrecorded=""
  # Per run-slot blocking tallies across passes: run 1 over every pass is one
  # sweep of the set, run 2 another, and the spread between sweeps is the
  # candidate's own noise floor. Indexed by run number.
  local run_bhit=() run_btotal=() run_bunres=() run_passes=()
  # Fewest scored runs any pass with blocking items contributed (#23). EMPTY
  # until one does: no blocking item graded is no rounds, not zero of them.
  local min_rounds=""
  local regrade_changed_items=0 regrade_changed_runs=0 regrade_kept_runs=0
  # ★ Two failures that must not share an exit code, because the caller's correct
  # response to them is opposite. A missing REVIEW is fifteen minutes of a model's
  # time and the reason to stop a sweep. A review that exists but could not be
  # GRADED is a judge outage: the expensive artifact is safely on disk and one
  # cheap re-grade fixes it, so a sweep that quits there throws away hours of
  # review production to save one minute of grading. Collapsing them is how a
  # driver ends up treating an ollama hiccup at hour two as a reason to abandon
  # hour three onward.
  local pass_reviews=0 grading_failed=""
  # ★ Coverage is aggregated PER PASS, never pooled across passes: the whole
  # hypothesis is that coverage degrades as a changeset grows, so pooling a
  # 3-file pass with a 40-file one lets the big pass swamp the signal being
  # measured. cov_pct_sum/cov_npass is the mean of per-pass ratios; the worst
  # pass is named alongside. CLEAN passes are excluded from this aggregate, the
  # same rail cost-per-hit honours (a CLEAN probe is a different measurement).
  local cov_npass=0 cov_pct_sum=0 cov_worst=101 cov_worst_frac="" cov_worst_label=""

  {
    if [ -n "$scoped" ]; then
      echo "# One pass: \`$spec\` on \`$only\`"
      echo
      echo "**Scoped with a pass argument**, so everything below is over \`$only\`"
      echo "alone. Whether that left other registered passes out is stated in the"
      echo "verdict; run \`cadre grade $spec $runs\` with no pass argument for all of them."
    else
      echo "# Gauntlet: \`$spec\`"
    fi
    echo
    if [ "${#judges[@]}" -gt 1 ]; then
      echo "Judges: \`${judges[0]}\` and \`${judges[1]}\`. $runs run(s) per pass. Rubric: lib/prompts/judge.md."
      echo
      echo "Both graded every run. An item they agree on is the grade. An item they"
      echo "split on is **UNRESOLVED**: it scores nothing, and the split is evidence"
      echo "the KEY is underspecified rather than a tie to be broken."
    else
      echo "Judge: \`${judges[0]}\`. $runs run(s) per pass. Rubric: lib/prompts/judge.md."
    fi
    echo
  } > "$report"

  local label sha dir base key
  while IFS='|' read -r label sha dir base key; do
    case "$label" in ''|\#*) continue ;; esac
    # EDGES only. `tr -d ' '` also ate spaces inside paths, so a checkout under
    # a directory with a space read as missing and was silently skipped.
    label=$(trim "$label"); sha=$(trim "$sha"); dir=$(trim "$dir")
    base=$(trim "$base");   key=$(trim "$key")
    local keyfile="$key" target="$dir" pinned_sha
    case "$keyfile" in /*) ;; *) keyfile="$CADRE_HOME/$key" ;; esac
    case "$target" in /*) ;; *) target="$CADRE_HOME/$dir" ;; esac
    pinned_sha=$(git -C "$target" rev-parse --verify "$sha^{commit}" 2>/dev/null) || pinned_sha=""
    table_manifest_pass "$label" "$pinned_sha" "$keyfile" || return 1
    # ★ COUNT what the scope excluded. Scoping to the only registered pass
    # excluded nothing, and warning "this is not the benchmark" there would be a
    # false alarm on the smallest legitimate setup there is. The guard below asks
    # whether anything was actually left out, not whether an argument was passed.
    if [ -n "$only" ] && [ "$only" != "$label" ]; then
      table_manifest_exclude scope "$label" "" "Outside the requested pass scope: $only" || return 1
      nfiltered=$((nfiltered + 1)); continue
    fi

    # The sweep gave up on an earlier pass (see the abort below). Name every
    # pass that consequently never ran, rather than letting the report end where
    # the candidate stopped working and read as if that were the registry.
    if [ -n "$aborted" ]; then
      table_manifest_exclude not-attempted "$label" "" "The sweep aborted on $aborted" || return 1
      skipped="$skipped- $label: NOT ATTEMPTED, the sweep aborted on '$aborted'"$'\n'
      nskipped=$((nskipped + 1)); continue
    fi

    # ★ A skipped pass goes IN THE REPORT, not just the scrollback. Omitting it
    # silently shrank the denominator: one deleted checkout of two turned
    # "caught every blocking item in every run" into a claim about half the
    # benchmark, and the saved artifact carried no trace of the half that
    # never ran.
    if [ ! -f "$keyfile" ]; then
      table_manifest_exclude missing-key "$label" "" "Answer key is missing" || return 1
      echo "  $label: no key at $keyfile, NOT GRADED"
      skipped="$skipped- $label: key missing at $keyfile"$'\n'; nskipped=$((nskipped + 1))
      continue
    fi

    if [ ! -d "$target" ]; then
      table_manifest_exclude missing-checkout "$label" "" "Reviewed checkout is missing" || return 1
      echo "  $label: no checkout at $target, NOT GRADED"
      skipped="$skipped- $label: checkout missing at $target"$'\n'; nskipped=$((nskipped + 1))
      continue
    fi

    # Refuse at RUN time, not just in doctor. A key inside the reviewed tree is
    # the answer sitting in the reviewer's working copy.
    case "$(readlink -m "$keyfile")" in
      "$(readlink -m "$target")"/*)
        die "$label: the key is inside the reviewed checkout ($keyfile). Move it out of $target." ;;
    esac

    local prc=0
    if [ "$rescore" != 1 ]; then
      echo "==> $label: running $spec"
      # ★ Was `|| return 1`, which had never fired because run-pass.sh always
      # exited 0. Now that it reports 0-of-N, STOP: a candidate producing no
      # review on this pass will produce none on the next eleven either, and
      # grinding through them is the fifty silent minutes this whole change is
      # about. Recorded as a skipped pass so the denominator guard below sees it.
      CADRE_PASS_DIR="$target" CADRE_PASS_BASE="$base" \
        "$CADRE_ROOT/lib/run-pass.sh" "$label" "$sha" "$runs" "$spec" || prc=$?
    fi

    # Read delivery evidence even when dispatch aborts before grading. Later,
    # unattempted passes still take the aborted-sweep branch above and add no
    # denominator. Only .failed artifacts classified no-output/failed add MISS;
    # missing attempts, partials, inconclusive runs and judge outages do not.
    local items; items=$(key_items "$keyfile")
    local pass_record="$CADRE_HOME/$label/runs.jsonl" pass_runs=""
    pass_runs=$(record_rows "$pass_record" complete slug run state rc secs)
    local pass_meta; pass_meta=$(record_rows "$pass_record" complete slug run finish_reason completion_tokens output_cap)
    local run_leaks=() run_invalid=() run_failure_kinds=() n rf rec_rc k pass_invalid=0
    if [ "$table_selection" = first-run ]; then
      for ((n=2; n<=requested_runs; n++)); do
        table_manifest_exclude selection "$label" "$n" "first-run selects numbered run 1 only" || return 1
      done
    fi
    for n in $(seq 1 "$runs"); do
      rf="$CADRE_HOME/$label/$sl-run$n.md"
      rec_rc=$(awk -F '\t' -v s="$sl" -v r="$n" '$1 == s && $2 == r { v = $4 } END { print v }' <<< "$pass_runs")
      scan_run_evidence "$keyfile" "$rf" "$rec_rc"
      run_leaks[$n]="$RUN_LEAKED"
      run_invalid[$n]="$RUN_INVALID_REASON"
      run_failure_kinds[$n]="$RUN_FAILURE_KIND"
      if [ "$RUN_LEAKED" -ge 2 ]; then
        table_manifest_run "$label" "$n" suspect "" || return 1
        table_manifest_exclude suspect "$label" "$n" "Suspected answer-key leak; invalidates the whole table" || return 1
        suspect=$((suspect + 1))
        suspect_notes="$suspect_notes- $label run $n: SUSPECT, quotes $RUN_LEAKED key items verbatim; not scored, operator exclusion cannot override this."$'\n'
      elif [ -n "$RUN_INVALID_REASON" ]; then
        table_manifest_run "$label" "$n" operator-invalid "" || return 1
        table_manifest_exclude operator-invalid "$label" "$n" "$RUN_INVALID_REASON" || return 1
        operator_invalid=$((operator_invalid + 1))
        pass_invalid=$((pass_invalid + 1))
        invalid_notes="$invalid_notes- $label run $n: $RUN_INVALID_REASON"$'\n'
      else
        local table_run_status=pending-grade
        if [ ! -s "$rf" ]; then
          if [ -e "$rf.failed" ]; then
            table_run_status="${RUN_FAILURE_KIND:-failed}"
            case "$rec_rc" in 124|137) table_run_status=timed-out ;; esac
          elif [ -s "$rf.inconclusive" ]; then table_run_status=inconclusive
          elif [ -s "$rf.partial" ]; then table_run_status=partial
          else table_run_status=missing; fi
        fi
        # ★ Counted HERE, not in the grading loop below, because a pass that
        # aborted dispatch never reaches that loop -- and a footer printing
        # "0 cut off" over a pass whose own results hold one is the fabricated
        # zero this file refuses everywhere else. This loop runs before the
        # abort check, which is why the delivery counters already live in it.
        case "$table_run_status" in
          partial)   cutoff_runs=$((cutoff_runs + 1)) ;;
          no-output) empty_runs=$((empty_runs + 1)) ;;
        esac
        table_manifest_run "$label" "$n" "$table_run_status" "" || return 1
        case "$table_run_status" in
          pending-grade|failed|no-output) ;;
          *) table_manifest_exclude "$table_run_status" "$label" "$n" "No items scored: $table_run_status" || return 1 ;;
        esac
        [ -z "$RUN_INVALID_ERROR" ] || invalid_errors="$invalid_errors- $label run $n: $RUN_INVALID_ERROR"$'\n'
        case "$RUN_DELIVERY_KIND" in
          no-output|failed)
            [ -n "$items" ] || continue
            if [ "$RUN_DELIVERY_KIND" = no-output ]; then delivery_no_output=$((delivery_no_output + 1))
            else delivery_failed=$((delivery_failed + 1)); fi
            for k in $items; do
              delivery_miss=$((delivery_miss + 1))
              [ "$(key_severity "$keyfile" "$k")" != blocking ] || delivery_blocking_miss=$((delivery_blocking_miss + 1))
            done ;;
        esac
      fi
    done

    if [ "$prc" -ne 0 ]; then
      echo "  $label: run-pass.sh exited $prc, ABORTING the sweep here"
      nskipped=$((nskipped + 1)); aborted="$label"
      # ★ 6 aborts the sweep like 4 does, but it is not a failed measurement
      # and must not be reported as one: the cause is a provider usage window
      # that clears on its own, so the next move is to wait and resume, not to
      # go looking for a defect. Kept out of $measurement_failed for exactly
      # that reason -- see provider_window_closed() in lib/common.sh.
      if [ "$prc" -eq 6 ]; then
        skipped="$skipped- $label: NOT MEASURED, the provider's usage window closed (resume once it reopens)"$'\n'
        window_closed=1
      # ★ 7 gets the same treatment as 6 and for the same reason: the pass
      # measured nothing, but the cause is on the provider's side and clears
      # on its own, so calling it a failed measurement sends the operator
      # looking for a defect that is not there. This is the ONLY route by
      # which `cadre run` can reach the outage verdict -- it aborts here and
      # never reaches the grading loop that computes the other one.
      elif [ "$prc" -eq 7 ]; then
        skipped="$skipped- $label: NOT MEASURED, every run came back empty (suspect a provider outage)"$'\n'
        provider_empty=1
      # ★ 9 IS a failed measurement, unlike 6 and 7, because nothing clears
      # it but the operator -- but the sentence must send them to the roster
      # or the install, not to the candidate (#31).
      elif [ "$prc" -eq 9 ]; then
        skipped="$skipped- $label: NOT MEASURED, the seat is MISCONFIGURED on this box (not installed, bad spec, or no adapter); the reviewer was never called"$'\n'
        measurement_failed=1; misconfigured_seat=1
      else
        skipped="$skipped- $label: no usable review, run-pass.sh exited $prc"$'\n'
        measurement_failed=1
      fi
      continue
    fi

    echo "==> $label: grading"
    graded_passes=$((graded_passes + 1))
    pass_usable=0; pass_reviews=0
    # Changed-file set for this pass, computed once. Empty (no base resolvable,
    # git failure) leaves every coverage line a "-".
    local pass_changed passcov_runs=0 passcov_pctsum=0
    pass_changed=$(changed_files "$target" "$base" "$sha")
    # ref-* = public repo = contaminated. Warn in the report. passes/README.md.
    case "$label" in ref-*) reference_used=1 ;; esac
    # A clean pass measures the opposite thing from a keyed one, so it is tracked
    # apart from the first line of the section rather than being separated later.
    local pass_clean=""
    if key_is_clean "$keyfile"; then
      pass_clean=1; clean_passes=$((clean_passes + 1))
      clean_labels="${clean_labels:+$clean_labels, }$label"
    fi
    { echo "## $label${pass_clean:+ (CLEAN - false-positive probe, no planted defects)}"; echo; } >> "$report"

    # ★ The pass's run record, read ONCE (#2). Empty for a pass graded before
    # run-pass.sh wrote one, which is the legacy case the suffix-probing below
    # still exists to serve -- criterion 2's "edge-matching survives only as a
    # fallback". A pass with a record gets facts; a pass without gets the best
    # inference from filenames, and the two must not be confused for each other.
    # ★ Read from the RECORD, never re-detected here: the dispatch layer saw the
    # checkout the reviewers saw. A pass with no record, or one written before
    # the field, says so rather than getting a value invented at grade time.
    # ★ The LAST completion's value, not the last non-empty one: a slot can be
    # re-dispatched, and an older event's language must not outlive a newer
    # event that recorded none. Two nothings, told apart: a record whose last
    # completion carries the field EMPTY detected nothing (docs-only change);
    # a record with no field at all predates it, or there is no record.
    local pass_lang_field=""
    pass_lang=$(record_rows "$pass_record" complete language | tail -1)
    grep '"event":"complete"' "$pass_record" 2>/dev/null | tail -1 | grep -q '"language":' && pass_lang_field=1
    pass_bhit=0; pass_btotal=0; pass_bunres=0
    if [ -n "$pass_lang" ]; then
      { echo "Language: \`$pass_lang\` (dominant, by changed files; observational)"; echo; } >> "$report"
    elif [ -n "$pass_lang_field" ]; then
      { echo "Language: none detected (no recognisable source file changed)"; echo; } >> "$report"
    else
      { echo "Language: not recorded"; echo; } >> "$report"
    fi
    # Stated per pass (#23): an unproved item scores exactly like a proved one,
    # so the report is the only place the difference can show.
    [ -n "$pass_clean" ] || { two_sided_line "$label" "$keyfile"; echo; } >> "$report"
    for n in $(seq 1 "$runs"); do
      local rf="$CADRE_HOME/$label/$sl-run$n.md"
      if [ "${run_leaks[$n]:-0}" -ge 2 ]; then
        [ ! -s "$rf" ] || pass_reviews=$((pass_reviews + 1))
        echo "- run $n: **★ SUSPECT, quotes ${run_leaks[$n]} key items verbatim**, this reviewer" >> "$report"
        echo "  probably read the answer key rather than finding the defects. NOT scored." >> "$report"
        continue
      fi
      if [ -n "${run_invalid[$n]:-}" ]; then
        echo "- run $n: **OPERATOR-INVALID**, excluded from both hit rates; see Operator-invalid runs." >> "$report"
        continue
      fi
      # A requested run with no output is a FAILED run, not one that never
      # happened. Skipping it let 1 good run of 2 report "every blocking item in
      # every run" and earn a review-alone seat.
      if [ ! -s "$rf" ]; then
        unusable=$((unusable + 1))
        # Which kind of nothing. "no output" for a run that stopped partway is
        # a false statement about the model, and the fix is one file test.
        local why="no output"
        [ -s "$rf.partial" ] && why="stopped early, partial review in $sl-run$n.md.partial, not scored"
        # ★ .failed is always from the attempt that just ran. .partial can be
        # left over from an EARLIER attempt at the same slot, because a failed
        # attempt no longer clears it -- so letting .partial win reported
        # "stopped early" for a model whose last attempt died outright. That is
        # the same false-statement-about-the-model this block exists to prevent,
        # reintroduced by the fix that stopped deleting partials. Newest wins,
        # and the older artifact still gets named rather than quietly dropped.
        # ★ Between .partial and .failed, and it says something different from
        # both: the adapter did NOT fail and the model did NOT stop early. It
        # ran to completion and never reviewed. Calling that "the adapter
        # failed" is the same false-statement-about-the-model this block exists
        # to prevent, and it is the version that costs the most, because it
        # sends the reader to the adapter for a roster problem.
        # ★ ...and it names a surviving .partial for the same reason the .failed
        # branch does. `.partial` is deliberately kept across attempts while
        # `.inconclusive` is cleared, so an earlier attempt's partial review --
        # which has real findings in it -- can still be on disk. Reporting only
        # "no review" would bury it.
        if [ -s "$rf.inconclusive" ]; then
          why="ran but returned no review, see $sl-run$n.md.inconclusive, not scored"
          [ -s "$rf.partial" ] && why="$why (an earlier attempt stopped early, see $sl-run$n.md.partial)"
        fi
        # ★ "the adapter failed" was a claim, not an observation (#12). The same
        # line covered a provider that returned nothing, a live adapter killed
        # by cadre's own clock, and a real adapter crash -- and it sent the
        # reader to the adapter for all three.
        # ★ #12 had to leave the TIMEOUT case unclaimed here, because the exit
        # code was gone by grade time and guessing one from bytes would be the
        # same manufactured verdict pointed the other way. The record carries
        # `rc`, so that gap closes: a pass with a record can name a clock kill
        # at grade time, and a pass without one still declines to guess.
        # ★ Keyed on SEAT AND RUN, and taking the LAST match. Both halves are
        # required and each was a way to describe this artifact with somebody
        # else's exit code:
        #  - `runs.jsonl` lives at $CADRE_HOME/$label/ and is SHARED BY EVERY
        #    CANDIDATE on that pass, so `run == 1` alone matches run 1 of every
        #    seat ever benchmarked there. Grading `waffle` would read `terse`'s
        #    rc, with no re-run involved at all.
        #  - the record is append-only and `cadre run` re-dispatches any slot
        #    whose .md is missing, so one seat's run 1 can hold several
        #    completions. The artifact on disk is the LAST attempt's.
        # Either mistake reports "TIMED OUT -- cadre's own clock killed it"
        # about a run that simply crashed, which is the manufactured verdict #12
        # exists to kill, arriving through the record instead of through prose.
        # Same last-wins rail as `.meta`, for the same reason.
        # ★ -e, not -s. A hung provider that wrote nothing to stdout OR stderr
        # leaves run-pass.sh a 0-byte `.part` to rename, so the truest form of
        # "the provider returned nothing" is the one a `-s` gate skips entirely:
        # the branch never ran, the count never incremented, and a sweep of pure
        # silence was the one shape that could not reach the outage verdict.
        # Every other artifact test in this block stays `-s` on purpose -- an
        # empty .partial or .inconclusive really is nothing to report.
        if [ -e "$rf.failed" ]; then
          case "${run_failure_kinds[$n]}" in
            misconfigured)
              why="MISCONFIGURED on this box, the reviewer was never called: $(misconfigured_line "$rf.failed" | cut -c1-120)" ;;
            no-output)
              why="the provider returned NOTHING (no content in $sl-run$n.md.failed)"
              no_output_runs=$((no_output_runs + 1)) ;;
            # Only reachable with a record: `rec_rc` is empty otherwise and
            # failure_kind declines to claim a timeout without one.
            timed-out)
              why="TIMED OUT -- cadre's own clock killed it, not a verdict on the model; raise CADRE_TIMEOUT and re-run (see $sl-run$n.md.failed)" ;;
            *)
              why="the run produced output but no usable review, see $sl-run$n.md.failed" ;;
          esac
          [ -s "$rf.partial" ] && why="$why (an earlier attempt stopped early, see $sl-run$n.md.partial)"
        fi
        echo "- run $n: **UNUSABLE** ($why)" >> "$report"
        continue
      fi
      # The review itself exists. Whatever happens from here is downstream of the
      # expensive part, so it is cheap to redo and must not read as a lost run.
      pass_reviews=$((pass_reviews + 1))
      # ---- coverage of the changeset by THIS review (#5) ----------------------
      # Runs after the leak gate, so a SUSPECT review (which `continue`d above)
      # never earns coverage credit for files it may have read from the key.
      coverage_scan "$rf" "$pass_changed"
      local cov_denom=$((COV_COVERED + COV_UNCOVERED))
      if [ "$COV_TOTAL" -eq 0 ] || [ "$cov_denom" -eq 0 ]; then
        # No changeset, or every changed file was ambiguous: "-", never 0/0 (a
        # ratio the measurement cannot support), same rule cost_per_hit follows.
        local why="no changeset to measure against"
        [ "$COV_TOTAL" -gt 0 ] && why="all $COV_AMBIG changed file(s) ambiguous by shared basename"
        echo "- run $n coverage: — ($why)" >> "$report"
      else
        local cov_line="- run $n coverage: $COV_COVERED/$cov_denom changed files mentioned"
        [ "$COV_AMBIG" -gt 0 ] && cov_line="$cov_line ($COV_AMBIG ambiguous, shared basename)"
        echo "$cov_line" >> "$report"
        [ "$COV_UNCOVERED" -gt 0 ] && echo "  - never mentioned: $COV_UNCOVERED_LIST" >> "$report"
        passcov_runs=$((passcov_runs + 1))
        passcov_pctsum=$((passcov_pctsum + (100 * COV_COVERED / cov_denom)))
      fi

      anchor_scan "$rf" "$target" "$base" "$sha"
      if [ "$ANCHOR_CHECKED" -gt 0 ]; then
        echo "- run $n anchor positions: $ANCHOR_DRIFT/$ANCHOR_CHECKED outside diff hunks (possible position drift; advisory); $ANCHOR_UNRESOLVED/$ANCHOR_CHECKED past end of file (unresolved coordinate)" >> "$report"
        [ "$ANCHOR_DRIFT" -eq 0 ] || echo "  - outside hunks: $ANCHOR_DRIFT_LIST" >> "$report"
        [ "$ANCHOR_UNRESOLVED" -eq 0 ] || echo "  - past end of file: $ANCHOR_UNRESOLVED_LIST" >> "$report"
      else
        echo "- run $n anchor positions: — (no supported anchors with resolvable text hunks)" >> "$report"
      fi

      # ---- grade this run with EVERY judge ------------------------------------
      # `cadre grade` means RE-grade. A stale grade file would make a corrected
      # key produce identical numbers, the one thing a rescore rules out.
      #
      # ★ But grade to a SIDE FILE and swap, rather than deleting first. The old
      # order deleted the existing grade and then made a network call that can
      # take minutes -- so a rescore interrupted at any point in that window
      # destroyed a grade and produced nothing to replace it. Measured: a
      # re-grade of nine runs was killed by an outer timeout and left three of
      # them simply gone. A judge outage does the same thing more quietly. This
      # is the same delete-before-write shape that `45211c9` fixed one layer up,
      # and losing a graded artifact is the most expensive failure here: the
      # review can be re-graded, but a baseline nobody kept cannot be recovered.
      local gfs=() all_gfs=() bad="" savedj="$CADRE_JUDGE"
      local kept="" unrecorded="" regrade_notes="" run_regraded=0
      local j js gf
      for j in "${judges[@]}"; do
        CADRE_JUDGE="$j"
        js=$(slug "$j")
        gf="$CADRE_HOME/$label/$sl-run$n.by-$js.grade.json"
        all_gfs+=("$gf")
        if [ "$rescore" = 1 ] || [ ! -s "$gf" ]; then
          grade_one "$keyfile" "$rf" "$gf.new"
          if [ -s "$gf.new" ]; then
            # ★ (#39) A regrade writes BESIDE the prior grade before it writes
            # over it, and a regrade that came back UNUSABLE never writes over
            # it at all. The old order swapped whatever the judge returned in,
            # so one rate-limited re-grade replaced nine usable grades with
            # `{"unusable":true}` and the baseline was gone. Now the prior stays
            # on disk, is NOT scored on this pass (it was graded against inputs
            # that may have moved), and the ledger says which happened.
            local prior_ok=0 next_ok=1
            [ -s "$gf" ] && [ "$(jq -r '.unusable // false' "$gf" 2>/dev/null)" = false ] && prior_ok=1
            [ "$(jq -r '.unusable // false' "$gf.new" 2>/dev/null)" = true ] && next_ok=0
            if [ "$prior_ok" -eq 1 ] && [ "$next_ok" -eq 0 ]; then
              if regrade_ledger "$gf" "$gf.new" "$j" "$keyfile" 1; then
                if [ -s "$gf.new.judge-raw" ]; then mv -f "$gf.new.judge-raw" "$gf.regrade-failed.judge-raw"
                else rm -f "$gf.regrade-failed.judge-raw"; fi
                kept="$kept $j"
                rm -f "$gf.new" "$gf.new.judge-raw"
              else
                # ★ The ledger failing does not make the reply worthless, and
                # a stale .unapplied.json from an EARLIER attempt left here
                # makes the report name the wrong artifact. Newest wins, the
                # same rail .partial vs .failed follows above.
                mv -f "$gf.new" "$gf.unapplied.json"
                if [ -s "$gf.new.judge-raw" ]; then mv -f "$gf.new.judge-raw" "$gf.unapplied.judge-raw"
                else rm -f "$gf.unapplied.judge-raw"; fi
                unrecorded="$unrecorded $j"
              fi
            elif regrade_ledger "$gf" "$gf.new" "$j" "$keyfile" 0; then
              if [ "$REGRADE_CHANGED" -gt 0 ]; then
                regrade_notes="$regrade_notes- $j: $REGRADE_CHANGES (ledger: $(basename "$gf").regraded.jsonl)"$'\n'
                regrade_changed_items=$((regrade_changed_items + REGRADE_CHANGED)); run_regraded=1
              fi
              mv -f "$gf.new" "$gf"
              rm -f "$gf.regrade-failed.judge-raw" "$gf.unapplied.json" "$gf.unapplied.judge-raw"
              if [ -s "$gf.new.judge-raw" ]; then mv -f "$gf.new.judge-raw" "$gf.judge-raw"
              else rm -f "$gf.judge-raw"; fi
            else
              # ★ The judge's reply is KEPT, not deleted. The ledger failing is
              # a harness fault, and answering it by destroying the call the
              # operator paid for is the same overwrite pointed the other way.
              mv -f "$gf.new" "$gf.unapplied.json"
              if [ -s "$gf.new.judge-raw" ]; then mv -f "$gf.new.judge-raw" "$gf.unapplied.judge-raw"
              else rm -f "$gf.unapplied.judge-raw"; fi
              unrecorded="$unrecorded $j"
            fi
          else
            rm -f "$gf.new" "$gf.new.judge-raw"
          fi
        fi
        if in_list "$j" "$kept"; then
          local why3="empty, truncated, or an error"
          if [ -s "$gf.regrade-failed.judge-raw" ]; then
            why3="its reply did not parse, see $(basename "$gf").regrade-failed.judge-raw"
            rate_limited "$gf.regrade-failed.judge-raw" &&
              why3="★ RATE-LIMITED or OUT OF QUOTA after ${CADRE_RETRIES:-3} attempts, a judge outage and NOT a fact about the candidate"
          fi
          bad="$bad$j: the regrade returned $why3; the PRIOR grade is kept on disk unscored (see $(basename "$gf").regraded.jsonl), re-run cadre grade; "
        elif in_list "$j" "$unrecorded"; then
          bad="$bad$j: could not append $(basename "$gf").regraded.jsonl, so the new grade was NOT applied and the prior stands unscored; the new grade is kept at $(basename "$gf").unapplied.json; "
        elif [ ! -s "$gf" ] || [ "$(jq -r '.unusable // false' "$gf")" = true ]; then
          local why2="empty, truncated, or an error, NOT a clean pass"
          if [ -s "$gf.judge-raw" ]; then
            why2="its reply did not parse, see $(basename "$gf").judge-raw"
            # ★ An EXHAUSTED judge is not a broken judge, and saying "did not parse"
            # about a quota message is the mislabeling this tool exists to catch.
            # grade_one already retried and gave up, so the raw is the provider's
            # refusal, not JSON that came out wrong. Measured: copilot replied "You
            # have exceeded your monthly quota" on all nine runs of a second-grader
            # comparison and the report blamed its JSON -- which sent the reader
            # looking for a wrapper bug in an adapter that was working fine.
            rate_limited "$gf.judge-raw" &&
              why2="★ RATE-LIMITED or OUT OF QUOTA after ${CADRE_RETRIES:-3} attempts, so this is a judge outage and NOT a fact about the candidate"
          fi
          bad="$bad$j: $why2; "
        elif judge_incoherent "$gf" "$rf"; then
          # Not scored rather than scored wrong: see judge_incoherent. The item
          # verdicts on such a run may happen to be right, but they were not
          # reliably arrived at, and a re-grade is one command.
          bad="$bad$j: credited no key item and listed no extras against a review stating $(review_findings "$rf") findings, so it did not read this review; "
        else
          gfs+=("$gf")
        fi
      done
      CADRE_JUDGE="$savedj"
      # ★ Exit 5, not 0. A refused regrade takes a run that WAS scored out of
      # this table's denominator, so a sweep that keeps priors and then exits
      # green reports a shrunken benchmark as a clean one. 5 is the right code
      # rather than 4: the review is on disk and untouched, so the caller
      # re-grades and does not re-review -- which is exactly what this branch
      # did to the grade.
      [ -z "$kept" ] || { regrade_kept_runs=$((regrade_kept_runs + 1)); grading_failed=1; }
      # ★ Counted with the ITEMS, ahead of the usability gate below. A grade
      # that moved was written to disk whether or not the OTHER judge then
      # failed, so gating the run count on a scored run reported "1 item
      # across 0 runs" -- a count of a population the other number is not from.
      [ "$run_regraded" -eq 0 ] || regrade_changed_runs=$((regrade_changed_runs + 1))

      # ★ EVERY judge has to have produced a usable grade. Reconciling one
      # judge's reading against a missing one is a single-judge score wearing a
      # two-judge label, and an outage is not a measurement. The usable grade
      # stays on disk, so a re-grade after the quota resets costs one call.
      if [ -n "$bad" ]; then
        table_manifest_run "$label" "$n" grading-failed "" "${all_gfs[@]}" || return 1
        table_manifest_exclude grading-failed "$label" "$n" "One or more judges did not produce a usable grade" || return 1
        unusable=$((unusable + 1))
        echo "- run $n: **UNUSABLE** (${bad%; })" >> "$report"
        [ "${#gfs[@]}" -gt 0 ] &&
          echo "  The other judge's grade is on disk and was NOT discarded; \`cadre grade --rescore\` re-runs only what is missing." >> "$report"
        continue
      fi
      pass_usable=$((pass_usable + 1)); usable_runs=$((usable_runs + 1))
      # ★ WHICH passes this slot graded, not how many items. Equal denominators
      # do not prove equal contents: pass A scoring only in slot 1 and pass B
      # only in slot 2 gives both slots the same item count over completely
      # different items, and the gap between their rates is then 100% of the
      # difference between two passes. A usable run grades every item of its
      # pass, so the label list IS the item set.
      run_passes[$n]="${run_passes[$n]:-} $label"

      # ★ What the record says about HOW this scored run ended (#39). Last
      # completion for this seat and run, same last-wins rail as `rc` above.
      # A declared `length` finish is a review the cap cut that the adapter did
      # not mark partial: scored, since the findings are real, but named, since
      # its silence past the cut is not clearance. The cap itself is collected
      # so the footer can say whether the runs were cap-matched at all.
      local run_finish run_ctok run_cap
      IFS=$'\t' read -r run_finish run_ctok run_cap < <(awk -F '\t' -v OFS='\t' -v s="$sl" -v r="$n" \
        '$1 == s && $2 == r { f = $3; t = $4; c = $5 } END { print (f == "" ? "-" : f), (t == "" ? "-" : t), (c == "" ? "-" : c) }' <<< "$pass_meta")
      if [ "$run_finish" = length ]; then
        capped_scored=$((capped_scored + 1))
        echo "- run $n: ★ the adapter reports the OUTPUT CAP was hit (finish_reason=length$([ "$run_ctok" != - ] && echo ", $run_ctok tokens")$([ "$run_cap" != - ] && echo " of a $run_cap cap")); scored, but silence past the cut is not clearance" >> "$report"
      fi
      if [ "$run_cap" = - ]; then cap_unrecorded=1
      else in_list "$run_cap" "$caps_seen" || caps_seen="$caps_seen $run_cap"; fi

      # ★ Harness-side receipt for this usable run. Only runs that contribute to
      # the hit count feed the cost-per-hit number: an unusable or suspect run is
      # not in the score, so its spend must not pad the numerator either.
      # ★ One EMPTY prompt voids the whole seat's cost-per-item. Mixing a real
      # measurement with a silent zero is the same average-toward-the-floor bug
      # slots.tsv avoids by leaving reconstructed prompt_bytes blank.
      # ★ A CLEAN pass pays no part of the cost-per-HIT, because it structurally
      # cannot produce one. On a mixed passes.conf -- the intended shape, since a
      # probe alone measures nothing worth seating -- letting its bytes into the
      # numerator charges spend from one experiment against hits from another,
      # and inflates the seat's cost by however many probes the corpus carries.
      # That is the same pooling METHOD.md forbids one paragraph up; spend is
      # part of the score. A clean-only gauntlet then reaches receipt_have=0 and
      # prints "-", which is the right answer for a run with no hits to cost.
      # Skipped entirely rather than voided: a probe with no prompt.txt is not a
      # missing measurement, it is a measurement that was never owed.
      if [ -z "$receipt_empty" ] && [ -z "$pass_clean" ]; then
        local pfile="$CADRE_HOME/$label/prompt.txt" pb rb
        if [ -s "$pfile" ]; then
          pb=$(wc -c < "$pfile" | tr -d ' ')
          rb=$(wc -c < "$rf" | tr -d ' ')
          receipt_prompt_bytes=$((receipt_prompt_bytes + pb))
          receipt_review_bytes=$((receipt_review_bytes + rb))
          receipt_have=1
        else
          receipt_empty=1
        fi
      fi

      # Union across judges: a collision in ANY grade file means at least one
      # grader's credit is doubled, and letting the clean judge overrule it
      # would be the tie-break the gate below refuses to make.
      local collided="" cg
      for cg in "${gfs[@]}"; do
        collided="$collided $(quote_collisions "$cg" | tr '\n' ' ')"
      done

      local row="" k v sev
      for k in $items; do
        sev=$(key_severity "$keyfile" "$k")
        # ★ THE GATE. Every judge's verdict on this item; they agree or it is
        # UNRESOLVED. There is deliberately no tie-break: a tie-break makes one
        # grader authoritative for exactly the items where graders are known to
        # be unreliable, which is backwards. An UNRESOLVED item scores neither
        # way and is reported as a range, and the split is a finding about the
        # KEY -- the fix is tightening its credit boundary, not swapping judges.
        local vs=() gg
        for gg in "${gfs[@]}"; do
          vs+=("$(jq -r --arg k "$k" '.items[$k] // "MISS"' "$gg")")
        done
        v="${vs[0]}"
        local x
        for x in "${vs[@]}"; do [ "$x" = "$v" ] || v=UNRESOLVED; done
        # A finding credited twice is not evidence twice. See quote_collisions().
        # This runs AFTER the split gate so it can only ever widen the range,
        # never resolve one the judges disagreed on.
        in_list "$k" "$collided" && v=UNRESOLVED

        total_items=$((total_items + 1))
        [ "$v" = HIT ]        && total_hit=$((total_hit + 1))
        [ "$v" = UNRESOLVED ] && total_unresolved=$((total_unresolved + 1))
        if [ "$sev" = blocking ]; then
          blocking_total=$((blocking_total + 1)); pass_btotal=$((pass_btotal + 1)); run_btotal[$n]=$(( ${run_btotal[$n]:-0} + 1 ))
          [ "$v" = HIT ]        && { blocking_hit=$((blocking_hit + 1)); pass_bhit=$((pass_bhit + 1)); run_bhit[$n]=$(( ${run_bhit[$n]:-0} + 1 )); }
          [ "$v" = UNRESOLVED ] && { blocking_unresolved=$((blocking_unresolved + 1)); pass_bunres=$((pass_bunres + 1)); run_bunres[$n]=$(( ${run_bunres[$n]:-0} + 1 )); }
          # ★ A DEFER disqualifies outright, so it must carry the sentence that
          # earned it. An unquoted DEFER cannot be re-checked by anyone, and
          # this harness's graders have split one item in three -- letting a
          # single unverifiable judge call zero a candidate is a grading
          # artifact wearing a safety rule's clothes. Flagged and NOT counted
          # as disqualifying; re-grade it. With two judges this needs BOTH to
          # have said DEFER (that is what reaching here means) and at least one
          # of them to have quoted where.
          if [ "$v" = DEFER ]; then
            local dq="" q1
            for gg in "${gfs[@]}"; do
              q1=$(jq -r --arg k "$k" '(.quotes[$k] // "") | gsub("\\s+"; " ")' "$gg")
              [ -n "$q1" ] && [ "$q1" != null ] && dq="$q1"
            done
            if [ -n "$dq" ]; then
              defer_on_blocking=$((defer_on_blocking + 1))
            else
              unquoted_defer=$((unquoted_defer + 1))
            fi
          fi
        fi
        row="$row $k=$v"
      done

      # The verdict line and extras come from every judge, because "the judge
      # found nothing out of key" is a per-judge fact and merging them would
      # invent a consensus that was never reached.
      local verdict="" ex="" i
      for i in "${!gfs[@]}"; do
        local vv xx
        vv=$(jq -r '.verdict // "none"' "${gfs[$i]}")
        xx=$(jq -r '(.extras // []) | join("; ")' "${gfs[$i]}")
        verdict="${verdict:+$verdict | }$vv"
        [ -n "$xx" ] && {
          ex="${ex:+$ex; }$xx"
          # ★ On a CLEAN pass an extra is not a bonus finding, it is the score:
          # there was nothing to find, so everything raised is a false positive.
          # Kept in its own list because pooling it with keyed extras would mix
          # "found something the key did not ask about" (often good) with
          # "flagged a defect that does not exist" (never good).
          if [ -n "$pass_clean" ]; then
            clean_fp=$((clean_fp + 1))
            clean_extras="$clean_extras- $label run $n (${judges[$i]}): $xx"$'\n'
          else
            extras_all="$extras_all- $label run $n (${judges[$i]}): $xx"$'\n'
          fi
        }
      done
      echo "- run $n:$row, verdict \"$verdict\"${ex:+, extras: $ex}" >> "$report"
      if [ -n "$regrade_notes" ]; then
        echo "  - ★ REGRADED, item verdicts moved from the prior grade (prior values kept in the ledger, never overwritten):" >> "$report"
        printf '%s' "$regrade_notes" | sed 's/^/    /' >> "$report"
      fi
      table_manifest_run "$label" "$n" "${pass_clean:+clean-}graded" "$row" "${gfs[@]}" || return 1

      # ★ Print the sentence that earned each HIT. Without it a grade is a verdict
      # nobody can re-check: two graders split on one item in three here and the
      # artifacts could not say whether they credited different sentences or read
      # the same one two ways, so only a human re-read could settle it -- which is
      # exactly the loop that stopped being self-correcting. An unquoted HIT is
      # still counted (the grade is the judge's to make) but it is marked, because
      # it is the shape a credit-by-adjacency takes.
      #
      # ★ On a split, print BOTH readings side by side. That is the whole payload
      # of this gate: seeing that two judges quoted DIFFERENT sentences tells you
      # the key's boundary is loose, and seeing them quote the SAME sentence two
      # ways tells you the wording is ambiguous. Those need different fixes, and
      # neither is "pick a judge".
      for k in $items; do
        local kv2=""
        for gg in "${gfs[@]}"; do
          kv2="$kv2 $(jq -r --arg k "$k" '.items[$k] // "MISS"' "$gg")"
        done
        # ★ Checked BEFORE the split gate, and it needs its own sentence. The
        # split wording below ("the judges read this item differently") is a
        # FALSE statement about a collision -- the judges may agree perfectly and
        # still both be crediting one finding twice. Reusing that line would put
        # a lie in the report, which is the failure mode the inconclusive work
        # was written up to avoid.
        if in_list "$k" "$collided"; then
          echo "  - $k **UNRESOLVED**, credited to a sentence that also credits another item, so one finding is being counted twice:" >> "$report"
          for i in "${!gfs[@]}"; do
            local cq cshare
            cq=$(jq -r --arg k "$k" '(.quotes[$k] // "") | gsub("\\s+"; " ")' "${gfs[$i]}")
            [ -n "$cq" ] && [ "$cq" != null ] || continue
            cshare=$(jq -r --arg q "$cq" '
              [ (.quotes // {}) | to_entries[]
                | select((.value | gsub("\\s+"; " ")) == $q) | .key ] | join(", ")' "${gfs[$i]}")
            echo "    - ${judges[$i]}: shared by $cshare ↳ \"$cq\"" >> "$report"
          done
          split_notes="$split_notes- $label run $n $k (one sentence credited to more than one item)"$'\n'
          continue
        fi
        local uniq2; uniq2=$(printf '%s\n' $kv2 | sort -u | grep -c .)
        if [ "$uniq2" -gt 1 ]; then
          echo "  - $k **UNRESOLVED**, the judges read this item differently, so it scores nothing:" >> "$report"
          for i in "${!gfs[@]}"; do
            local jv jq2
            jv=$(jq -r --arg k "$k" '.items[$k] // "MISS"' "${gfs[$i]}")
            jq2=$(jq -r --arg k "$k" '(.quotes[$k] // "") | gsub("\\s+"; " ")' "${gfs[$i]}")
            if [ -n "$jq2" ] && [ "$jq2" != null ]; then
              echo "    - ${judges[$i]}: $jv ↳ \"$jq2\"" >> "$report"
            else
              echo "    - ${judges[$i]}: $jv (no quote)" >> "$report"
            fi
          done
          split_notes="$split_notes- $label run $n $k ($(printf '%s' "$kv2" | sed 's/^ //; s/ / vs /g'))"$'\n'
          continue
        fi
        case "${kv2# }" in HIT*|DEFER*) ;; *) continue ;; esac
        for i in "${!gfs[@]}"; do
          local q; q=$(jq -r --arg k "$k" '(.quotes[$k] // "") | gsub("\\s+"; " ")' "${gfs[$i]}")
          local who=""; [ "${#gfs[@]}" -gt 1 ] && who=" (${judges[$i]})"
          if [ -n "$q" ] && [ "$q" != null ]; then
            echo "  - $k$who ↳ \"$q\"" >> "$report"
          else
            echo "  - $k$who ⚠ credited with NO quote, so this grade cannot be re-checked" >> "$report"
          fi
        done
      done
    done
    # Per-pass coverage into the candidate mean. KEYED passes only (a CLEAN
    # probe is a different measurement and stays out of the aggregate, the same
    # rail cost-per-hit follows); worst pass tracked with its own denominator so
    # the summary can name where coverage was thinnest, not just the average.
    if [ -z "$pass_clean" ] && [ "$passcov_runs" -gt 0 ]; then
      local pass_pct=$((passcov_pctsum / passcov_runs))
      cov_npass=$((cov_npass + 1)); cov_pct_sum=$((cov_pct_sum + pass_pct))
      if [ "$pass_pct" -lt "$cov_worst" ]; then
        cov_worst=$pass_pct; cov_worst_label="$label"; cov_worst_frac="$pass_pct%"
      fi
    fi

    # ★ A pass whose every run was UNUSABLE is a pass that did not happen. It
    # belongs with the missing keys and the deleted checkouts, because it has
    # exactly their effect on the arithmetic: nothing in the numerator, nothing
    # in the denominator, and a `graded_passes` tick that made the report look
    # like the benchmark ran. Counted as skipped so the guard below downgrades
    # the verdict instead of dressing a short denominator as a result.
    if [ "$pass_usable" -eq 0 ]; then
      echo "**No usable run on this pass, so it contributed no items to the graded-only score.**" >> "$report"
      nskipped=$((nskipped + 1)); graded_passes=$((graded_passes - 1))
      # ★ WHICH nothing. The reviews being on disk changes what the operator
      # should do and what a driver should do, so it changes the exit code too.
      if [ "$pass_invalid" -eq "$runs" ]; then
        skipped="$skipped- $label: every requested run was marked operator-invalid"$'\n'
        measurement_failed=1
      elif [ "$pass_reviews" -gt 0 ]; then
        echo "  $label: $pass_reviews review(s) on disk, but NONE could be graded"
        echo "The review(s) themselves exist. This is a grading failure, and \`cadre grade\` re-runs it." >> "$report"
        skipped="$skipped- $label: $pass_reviews review(s) exist but none was gradeable (re-grade, do not re-review)"$'\n'
        grading_failed=1
      else
        echo "  $label: every run was UNUSABLE, so this pass graded NOTHING"
        skipped="$skipped- $label: ran, but produced no usable review at all"$'\n'
        measurement_failed=1
      fi
    fi
    # Only a pass that scored something joins the slice; a pass that graded
    # nothing has no denominator to lend to a language.
    if [ "$pass_usable" -gt 0 ]; then
      lang_rows="$lang_rows${pass_lang:-unknown}	$label	$pass_bhit	$pass_btotal	$pass_bunres"$'\n'
      # A usable run grades every item of its pass, so pass_usable IS this
      # pass's round count behind the blocking rate.
      if [ "$pass_btotal" -gt 0 ] && { [ -z "$min_rounds" ] || [ "$pass_usable" -lt "$min_rounds" ]; }; then
        min_rounds=$pass_usable
      fi
    fi
    echo >> "$report"
  done < "$CADRE_HOME/passes.conf"

  table_manifest_totals "$blocking_hit" "$blocking_total" "$blocking_unresolved" \
    "$total_hit" "$total_items" "$total_unresolved" "$delivery_blocking_miss" "$delivery_miss" "$suspect" || return 1

  {
    echo "## Hit rates"
    echo
    if [ "$suspect" -gt 0 ]; then
      echo "Graded-only and delivery-inclusive: **NOT SCORED, answer-key leak suspected**."
    else
      echo "| basis | blocking items hit | all items hit |"
      echo "|---|---|---|"
      echo "| graded-only | $(hit_rate_cell "$blocking_hit" "$blocking_total" "$blocking_unresolved") | $(hit_rate_cell "$total_hit" "$total_items" "$total_unresolved") |"
      echo "| delivery-inclusive | $(hit_rate_cell "$blocking_hit" "$((blocking_total + delivery_blocking_miss))" "$blocking_unresolved") | $(hit_rate_cell "$total_hit" "$((total_items + delivery_miss))" "$total_unresolved") |"
    fi
    echo
    echo "Delivery-inclusive adds MISS on every key item for $delivery_no_output no-output and"
    echo "$delivery_failed failed run(s) with output but no usable review. These are delivery"
    echo "failures; an all-failed rate establishes no review quality. Misconfigured and"
    echo "timed-out runs, missing attempts, partials, inconclusive runs and judge outages"
    echo "add no items. CLEAN passes have no item denominator."
    echo
    echo "The verdict and per-item matrix retain graded-only semantics."
    echo
  } >> "$report"

  if [ "$graded_passes" -le 0 ]; then
    # ★ Two different nothings, and the old message said the wrong one. "Check
    # 'cadre passes'" sends the reader to the registry, which is right when the
    # registry is empty and actively misleading when the registry was fine and
    # the CANDIDATE produced nothing -- the case that actually happened. Exit 4
    # either way for the second one, so a driver piping stdout to /dev/null still
    # cannot record COMPLETED.
    if [ "$nskipped" -gt 0 ]; then
      # ★ And once more, the same split: were the REVIEWS produced or not. Both
      # verdicts refuse to state a number; they differ in what the operator does
      # next, which is the only thing the distinction is for.
      local head1="NOTHING MEASURED" body1 rc1=4
      body1="Not one usable review was graded, so this says nothing about \`$spec\`.
It is a failed measurement, and a failed measurement is not a result."
      if [ -n "$grading_failed" ] && [ -z "$measurement_failed" ]; then
        head1="NOTHING GRADED"; rc1=5
        body1="The reviews exist. Not one of them could be GRADED, so there is no score
here -- but nothing expensive was lost, and \`cadre grade $spec $runs\` re-runs
the judge over what is already on disk. Do not re-review."
      fi
      local tail1="Fix the cause and re-run. Do not quote a number from this file."
      # ★ The operator's own fault outranks every provider-shaped verdict below
      # (#31): a seat that is not installed will not come back after a reset
      # or an outage, and 4's "fix the cause" sends the reader to the tool.
      # Exit 9, matching run-pass.sh, so a driver can tell "install it" from
      # "file a bug" without reading the report.
      if [ -n "$misconfigured_seat" ] && [ -z "$grading_failed" ]; then
        head1="NOT MEASURED -- SEAT MISCONFIGURED"; rc1=9
        body1="The seat for \`$spec\` never ran on this box: not installed, a bad spec, or no
adapter. Nothing about the candidate was observed, so this says nothing about it."
        tail1="Fix the roster entry or the install, then re-run. Do not quote a number from
this file, and do not record a verdict about the candidate from it."
      fi
      # ★ A fourth nothing (#12), and it is a statement about the PROVIDER. Fires
      # only when EVERY failed run of the sweep came back content-empty: one
      # empty artifact is an ordinary failure, a clean sweep of them is an
      # outage, and the two need opposite responses (drop the seat vs. wait and
      # re-run). Checked before the window branch and gated on the same
      # grading_failed guard, so a sweep that actually produced reviews and only
      # failed to grade them still gets NOTHING GRADED.
      # ★ The denominator is $unusable -- EVERY unusable run of the sweep -- not
      # the failed ones alone. Against the failed-run count, a sweep of one empty
      # artifact plus three INCONCLUSIVE runs reads as 1-of-1 empty and blames a
      # provider for what is a roster problem: those three runs answered, they
      # just never reviewed. Widening the denominator makes the claim exactly as
      # strong as the words: nothing usable came back, and every last piece of
      # that nothing was empty.
      # ★ And it must be > 0. A sweep whose passes were all skipped for missing
      # keys has zero of both, and `0 -eq 0` would blame a provider never called.
      # ★ TWO routes reach this, and both are needed. `cadre grade` re-reads the
      # artifacts and computes it here; `cadre run` never gets here at all,
      # because run-pass.sh exit 7 aborts the sweep above -- so that path sets
      # the flag directly. A verdict only the rarer command can print is a
      # verdict the operator does not get.
      if [ -n "$provider_empty" ] ||
         { [ "$no_output_runs" -gt 0 ] && [ "$no_output_runs" -eq "$unusable" ]; }; then
        provider_empty=1
      fi
      if [ -n "$provider_empty" ] && [ -z "$grading_failed" ]; then
        # ★ Its own exit code, for the reason window-closed has one: a driver
        # piping stdout to /dev/null sees only this, and "wait for the provider,
        # nothing here is broken" is a different instruction from 4's "fix the
        # cause". Collapsing them is what makes a driver retry a real defect or
        # file a bug against a healthy tool.
        head1="NOT MEASURED -- PROVIDER RETURNED NOTHING"; rc1=7
        body1="Every failed run on this sweep came back EMPTY -- $no_output_runs of them, no
content at all after CLI chrome is stripped. That pattern is evidence about the
PROVIDER, not about \`$spec\`: a model that is answering normally does not return
zero bytes to every seat. Nothing here scores the candidate either way.

If the runs also burned the full timeout, check the endpoint before re-running:
a trivial prompt (\`Reply with exactly: OK\`) against the same route answers
instantly when the provider is healthy."
        tail1="Confirm the provider is up, then re-run. Do not quote a number from this
file, and do not record a verdict about the candidate from it."
      fi
      # ★ A third nothing, and the only one where the operator's correct move is
      # to do nothing at all for a while. Checked last so a real failure
      # elsewhere in the sweep still gets its own verdict.
      if [ -n "$window_closed" ] && [ -z "$measurement_failed" ] && [ -z "$grading_failed" ]; then
        head1="NOT MEASURED -- PROVIDER WINDOW CLOSED"; rc1=6
        body1="A provider usage window closed mid-sweep, so this pass never got to run.
That is a clock, not a defect: nothing is wrong with the tool, the key or the
candidate, and every review already on disk is intact and still counted."
        # ★ Not "resume after the reset time above" (#48): a model-tier window
        # names a remedy instead of a time, so that sentence pointed at a line
        # that was never printed. run-pass quotes whatever the provider said.
        tail1="Resume when that window reopens. There is nothing here to fix, and no
number to quote."
      fi
      # Leak evidence outranks every exclusion and the all-unusable verdict.
      # Retain the dispatch/grading error code for callers resuming a sweep.
      if [ "$suspect" -gt 0 ]; then
        head1="INVALID, answer-key leak suspected"
        body1="$suspect run(s) reproduced key item headings word for word. Neither hit rate is valid evidence."
        tail1="Move the key out of reach and re-run the reviews before scoring."
      fi
      {
        echo "## Verdict: $head1"
        echo
        echo "$body1"
        echo
        printf '%s' "$skipped"
        echo
        echo "$tail1"
        echo
        report_run_exclusions "$invalid_notes" "$invalid_errors" "$suspect_notes" "$operator_invalid"
        # A regrade that kept its priors is the likeliest way to land here
        # with reviews on disk, so the count is printed on this path too.
        [ "$rescore" != 1 ] || [ "$regrade_kept_runs" -eq 0 ] ||
          echo "- regrades that returned unusable and KEPT the prior grade on disk, unscored: $regrade_kept_runs"
      } >> "$report"
      frontload_grade_cost "$report" || return 1
      table_manifest_finish "$report" "$table_report" || return 1
      report="$table_report"
      echo
      cat "$report"
      echo
      echo "saved: $report"
      echo "cadre: $head1 for '$spec' -- $nskipped pass(es) scored nothing" >&2
      return "$rc1"
    fi
    echo "## Verdict: NOTHING MEASURED" >> "$report"
    table_manifest_finish "$report" "$table_report" || return 1
    report="$table_report"
    echo "no passes graded. Check 'cadre passes'"; return 1
  fi

  # ---- slot recommendation -------------------------------------------------
  #
  # ★ With an UNRESOLVED item there is no single hit count, so there is no single
  # slot. The rule is to work out the slot at BOTH ends of the range and only
  # state one when they agree: if resolving every contested item one way would
  # seat this candidate and the other way would not, the honest answer is that
  # the key cannot yet tell. That is the whole point of not breaking the tie.
  local bhigh=$((blocking_hit + blocking_unresolved))
  local slot reason
  if [ "$suspect" -gt 0 ]; then
    slot="INVALID, answer-key leak suspected"
    reason="$suspect run(s) reproduced key item headings word for word, so this pass measured nothing about the candidate. Move the key somewhere the agent cannot reach, or run the agents in a container, then re-run. Scoring the remaining runs would report a number produced under a compromised setup."
  elif [ "$defer_on_blocking" -gt 0 ]; then
    slot="DO NOT SLOT"
    reason="Deferred on a BLOCKING item $defer_on_blocking time(s). Found the bug and argued it was fine. A confident wrong approval is worse than silence in a panel: it supplies cover for shipping. Disqualifying on its own, whatever the hit rate."
  elif [ "$blocking_total" -eq 0 ]; then
    slot="INCONCLUSIVE"
    reason="No blocking items were graded. Check the passes registry and the severity words in your keys."
  elif [ "$(slot_band "$blocking_hit" "$blocking_total")" != "$(slot_band "$bhigh" "$blocking_total")" ]; then
    slot="UNRESOLVED, not slottable"
    reason="The judges split on $blocking_unresolved blocking item(s), so this candidate caught
between $blocking_hit and $bhigh of $blocking_total -- a range that straddles the line between
'$(slot_band "$blocking_hit" "$blocking_total")' and '$(slot_band "$bhigh" "$blocking_total")'. Resolving those items one way seats it and the
other way does not, so the key cannot yet tell you which. Read the side-by-side
readings above: judges quoting DIFFERENT sentences means the key's credit
boundary is loose, and quoting the SAME sentence two ways means its wording is
ambiguous. Tighten the key and re-grade. Do not pick a judge."
  elif [ "$blocking_hit" -eq "$blocking_total" ]; then
    slot="SEAT: can review alone"
    reason="Caught every blocking item in every run ($blocking_hit/$blocking_total)."
  elif [ $((blocking_hit * 2)) -ge "$blocking_total" ]; then
    slot="SEAT: needs a second reader"
    reason="Caught $blocking_hit/$blocking_total blocking items$([ "$blocking_unresolved" -gt 0 ] && echo " (plus $blocking_unresolved UNRESOLVED, which score nothing either way)"). Never the only reviewer on a change. That is not a ranking against the others: a candidate here can still be the most valuable seat on the panel if it catches what the rest of them do not."
  else
    slot="DO NOT SLOT"
    reason="Caught only $blocking_hit/$blocking_total blocking items and never deferred. Limited rather than dangerous, but not carrying its cost."
  fi

  # ★ A short denominator cannot recommend a seat. If a registered pass never
  # ran, "hit every blocking item" describes the passes that survived, not the
  # benchmark that was asked for. Disqualifying verdicts stand: a leak or a
  # DEFER on a blocking item is evidence already in hand, and a missing pass
  # does not undo it.
  if [ "$nskipped" -gt 0 ]; then
    # ★ Right verdict, wrong instruction, which is the same defect the
    # NOTHING-MEASURED wording had: "restore the missing keys or checkouts" sends
    # the operator looking for a broken registry when the sweep was stopped by a
    # provider clock and there is nothing to restore. The verdict below is
    # unchanged either way -- a short denominator still cannot recommend a seat.
    local fixit="Restore the missing keys or checkouts and re-run before slotting anything."
    [ -n "$window_closed" ] &&
      fixit="A provider usage window closed mid-sweep, so the missing passes are a clock and not a defect: wait for that window to reopen, then re-run to resume. Every review already on disk is reused."
    case "$slot" in
      SEAT:*|INCONCLUSIVE)
        reason="$nskipped registered pass(es) never ran, so $blocking_hit/$blocking_total is a partial denominator and not the benchmark you registered. $fixit On the passes that did run: $reason"
        slot="INCOMPLETE, not slottable" ;;
    esac
  fi

  # ★ Same guard, other cause. One pass is not the registry either, and a scoped
  # run reaching "SEAT: can review alone" off a single key would be the exact
  # overclaim the guard above exists to stop -- arrived at from the argument
  # list instead of from a missing checkout.
  if [ -n "$scoped" ] && [ "$nfiltered" -gt 0 ]; then
    case "$slot" in
      SEAT:*|INCONCLUSIVE)
        reason="Scoped to the one pass '$only', which left $nfiltered other registered pass(es) out, so $blocking_hit/$blocking_total is that pass and not the benchmark. Re-run without a pass argument before slotting anything. On '$only': $reason"
        slot="SCOPED to one pass, not slottable" ;;
    esac
  fi

  # ★ The round floor (#23), third guard of the same shape. Both directions of
  # the rate verdict fall to it, unlike the two above: the reversals it exists
  # for were a LOW first round as often as a high one, so "caught only 1/4" off
  # one round is the same draw as "caught every one". A DEFER is not a rate, it
  # is a quoted act already in hand, so that DO NOT SLOT stands, as a leak does.
  if [ -n "$min_rounds" ] && [ "$min_rounds" -lt "$ROUND_FLOOR" ]; then
    local rate_verdict=""
    case "$slot" in
      SEAT:*) rate_verdict=1 ;;
      "DO NOT SLOT") [ "$defer_on_blocking" -gt 0 ] || rate_verdict=1 ;;
    esac
    if [ -n "$rate_verdict" ]; then
      reason="At least one pass was scored in only $min_rounds run, so $blocking_hit/$blocking_total is one round's draw and not a property of \`$spec\`: single rounds have been measured reversing in both directions. Grade at least $ROUND_FLOOR runs per pass (the default) before slotting anything. On the one round: $reason"
      slot="ONE ROUND, not slottable"
    fi
  fi

  # ★ Cost per blocking item hit sits BESIDE the hit rate; it never replaces it.
  # The seating question is not only "how many" but "at what spend": a 4/6 seat
  # at a tenth the cost can beat a 5/6 seat. Estimator is bytes/4 of harness-side
  # prompt+review -- the same relative-spend signal as cadre receipts, not a
  # bill and not a count of hidden reasoning tokens.
  #
  # ★ EMPTY receipt -> "-". Never 0 (looks like free) and never a huge number
  # from dividing by a missing measure. A seat that hit 0 blocking items has no
  # defined cost-per-item either: zero denominator is not infinite efficiency.
  # UNRESOLVED is already out of blocking_hit, so it is out of this denominator
  # too -- scores nothing either way.
  local cost_per partial_note=""
  cost_per=$(cost_per_hit "$((receipt_prompt_bytes + receipt_review_bytes))" \
                          "$blocking_hit" "$receipt_have" "$receipt_empty")
  # ★ Same partial-denominator condition the hit count already names (skipped
  # passes, --only scoping). A cost line without the caveat inherits a lie the
  # report already knows how to call out.
  if [ "$nskipped" -gt 0 ] || { [ -n "$scoped" ] && [ "$nfiltered" -gt 0 ]; }; then
    partial_note=" (partial denominator)"
  fi

  # ★ The per-language slice (#9): rendered only when the graded passes span at
  # least TWO recorded languages, silent otherwise -- one language is not a
  # split, and a section that says so would read as a finding. Labelled
  # observational on the line the numbers sit on, because language and repo are
  # confounded here: nothing matched these passes for difficulty, and a row
  # built from one repo says nothing about the language. Passes with no
  # recorded language are listed, not folded into a guess.
  local nlangs
  nlangs=$(printf '%s' "$lang_rows" | awk -F '\t' '$1 != "unknown" && !seen[$1]++ { n++ } END { print n + 0 }')
  if [ "${nlangs:-0}" -ge 2 ]; then
    {
      echo "## By language (observational)"
      echo
      echo "The passes you registered happen to span these languages. This is NOT a"
      echo "cross-language benchmark: language and repo are confounded, difficulty is"
      echo "unmatched, and a row built from one repo measures that repo. Blocking items"
      echo "only; UNRESOLVED scores nothing either way."
      echo
      echo "| language | passes | blocking hit | blocking total | unresolved |"
      echo "|---|---|---|---|---|"
      printf '%s' "$lang_rows" | awk -F '\t' '
        { p[$1]++; h[$1] += $3; t[$1] += $4; u[$1] += $5 }
        END {
          for (l in p) if (l != "unknown") printf "%s\t%d\t%d\t%d\t%d\n", l, p[l], h[l], t[l], u[l]
        }' | LC_ALL=C sort | awk -F '\t' '{ printf "| `%s` | %d | %d | %d | %d |\n", $1, $2, $3, $4, $5 }'
      printf '%s' "$lang_rows" | awk -F '\t' '$1 == "unknown" { n++ }
        END { if (n) printf "| none detected / not recorded | %d | - | - | - |\n", n }'
      echo
    } >> "$report"
  fi

  {
    echo "## Verdict: $slot"
    echo
    echo "$reason"
    echo
    report_run_exclusions "$invalid_notes" "$invalid_errors" "$suspect_notes" "$operator_invalid"
    # ★ Confounds BEFORE the score (#39): the cap the runs ran under, the runs
    # that could not have scored whatever the model knew, the candidate's own
    # run-to-run spread, and what this regrade moved. A reader who sees the
    # hit line first reads everything after it as a footnote.
    local ncaps; ncaps=$(printf '%s' "$caps_seen" | wc -w | tr -d ' ')
    if [ "$ncaps" -eq 0 ]; then
      echo "- output cap: **not recorded** (no adapter declared one; see cadre_cap in docs/ADDING-AN-AGENT.md)"
    elif [ "$ncaps" -eq 1 ] && [ -z "$cap_unrecorded" ]; then
      echo "- output cap: **$(printf '%s' "${caps_seen# }") tokens** (declared by the adapter on every scored run)"
    else
      echo "- output cap: **mixed** ($(printf '%s' "${caps_seen# }" | tr ' ' ',' | sed 's/,/, /g')${cap_unrecorded:+; unrecorded on some scored runs}); the scored runs were not cap-matched, so their rates are not one measurement"
    fi
    echo "- runs not scored, output cut off (partial review on disk): $cutoff_runs"$partial_note
    echo "- runs not scored, provider returned nothing: $empty_runs"$partial_note
    [ "$capped_scored" -eq 0 ] ||
      echo "- scored runs whose adapter reported the output cap was hit: $capped_scored (findings real; silence past the cut is not clearance)"
    # ★ A REAL tab, not "\t": inside double quotes that is a backslash and a
    # t, and `awk -F` would then split on neither. A pass label can hold a
    # space, so the field separator has to be something a label does not carry.
    local spread_rows="" nn tab
    tab=$'\t'
    for ((nn = 1; nn <= runs; nn++)); do
      [ "${run_btotal[$nn]:-0}" -gt 0 ] || continue
      spread_rows="$spread_rows$nn$tab${run_bhit[$nn]:-0}$tab${run_btotal[$nn]}$tab${run_bunres[$nn]:-0}$tab${run_passes[$nn]:-}"$'\n'
    done
    # Run k over every pass is one sweep of the set; the spread between sweeps
    # is the floor a delta between two seats has to clear.
    #
    # ★ Two sweeps are only comparable when they graded the SAME PASSES. A
    # pass whose run 2 was unusable contributes its items to slot 1 alone, so
    # the gap between the slots' rates is partly the missing pass, not
    # variance -- and EQUAL ITEM COUNTS DO NOT PROVE EQUAL CONTENTS: pass A
    # scoring only in slot 1 and pass B only in slot 2 gives both slots the
    # same denominator over completely different items -- and this number becomes the
    # floor for the whole panel table, where an inflated one declares real
    # seat differences to be noise. Same rail as the verdict guard above: a
    # short denominator cannot support the claim, so the number is unavailable
    # and the fractions are printed rather than divided.
    # ★ UNRESOLVED is the same problem wearing a different hat. A slot rate is
    # a LOW bound, so a split in one sweep and not the other moves the gap by
    # the split rather than by the candidate. Refused for the same reason, and
    # the fix is the one the report already names: tighten the key, re-grade.
    # ★ Every branch prints the line. An absent spread line cannot be told
    # apart from a check that never ran.
    printf '%s' "$spread_rows" | awk -F '\t' -v req="$runs" '
      { n++; r = 100 * $2 / $3
        if (n == 1) seen = $5; else if ($5 != seen) mixed = 1
        unres += $4
        if (n == 1 || r < lo) lo = r
        if (n == 1 || r > hi) hi = r
        d = d (d ? ", " : "") "run " $1 ": " $2 "/" $3 ($4 > 0 ? " (+" $4 " unresolved)" : "") }
      END {
        if (req < 2) print "- run-to-run spread (blocking hit rate): **not measured** (1 run per pass; run at least 2 to measure the noise floor)"
        else if (n < 2) print "- run-to-run spread (blocking hit rate): **not measured** (only " n + 0 " run slot produced graded blocking items)"
        else if (mixed) print "- run-to-run spread (blocking hit rate): **unavailable**, the sweeps did not grade the same items (" d "); a pass missing from one sweep moves this gap by the pass, not by the candidate"
        else if (unres) print "- run-to-run spread (blocking hit rate): **unavailable**, " unres " UNRESOLVED item(s) leave each sweep a lower bound (" d "); tighten the key and re-grade"
        else printf "- run-to-run spread (blocking hit rate): **%.1fpp** (%s); a difference between two seats smaller than this is noise\n", hi - lo, d
      }'
    # ★ The round count sits beside every rate it qualifies (#23), and like the
    # spread it is printed on every branch: an absent count reads as "enough".
    if [ -z "$min_rounds" ]; then
      echo "- rounds per pass behind the blocking hit rate: **-** (no pass graded a blocking item)"
    elif [ "$min_rounds" -lt "$ROUND_FLOOR" ]; then
      echo "- rounds per pass behind the blocking hit rate: **$min_rounds** (the fewest scored runs any pass had); below the floor of $ROUND_FLOOR, so no seat is recommended from it"
    else
      echo "- rounds per pass behind the blocking hit rate: **$min_rounds** (the fewest scored runs any pass had)"
    fi
    if [ "$rescore" = 1 ]; then
      echo "- item verdicts moved by this regrade: $regrade_changed_items across $regrade_changed_runs run(s); every prior value is in a \`.grade.json.regraded.jsonl\` ledger beside its grade"
      [ "$regrade_kept_runs" -eq 0 ] ||
        echo "- regrades that returned unusable and KEPT the prior grade on disk, unscored: $regrade_kept_runs"
    fi
    if [ "$suspect" -gt 0 ]; then
      echo "- blocking items hit: **NOT SCORED**"
    elif [ "$blocking_unresolved" -gt 0 ]; then
      echo "- blocking items hit: **$blocking_hit to $bhigh / $blocking_total** ($blocking_unresolved UNRESOLVED)"
    else
      echo "- blocking items hit: **$blocking_hit / $blocking_total**"
    fi
    echo "- est. tokens per blocking item hit: **$cost_per**$partial_note"
    # ★ Coverage sits beside the hit rate: a seat that hits every planted defect
    # while never mentioning half the diff is a different bet from one that read
    # all of it. Mean of per-pass ratios (not pooled), worst pass named. "-" when
    # no keyed pass had a resolvable changeset -- never a fabricated 0%.
    if [ "$cov_npass" -gt 0 ]; then
      echo "- changed-file coverage (mean over $cov_npass keyed pass(es)): **$((cov_pct_sum / cov_npass))%**, thinnest on \`$cov_worst_label\` at $cov_worst_frac$partial_note"
    else
      echo "- changed-file coverage: **-** (no keyed pass had a resolvable changeset)"
    fi
    if [ "$suspect" -gt 0 ]; then
      echo "- all items hit: NOT SCORED"
    else
      echo "- all items hit: $total_hit / $total_items$([ "$total_unresolved" -gt 0 ] && echo " ($total_unresolved UNRESOLVED)")"
    fi
    echo "- deferred on a blocking item: $defer_on_blocking"
    echo "- unusable runs: $unusable"
    echo "- runs excluded as suspected key leaks: $suspect"
    if [ -n "$split_notes" ]; then
      echo
      echo "### The judges split on these, and each split is a bug in the KEY"
      echo
      printf '%s' "$split_notes"
      echo
      echo "Neither reading scored. A split says the key's credit boundary does not"
      echo "decide this item, which is a fact about the key and not about either"
      echo "judge -- so the fix is a keygen change tightening that boundary, not"
      echo "another judge swap. Re-grade after you tighten it."
    fi
    if [ "${#judges[@]}" -eq 1 ]; then
      echo
      echo "### ⚠ ONE judge graded this"
      echo
      echo "Two graders on this harness split on about **one item in three**, and"
      echo "three readers scored the same candidate 2/6, 4/6 and 6/6 ordered by"
      echo "nothing but leniency. A single judge's reading is a hypothesis about"
      echo "this candidate, not a measurement of it, and nothing above can tell"
      echo "you which items it would have read the other way."
      echo
      echo "Add a second and the items they disagree on stop being scored:"
      echo
      echo "    CADRE_JUDGE='${judges[0]},<other-agent>' cadre grade $spec $runs"
      echo
      echo "Pick one whose failures you expect to differ from ${judges[0]}'s. Two"
      echo "graders of one lineage agree where one was already confident."
    fi
    if printf '%s' "$split_notes" | grep -q DEFER; then
      echo "- ⚠ one judge called DEFER on an item the other did not. It is UNRESOLVED,"
      echo "  so it did NOT disqualify -- but a deferred blocking item is the one"
      echo "  finding this tool treats as worse than a miss. Read those rows before"
      echo "  seating this candidate; the gate declined to decide, it did not clear it."
    fi
    if [ "$unquoted_defer" -gt 0 ]; then
      echo "- DEFER on a blocking item with no quote, so NOT counted as disqualifying: $unquoted_defer"
      echo "  (the judge said the candidate argued the bug away but did not quote"
      echo "  where. Read the review yourself before slotting; an unverifiable"
      echo "  DEFER is the judge's claim, not the candidate's behaviour.)"
    fi
    if [ "$nskipped" -gt 0 ]; then
      echo
      echo "### ⚠ $nskipped registered pass(es) NOT GRADED"
      echo
      printf '%s' "$skipped"
      echo
      echo "Every number above is over the passes that ran. The benchmark you"
      echo "registered is larger. Restore the missing key or checkout and re-run"
      echo "before comparing this candidate against one scored on the full set."
    fi
    # ★ Its own section, never a column beside the hit rate. A clean pass and a
    # keyed pass measure opposite things -- what a reviewer wrongly raises, and
    # what it correctly catches -- and a reviewer trades one for the other, so a
    # single pooled number would hide the trade this is here to expose.
    # Reported as a COUNT, not a rate: a rate needs a denominator of things that
    # could have been flagged, and a key with no items does not have one.
    if [ "$clean_passes" -gt 0 ]; then
      echo
      echo "### False-positive probes ($clean_passes CLEAN pass(es): $clean_labels)"
      echo
      echo "- findings raised where nothing was planted: **$clean_fp**"
      echo
      if [ -n "$clean_extras" ]; then
        echo "$clean_extras"
        echo "Each of these is a defect the reviewer asserted in code that has none."
        echo "Verify before believing the count: a clean checkout can still contain a"
        echo "real bug nobody planted, and that is a finding about the PASS, not a"
        echo "false positive. Fix the pass or move it to a keyed one."
      else
        echo "Raised nothing on a clean checkout, which is the result this pass is for."
      fi
      echo
      echo "Not pooled with the keyed score above: these passes have no items, so"
      echo "they contribute no denominator and no hit rate."
    fi
    if [ -n "$extras_all" ]; then
      echo
      echo "### Out-of-key findings (grade these by hand)"
      echo
      echo "$extras_all"
      echo "A candidate that finds real bugs the key does not contain is the most"
      echo "valuable result this can produce, and the one it cannot score. Verify"
      echo "each against the source before believing it. If it holds, fold it into"
      echo "the key so the next candidate is measured against a better test, and"
      echo "record that earlier candidates were scored against the shorter key."
    fi
    echo
    if [ "$reference_used" = 1 ]; then
      echo
      echo "### ⚠ This score includes a reference pass"
      echo
      echo "\`ref-*\` passes are mined from a PUBLIC repository, so the target and"
      echo "its fix are in every model's training data. They exist to smoke-test"
      echo "that your adapters and judge are wired up, and to show what a good key"
      echo "looks like. **A score on a reference pass is not a roster signal.**"
      echo "Real slotting needs passes mined from your own repo."
    fi
    echo
    echo "### What the score does not tell you"
    echo
    echo "A hit rate ranks. It does not tell you whether this reviewer fails on the"
    echo "SAME items your current panel already fails on. Compare the per-item rows"
    echo "above against your incumbents': a lower-scoring candidate that hits an item"
    echo "everyone else misses is worth more than a higher-scoring one that agrees"
    echo "with them everywhere. See docs/METHOD.md."
    echo
    echo "_Recommendation only. Nothing was added to any review lineup._"
  } >> "$report"

  frontload_grade_cost "$report" || return 1
  table_manifest_finish "$report" "$table_report" || return 1
  report="$table_report"
  echo
  cat "$report"
  echo
  echo "saved: $report"

  # ★ The exit code has to say it too. Everything above is in the report, and the
  # driver that produced the false green was piping stdout to /dev/null -- so a
  # loud report and a 0 exit is still a green light. Only a failed MEASUREMENT
  # trips this (a pass that ran and yielded nothing, or a sweep that aborted); a
  # missing key or a deleted checkout keeps its old exit code, since that is a
  # registry the operator changed and the INCOMPLETE verdict already names it.
  if [ -n "$measurement_failed" ]; then
    echo "cadre: some pass(es) produced no usable review. Exit 4, not a result." >&2
    return 4
  fi
  # ★ 5, not 4, and the difference is worth an exit code of its own. A sweep
  # driver's correct response to 4 is to STOP -- the candidate is not producing
  # reviews and the next pass will go the same way. Its correct response to 5 is
  # to KEEP GOING and note the pass for a re-grade: the reviews are on disk, they
  # cost fifteen minutes each, and a judge that blipped costs one cheap call to
  # redo. Collapsed into one code, an ollama hiccup at hour two throws away five
  # hours of review production to save a minute of grading.
  if [ -n "$grading_failed" ]; then
    echo "cadre: pass(es) produced reviews that could NOT be graded. Exit 5: re-grade, do not re-review." >&2
    return 5
  fi
  # ★ 6 last, and it is the weakest of the three on purpose: a sweep that scored
  # some passes and then lost its window has a real partial result above, so this
  # says "incomplete, resume later", not "discard this". A driver's correct
  # response is to wait out the reset and re-invoke -- the reviews already on
  # disk are reused, which is what made resuming the 2026-07-28 sweep cost four
  # reviews instead of thirty.
  if [ -n "$window_closed" ]; then
    echo "cadre: a provider usage window closed, so the sweep is INCOMPLETE. Exit 6: wait for the window to reopen, then re-run to resume." >&2
    return 6
  fi
  [ -z "$invalid_errors" ] || return 1
}
