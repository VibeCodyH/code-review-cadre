# Grading and slot recommendation. Sourced by bin/cadre.
# shellcheck shell=bash

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

# ★ The fallback for what the scan above cannot parse: an UNBALANCED brace
# inside a JSON string. "The judge's format never has them" stopped being true
# the day `quotes` became required -- a verbatim reviewer sentence about shell
# or C code carries a lone { or } routinely, the depth count never returns to
# zero, and a valid grade was recorded UNUSABLE with the judge blamed for it.
# Same shape cmd_settle already uses: drop fence lines, slice first { to last
# }, let jq be the arbiter. Tried second, not first, because on a reply that
# echoes prompt text with braces the balanced scan finds the clean object and
# this slice would not.
extract_json_relaxed() {
  sed -e '/^[[:space:]]*```/d' \
  | awk 'BEGIN{RS="\0"} {
      i=index($0,"{"); if(!i) exit 1; s=substr($0,i)
      for(k=length(s);k>0;k--) if(substr(s,k,1)=="}") { printf "%s", substr(s,1,k); exit }
      exit 1
    }'
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
  if [ "$parsed" -eq 0 ]; then
    printf '%s' "$raw" | extract_json_relaxed > "$out" 2>/dev/null
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

# run_gauntlet <agent-spec> <runs> <rescore 0|1> [pass-label]
run_gauntlet() {
  local spec="$1" runs="$2" rescore="$3" only="${4:-}"
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
  local blocking_hit=0 blocking_total=0 defer_on_blocking=0
  local total_hit=0 total_items=0 unusable=0 suspect=0 extras_all="" graded_passes=0 reference_used=0
  local skipped="" nskipped=0 unquoted_defer=0
  local blocking_unresolved=0 total_unresolved=0 split_notes=""
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
  local usable_runs=0 pass_usable=0 aborted="" measurement_failed="" nfiltered=0 window_closed=""
  # ★ Two failures that must not share an exit code, because the caller's correct
  # response to them is opposite. A missing REVIEW is fifteen minutes of a model's
  # time and the reason to stop a sweep. A review that exists but could not be
  # GRADED is a judge outage: the expensive artifact is safely on disk and one
  # cheap re-grade fixes it, so a sweep that quits there throws away hours of
  # review production to save one minute of grading. Collapsing them is how a
  # driver ends up treating an ollama hiccup at hour two as a reason to abandon
  # hour three onward.
  local pass_reviews=0 grading_failed=""

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
    # ★ COUNT what the scope excluded. Scoping to the only registered pass
    # excluded nothing, and warning "this is not the benchmark" there would be a
    # false alarm on the smallest legitimate setup there is. The guard below asks
    # whether anything was actually left out, not whether an argument was passed.
    if [ -n "$only" ] && [ "$only" != "$label" ]; then
      nfiltered=$((nfiltered + 1)); continue
    fi

    # The sweep gave up on an earlier pass (see the abort below). Name every
    # pass that consequently never ran, rather than letting the report end where
    # the candidate stopped working and read as if that were the registry.
    if [ -n "$aborted" ]; then
      skipped="$skipped- $label: NOT ATTEMPTED, the sweep aborted on '$aborted'"$'\n'
      nskipped=$((nskipped + 1)); continue
    fi

    local keyfile="$key"
    case "$keyfile" in /*) ;; *) keyfile="$CADRE_HOME/$key" ;; esac
    # ★ A skipped pass goes IN THE REPORT, not just the scrollback. Omitting it
    # silently shrank the denominator: one deleted checkout of two turned
    # "caught every blocking item in every run" into a claim about half the
    # benchmark, and the saved artifact carried no trace of the half that
    # never ran.
    if [ ! -f "$keyfile" ]; then
      echo "  $label: no key at $keyfile, NOT GRADED"
      skipped="$skipped- $label: key missing at $keyfile"$'\n'; nskipped=$((nskipped + 1))
      continue
    fi

    local target="$dir"
    case "$target" in /*) ;; *) target="$CADRE_HOME/$dir" ;; esac
    if [ ! -d "$target" ]; then
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

    if [ "$rescore" != 1 ]; then
      echo "==> $label: running $spec"
      # ★ Was `|| return 1`, which had never fired because run-pass.sh always
      # exited 0. Now that it reports 0-of-N, STOP: a candidate producing no
      # review on this pass will produce none on the next eleven either, and
      # grinding through them is the fifty silent minutes this whole change is
      # about. Recorded as a skipped pass so the denominator guard below sees it.
      local prc=0
      CADRE_PASS_DIR="$target" CADRE_PASS_BASE="$base" \
        "$CADRE_ROOT/lib/run-pass.sh" "$label" "$sha" "$runs" "$spec" || prc=$?
      if [ "$prc" -ne 0 ]; then
        echo "  $label: run-pass.sh exited $prc, ABORTING the sweep here"
        nskipped=$((nskipped + 1)); aborted="$label"
        # ★ 6 aborts the sweep like 4 does, but it is not a failed measurement
        # and must not be reported as one: the cause is a provider usage window
        # that clears on its own, so the next move is to wait and resume, not to
        # go looking for a defect. Kept out of $measurement_failed for exactly
        # that reason -- see provider_window_closed() in lib/common.sh.
        if [ "$prc" -eq 6 ]; then
          skipped="$skipped- $label: NOT MEASURED, the provider's usage window closed (resume after its reset)"$'\n'
          window_closed=1
        else
          skipped="$skipped- $label: no usable review, run-pass.sh exited $prc"$'\n'
          measurement_failed=1
        fi
        continue
      fi
    fi

    echo "==> $label: grading"
    graded_passes=$((graded_passes + 1))
    pass_usable=0; pass_reviews=0
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

    local items; items=$(key_items "$keyfile")
    local n
    for n in $(seq 1 "$runs"); do
      local rf="$CADRE_HOME/$label/$sl-run$n.md"
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
        if [ -s "$rf.failed" ]; then
          why="the adapter failed, see $sl-run$n.md.failed"
          [ -s "$rf.partial" ] && why="$why (an earlier attempt stopped early, see $sl-run$n.md.partial)"
        fi
        echo "- run $n: **UNUSABLE** ($why)" >> "$report"
        continue
      fi
      # The review itself exists. Whatever happens from here is downstream of the
      # expensive part, so it is cheap to redo and must not read as a lost run.
      pass_reviews=$((pass_reviews + 1))
      local leaked; leaked=$(leak_check "$keyfile" "$rf")
      if [ "$leaked" -ge 2 ]; then
        suspect=$((suspect + 1))
        echo "- run $n: **★ SUSPECT, quotes $leaked key items verbatim**, this reviewer" >> "$report"
        echo "  probably read the answer key rather than finding the defects. NOT scored." >> "$report"
        continue
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
      local gfs=() bad="" savedj="$CADRE_JUDGE"
      local j js gf
      for j in "${judges[@]}"; do
        CADRE_JUDGE="$j"
        js=$(slug "$j")
        gf="$CADRE_HOME/$label/$sl-run$n.by-$js.grade.json"
        if [ "$rescore" = 1 ] || [ ! -s "$gf" ]; then
          grade_one "$keyfile" "$rf" "$gf.new"
          if [ -s "$gf.new" ]; then
            mv -f "$gf.new" "$gf"
            if [ -s "$gf.new.judge-raw" ]; then mv -f "$gf.new.judge-raw" "$gf.judge-raw"
            else rm -f "$gf.judge-raw"; fi
          else
            rm -f "$gf.new" "$gf.new.judge-raw"
          fi
        fi
        if [ ! -s "$gf" ] || [ "$(jq -r '.unusable // false' "$gf")" = true ]; then
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

      # ★ EVERY judge has to have produced a usable grade. Reconciling one
      # judge's reading against a missing one is a single-judge score wearing a
      # two-judge label, and an outage is not a measurement. The usable grade
      # stays on disk, so a re-grade after the quota resets costs one call.
      if [ -n "$bad" ]; then
        unusable=$((unusable + 1))
        echo "- run $n: **UNUSABLE** (${bad%; })" >> "$report"
        [ "${#gfs[@]}" -gt 0 ] &&
          echo "  The other judge's grade is on disk and was NOT discarded; \`cadre grade --rescore\` re-runs only what is missing." >> "$report"
        continue
      fi
      pass_usable=$((pass_usable + 1)); usable_runs=$((usable_runs + 1))

      # ★ Harness-side receipt for this usable run. Only runs that contribute to
      # the hit count feed the cost-per-hit number: an unusable or suspect run is
      # not in the score, so its spend must not pad the numerator either.
      # ★ One EMPTY prompt voids the whole seat's cost-per-item. Mixing a real
      # measurement with a silent zero is the same average-toward-the-floor bug
      # slots.tsv avoids by leaving reconstructed prompt_bytes blank.
      if [ -z "$receipt_empty" ]; then
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
          blocking_total=$((blocking_total + 1))
          [ "$v" = HIT ]        && blocking_hit=$((blocking_hit + 1))
          [ "$v" = UNRESOLVED ] && blocking_unresolved=$((blocking_unresolved + 1))
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
    # ★ A pass whose every run was UNUSABLE is a pass that did not happen. It
    # belongs with the missing keys and the deleted checkouts, because it has
    # exactly their effect on the arithmetic: nothing in the numerator, nothing
    # in the denominator, and a `graded_passes` tick that made the report look
    # like the benchmark ran. Counted as skipped so the guard below downgrades
    # the verdict instead of dressing a short denominator as a result.
    if [ "$pass_usable" -eq 0 ]; then
      echo "**No usable run on this pass, so it contributed no items to the score below.**" >> "$report"
      nskipped=$((nskipped + 1)); graded_passes=$((graded_passes - 1))
      # ★ WHICH nothing. The reviews being on disk changes what the operator
      # should do and what a driver should do, so it changes the exit code too.
      if [ "$pass_reviews" -gt 0 ]; then
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
    echo >> "$report"
  done < "$CADRE_HOME/passes.conf"

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
      # ★ A third nothing, and the only one where the operator's correct move is
      # to do nothing at all for a while. Checked last so a real failure
      # elsewhere in the sweep still gets its own verdict.
      local tail1="Fix the cause and re-run. Do not quote a number from this file."
      if [ -n "$window_closed" ] && [ -z "$measurement_failed" ] && [ -z "$grading_failed" ]; then
        head1="NOT MEASURED -- PROVIDER WINDOW CLOSED"; rc1=6
        body1="A provider usage window closed mid-sweep, so this pass never got to run.
That is a clock, not a defect: nothing is wrong with the tool, the key or the
candidate, and every review already on disk is intact and still counted."
        tail1="Resume after the reset time above. There is nothing here to fix, and no
number to quote."
      fi
      {
        echo "## Verdict: $head1"
        echo
        echo "$body1"
        echo
        printf '%s' "$skipped"
        echo
        echo "$tail1"
      } >> "$report"
      echo
      cat "$report"
      echo
      echo "saved: $report"
      echo "cadre: $head1 for '$spec' -- $nskipped pass(es) scored nothing" >&2
      return "$rc1"
    fi
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
      fixit="A provider usage window closed mid-sweep, so the missing passes are a clock and not a defect: wait for the reset named above, then re-run to resume. Every review already on disk is reused."
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

  {
    echo "## Verdict: $slot"
    echo
    echo "$reason"
    echo
    if [ "$blocking_unresolved" -gt 0 ]; then
      echo "- blocking items hit: **$blocking_hit to $bhigh / $blocking_total** ($blocking_unresolved UNRESOLVED)"
    else
      echo "- blocking items hit: **$blocking_hit / $blocking_total**"
    fi
    echo "- est. tokens per blocking item hit: **$cost_per**$partial_note"
    echo "- all items hit: $total_hit / $total_items$([ "$total_unresolved" -gt 0 ] && echo " ($total_unresolved UNRESOLVED)")"
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
    echo "cadre: a provider usage window closed, so the sweep is INCOMPLETE. Exit 6: wait for the reset, then re-run to resume." >&2
    return 6
  fi
}
