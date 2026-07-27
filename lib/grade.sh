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
  printf '%s' "$raw" | extract_json > "$out" 2>/dev/null
  # ★ Keep what the judge actually said when it does not parse. UNUSABLE with no
  # record is indistinguishable from a broken judge, a bad key, and a real
  # refusal. Measured: a judge CLI that will not start outside a git repo failed
  # on every call and reported UNUSABLE across the board with no reason given.
  jq -e . "$out" >/dev/null 2>&1 || {
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

# Findings the review states, counted in the two shapes reviewers actually emit:
#   codex        1. **blocking** - [file:line](...)
#   grok/claude  ### 1. blocking - ...
# Deliberately loose. It backs a check that only fires when the count is >= 2,
# so over-counting a stray line costs nothing and under-counting hides a bug.
review_findings() {
  grep -cEi '^ *(#{1,6} *)?([0-9]+[.)]|[-*+])? *\**(blocking|should[ -]fix|must[ -]fix|nit|critical|major)\**' "$1"
}

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
key_problems() {
  local kf="$1" item sev
  [ -s "$kf" ] || { echo "key file is empty"; return; }
  local items; items=$(key_items "$kf")
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
  local report="$CADRE_HOME/report-$sl.md"
  local blocking_hit=0 blocking_total=0 defer_on_blocking=0
  local total_hit=0 total_items=0 unusable=0 suspect=0 extras_all="" graded_passes=0 reference_used=0

  {
    echo "# Gauntlet: \`$spec\`"
    echo
    echo "Judge: \`$CADRE_JUDGE\`. $runs run(s) per pass. Rubric: lib/prompts/judge.md."
    echo
  } > "$report"

  local label sha dir base key
  while IFS='|' read -r label sha dir base key; do
    case "$label" in ''|\#*) continue ;; esac
    # EDGES only. `tr -d ' '` also ate spaces inside paths, so a checkout under
    # a directory with a space read as missing and was silently skipped.
    label=$(trim "$label"); sha=$(trim "$sha"); dir=$(trim "$dir")
    base=$(trim "$base");   key=$(trim "$key")
    [ -n "$only" ] && [ "$only" != "$label" ] && continue

    local keyfile="$key"
    case "$keyfile" in /*) ;; *) keyfile="$CADRE_HOME/$key" ;; esac
    [ -f "$keyfile" ] || { echo "  $label: no key at $keyfile, skipping"; continue; }

    local target="$dir"
    case "$target" in /*) ;; *) target="$CADRE_HOME/$dir" ;; esac
    [ -d "$target" ] || { echo "  $label: no checkout at $target, skipping"; continue; }

    # Refuse at RUN time, not just in doctor. A key inside the reviewed tree is
    # the answer sitting in the reviewer's working copy.
    case "$(readlink -m "$keyfile")" in
      "$(readlink -m "$target")"/*)
        die "$label: the key is inside the reviewed checkout ($keyfile). Move it out of $target." ;;
    esac

    if [ "$rescore" != 1 ]; then
      echo "==> $label: running $spec"
      CADRE_PASS_DIR="$target" CADRE_PASS_BASE="$base" \
        "$CADRE_ROOT/lib/run-pass.sh" "$label" "$sha" "$runs" "$spec" || return 1
    fi

    echo "==> $label: grading"
    graded_passes=$((graded_passes + 1))
    # ref-* = public repo = contaminated. Warn in the report. passes/README.md.
    case "$label" in ref-*) reference_used=1 ;; esac
    { echo "## $label"; echo; } >> "$report"

    local items; items=$(key_items "$keyfile")
    local n
    for n in $(seq 1 "$runs"); do
      local rf="$CADRE_HOME/$label/$sl-run$n.md"
      # A requested run with no output is a FAILED run, not one that never
      # happened. Skipping it let 1 good run of 2 report "every blocking item in
      # every run" and earn a primary slot.
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
        if [ -s "$rf.failed" ]; then
          why="the adapter failed, see $sl-run$n.md.failed"
          [ -s "$rf.partial" ] && why="$why (an earlier attempt stopped early, see $sl-run$n.md.partial)"
        fi
        echo "- run $n: **UNUSABLE** ($why)" >> "$report"
        continue
      fi
      local gf="$CADRE_HOME/$label/$sl-run$n.grade.json"
      # `cadre grade` means RE-grade. A stale grade file would make a corrected
      # key produce identical numbers, the one thing a rescore rules out.
      [ "$rescore" = 1 ] && rm -f "$gf" "$gf.judge-raw"
      [ -s "$gf" ] || grade_one "$keyfile" "$rf" "$gf"

      local leaked; leaked=$(leak_check "$keyfile" "$rf")
      if [ "$leaked" -ge 2 ]; then
        suspect=$((suspect + 1))
        echo "- run $n: **★ SUSPECT, quotes $leaked key items verbatim**, this reviewer" >> "$report"
        echo "  probably read the answer key rather than finding the defects. NOT scored." >> "$report"
        continue
      fi

      if [ "$(jq -r '.unusable // false' "$gf")" = true ]; then
        unusable=$((unusable + 1))
        local why2="empty, truncated, or an error, NOT a clean pass"
        [ -s "$gf.judge-raw" ] && why2="the judge's reply did not parse, see $(basename "$gf").judge-raw"
        echo "- run $n: **UNUSABLE** ($why2)" >> "$report"
        continue
      fi

      # Not scored rather than scored wrong: see judge_incoherent. The item
      # verdicts on such a run may happen to be right, but they were not
      # reliably arrived at, and a re-grade is one command.
      if judge_incoherent "$gf" "$rf"; then
        unusable=$((unusable + 1))
        echo "- run $n: **UNUSABLE** (the judge credited no key item and listed no" >> "$report"
        echo "  extras against a review stating $(review_findings "$rf") findings, so it did not read this" >> "$report"
        echo "  review. Re-grade with \`cadre grade --rescore\`.)" >> "$report"
        continue
      fi

      local row="" k v sev
      for k in $items; do
        v=$(jq -r --arg k "$k" '.items[$k] // "MISS"' "$gf")
        sev=$(key_severity "$keyfile" "$k")
        total_items=$((total_items + 1))
        [ "$v" = HIT ] && total_hit=$((total_hit + 1))
        if [ "$sev" = blocking ]; then
          blocking_total=$((blocking_total + 1))
          [ "$v" = HIT ]   && blocking_hit=$((blocking_hit + 1))
          [ "$v" = DEFER ] && defer_on_blocking=$((defer_on_blocking + 1))
        fi
        row="$row $k=$v"
      done
      local verdict ex
      verdict=$(jq -r '.verdict // "none"' "$gf")
      ex=$(jq -r '(.extras // []) | join("; ")' "$gf")
      [ -n "$ex" ] && extras_all="$extras_all- $label run $n: $ex"$'\n'
      echo "- run $n:$row, verdict \"$verdict\"${ex:+, extras: $ex}" >> "$report"
    done
    echo >> "$report"
  done < "$CADRE_HOME/passes.conf"

  [ "$graded_passes" -gt 0 ] || { echo "no passes graded. Check 'cadre passes'"; return 1; }

  # ---- slot recommendation -------------------------------------------------
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
  elif [ "$blocking_hit" -eq "$blocking_total" ]; then
    slot="SLOT: primary"
    reason="Caught every blocking item in every run ($blocking_hit/$blocking_total)."
  elif [ $((blocking_hit * 2)) -ge "$blocking_total" ]; then
    slot="SLOT: secondary"
    reason="Caught $blocking_hit/$blocking_total blocking items. Run it alongside a primary, not instead of one."
  else
    slot="DO NOT SLOT"
    reason="Caught only $blocking_hit/$blocking_total blocking items and never deferred. Limited rather than dangerous, but not carrying its cost."
  fi

  {
    echo "## Verdict: $slot"
    echo
    echo "$reason"
    echo
    echo "- blocking items hit: **$blocking_hit / $blocking_total**"
    echo "- all items hit: $total_hit / $total_items"
    echo "- deferred on a blocking item: $defer_on_blocking"
    echo "- unusable runs: $unusable"
    echo "- runs excluded as suspected key leaks: $suspect"
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
}
