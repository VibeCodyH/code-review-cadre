#!/usr/bin/env bash
# lib/engine/synthesize.sh -- the review ENGINE: merge the panel, then project
# what it saw into findings.json.
#
# Everything in lib/engine/ answers "what did this panel say about this tree".
# The BENCHMARK -- grade, judges, scoring -- answers "how good was each reviewer",
# and it is a CONSUMER of findings.json only. It does not source this directory,
# which tests/engine-seam.sh asserts, so a foreign findings.json (CodeRabbit, a
# raw Codex export, anything shaped right) grades with zero engine code run.
#
# ★ THE TWO LAYERS, and which one the benchmark is allowed to grade:
#
#   claims[]    verbatim. What each reviewer actually asserted, pulled out of
#               that reviewer's own file by grep. NO MODEL TOUCHES IT.
#               >>> This is the layer the benchmark grades. <<<
#   findings[]  the merged, human-facing view: what the synthesizer said after
#               reading the whole panel. Model-produced, so NOT graded.
#
# The direction of that rule is the part worth keeping, because every downstream
# step is a plausible place to lose it. A synthesizer paraphrases. A verify pass
# can be wrong about the code. A settle pass encodes one human's dismissals. If
# any of the three could reach claims[], a reviewer's score would become a
# function of a downstream model's quality instead of a function of what the
# reviewer wrote -- and it would do so invisibly, because the score would still
# look like a score. So: grade reads claims[]; everything downstream may write
# findings[] and nothing else.

# Merge the reviews. A model too, so the same rate-limit rule applies, and a
# failure here must not cost the individual reviews: they are already on disk.
cmd_synthesize() {
  local out="$1" synth="$2"; shift 2
  local specs=("$@") sl body="" cap="${CADRE_SYNTH_MAX:-200000}"
  local dead=() srcspec=() srcfile=() srcstate=() total=0
  for sp in "${specs[@]}"; do
    sl=$(slug "$sp")
    if [ -s "$out/$sl.md" ];           then srcspec+=("$sp"); srcfile+=("$out/$sl.md");         srcstate+=(ok)
    elif [ -s "$out/$sl.md.partial" ]; then srcspec+=("$sp"); srcfile+=("$out/$sl.md.partial"); srcstate+=(degraded)
    else dead+=("$sp"); fi
  done
  local usable=${#srcspec[@]} i
  # Partials count toward having something to merge. One full review plus one
  # partial is still two independent looks at the diff.
  [ "$usable" -ge 2 ] || { echo "only $usable usable review(s); nothing to synthesize."; return 0; }
  for i in "${!srcfile[@]}"; do total=$((total + $(wc -c < "${srcfile[$i]}"))); done

  # Over budget, every review gets the same byte share. ★ head -c MAKES a review
  # partial: a full review cut at 40KB is silent about everything after 40KB for
  # exactly the reason a truncated one is. Re-label it degraded here or the
  # silence rule below skips the reviews this function itself just truncated.
  local per=0
  if [ "$total" -gt "$cap" ]; then
    per=$(( cap / usable ))
    # A share of 0 would announce a truncation and then perform none, quietly
    # sending the whole oversized body anyway.
    [ "$per" -lt 1 ] && per=1
    echo "⚠ reviews total $total bytes, over CADRE_SYNTH_MAX ($cap). Truncating each to $per."
  fi

  # ★ TWO different facts, kept apart. "The reviewer stopped early" is a fact
  # about the reviewer's health. "Cadre sent only the first N bytes" is a fact
  # about what this function did to a reviewer that finished perfectly well.
  # Both mean the silence that follows proves nothing, so both get the silence
  # rule -- but telling the synthesizer a healthy reviewer "stopped early" is
  # simply false, and it is the kind of false that ends up quoted in a report.
  local partial=() capped=() n=0 text cut
  for i in "${!srcspec[@]}"; do
    cut=0
    if [ "$per" -gt 0 ] && [ "$(wc -c < "${srcfile[$i]}")" -gt "$per" ]; then
      text=$(head -c "$per" "${srcfile[$i]}"); cut=1
    else
      text=$(cat "${srcfile[$i]}")
    fi
    # A DIFFERENT delimiter, not just different prose. Under the same delimiter
    # as a full review the synthesizer has no handle to apply a different rule
    # to, however carefully the instructions are worded.
    if [ "${srcstate[$i]}" = degraded ]; then
      body="$body===== REVIEWER (PARTIAL, THIS REVIEWER STOPPED EARLY): ${srcspec[$i]} ====="$'\n'"$text"$'\n\n'
      partial+=("${srcspec[$i]}")
    elif [ "$cut" = 1 ]; then
      body="$body===== REVIEWER (COMPLETE, BUT CADRE SENT ONLY ITS FIRST $per BYTES): ${srcspec[$i]} ====="$'\n'"$text"$'\n\n'
      capped+=("${srcspec[$i]}")
    else
      body="$body===== REVIEWER: ${srcspec[$i]} ====="$'\n'"$text"$'\n\n'
      n=$((n + 1))
    fi
  done
  local short=("${partial[@]}" "${capped[@]}")
  # ★ Two different counts, and conflating them made cadre lie in prose while
  # the arithmetic stayed right. $n is "full text in front of the synthesizer",
  # which is the correct denominator floor for a finding only the full reviews
  # could have named. It is NOT the number of reviewers who finished: a capped
  # reviewer reviewed the whole diff and returned a complete review, cadre just
  # sent part of it. Reporting $n as "returned a complete review" understates a
  # healthy panel, and when every survivor was capped the console announced
  # "synthesizing 0 review(s)" for a run that was about to synthesize several.
  local completed=$((n + ${#capped[@]}))

  # ★ Tell the synthesizer who DIED. Without this it sees two reviews, reports
  # "2/2 agree", and the reader concludes the panel was unanimous when a third
  # of it never returned. The header line the prompt asks for is what carries
  # that; these members are NOT in the tags, because a reviewer that never ran
  # has no opinion to count either way.
  #
  # ★ dead[] is anything that is neither .md nor .md.partial, which is what
  # makes an INCONCLUSIVE run safe by construction: it lands here, and this
  # block already keeps it out of every denominator. That is the whole fix for
  # the false green -- no third delimiter, no new counting rule. The delimiter
  # says NO REVIEW rather than FAILED because a run that exited 0 and wrote 40KB
  # did not fail, and the prompt asks the synthesizer to describe these members
  # in the verdict spread.
  if [ ${#dead[@]} -gt 0 ]; then
    body="$body===== NO USABLE REVIEW: ${dead[*]} =====
These roster members produced no usable review. Say so in the verdict spread and
in the header line. Keep them out of every agreement tag: they neither agree nor
disagree with anything. This panel was ${#specs[@]} reviewers, of whom $completed
returned a complete review.

"
  fi
  # ★ Incomplete coverage breaks the agreement MATH, not just the prose, and in
  # the direction nobody checks. Tagging a finding [1/4] when two of the four
  # never reached that file reads as three dissents; it is one reviewer and two
  # absences. One rule for both causes, since the consequence is identical, but
  # each reviewer is listed under the cause that is actually true of it.
  if [ ${#short[@]} -gt 0 ]; then
    body="$body===== REVIEWERS WITH INCOMPLETE COVERAGE: ${short[*]} ====="$'\n'
    [ ${#partial[@]} -gt 0 ] && body="$body\
  ${partial[*]} -- stopped partway through, out of tokens or time.
"
    [ ${#capped[@]} -gt 0 ] && body="$body\
  ${capped[*]} -- reviewed the whole diff, but their review was too long for
  this synthesis and CADRE cut it. The reviewer is healthy; the copy you were
  given is not the whole of what it wrote. Do not say it stopped early.
"
    body="$body
Their text is a real review of the part you can see. Rules for them, unlike a
review you have in full:
  - On a finding one of them RAISED, it counts in both the numerator and the
    denominator, exactly like a complete review.
  - On a finding it never mentioned, it counts in NEITHER. That code is outside
    what you were given, so its silence is not agreement, disagreement, or
    clearance, and the denominator for that finding is smaller. Never list one
    under Disagreements for something it simply does not mention.
  - Give no overall verdict on behalf of a reviewer that stopped early.

Do the arithmetic for THIS panel. You have $n review(s) in full and ${#short[@]} with
incomplete coverage (${short[*]}). For each finding: denominator = $n, plus one
for EACH of those ${#short[@]} that raised that finding. So it is $n when none of them
raised it, and at most $((n + ${#short[@]})) when all of them did.

The low end is the case that gets written wrong. A defect only the full reviews
named is tagged [x/$n]. A bigger number there claims someone looked at that code
and declined to flag it, which is exactly backwards.

"
  fi

  local pf="$out/.synth-prompt" raw attempt=1 w
  { cat "$CADRE_ROOT/lib/prompts/synthesize.md"; echo; printf '%s' "$body"; } > "$pf"
  local pcount=""
  [ ${#capped[@]} -gt 0 ] && pcount="$pcount, ${#capped[@]} sent short"
  [ ${#partial[@]} -gt 0 ] && pcount="$pcount, ${#partial[@]} partial"
  echo "synthesizing $usable review(s)${pcount:+ ($n full$pcount)} with $synth ..."
  local a m mm=(); a=$(spec_agent "$synth"); m=$(spec_model "$synth")
  [ -n "$m" ] && mm=(-M "$m")
  # Capability preflight: a doomed synthesizer must not burn the merge call.
  local sblock sdecl sreason
  if sblock=$(capability_block "$synth" synth); then
    IFS=$'\t' read -r sdecl sreason <<< "$sblock"
    echo "synthesis SKIPPED by capability preflight ($sdecl: $sreason). Individual reviews are intact in $out." >&2
    rm -f "$pf"
    return 0
  fi
  local rc=0
  while :; do
    raw=$("$CADRE_ROOT/bin/agentcall" "$a" "${mm[@]}" -d /tmp -m ro < "$pf" 2>&1); rc=$?
    printf '%s' "$raw" > "$out/.synth-tmp"
    # ★ The THIRD retry loop. The commit that taught the two reviewer loops to
    # stop trusting a keyword scan over the adapter left this one asking the old
    # question, so a healthy short merge that discussed rate limiting burned
    # three retries and then got filed failed. Same principle, different test,
    # because a synthesis has no marker to be rescued by. See provider_refused.
    provider_refused "$out/.synth-tmp" "$rc" || { rm -f "$out/.synth-tmp"; break; }
    rm -f "$out/.synth-tmp"
    [ "$attempt" -ge "${CADRE_RETRIES:-3}" ] && break
    w=$(retry_wait "$attempt")
    echo "  synthesis rate limited, waiting ${w}s ($((attempt + 1))/${CADRE_RETRIES:-3})"
    sleep "$w"; attempt=$((attempt + 1))
  done
  rm -f "$pf"
  # ★ Same classifier the reviewers get. An auth error or an exhausted retry is
  # NON-EMPTY text, so testing only for emptiness filed the error itself as
  # synthesis.md and the reader saw a merged review that was really a 429. The
  # synthesizer is a model; it fails like one.
  # ★ Deliberately NOT three-state: only `ok` survives here. A partial merge is
  # worthless in a way a partial review is not, because the reviews it was
  # merging are already on disk and complete. Fail closed and keep them.
  printf '%s' "$raw" > "$out/.synth-tmp"
  if [ "$(classify_run "$out/.synth-tmp" "$rc" synth)" != ok ]; then
    mv "$out/.synth-tmp" "$out/synthesis.md.failed"
    # ★ Third consumer of the same split (#12). The synthesizer is a model and
    # fails like one, so "the provider returned nothing" and "cadre's clock cut
    # a live merge short" are as distinguishable here as on a review -- and the
    # second one is fixable by re-running with a bigger CADRE_TIMEOUT, which the
    # old flat message never suggested. No elapsed time is tracked on this path,
    # so the phrase is asked for without one rather than handed a made-up number.
    echo "synthesis $(failure_phrase "$out/synthesis.md.failed" "$rc"), kept as synthesis.md.failed." >&2
    echo "The individual reviews are intact in $out." >&2
    return 0
  fi
  rm -f "$out/.synth-tmp"
  { echo "# Synthesis ($synth)"; echo
    echo "_Model-produced and unverified. It merges what the reviewers said; it has"
    echo "not seen the code. Read the individual reviews before acting._"; echo
    printf '%s\n' "$raw"
  } > "$out/synthesis.md"
  echo "saved: $out/synthesis.md"
}

# ---- claims[]: the graded layer ----------------------------------------------
#
# ★ Deterministic, and it re-reads the reviewer files rather than taking anything
# out of the synthesis. cmd_synthesize above may hand the synthesizer only the
# first $per bytes of a review, and it keeps a dead reviewer out of the merge
# entirely. Both are right for a MERGE and both are lossy, so a claims layer
# built from the merge would be missing precisely the claims cadre itself
# declined to forward -- and a reviewer would be scored on the part of its review
# that happened to fit. Extraction starts at the file on disk, always in full.
#
# ★ Same regex as review_findings(), out of ONE variable rather than a second
# copy of it. That pattern is corpus-measured through four documented near-misses
# (see the comment above it in common.sh); a divergent copy here would drift in
# silence, because nothing in cadre compares the two numbers. A count of 13 and a
# projection of 4 would both look fine on their own. One pattern, two callers --
# `-c` there, `-n` here.
#
# location is deliberately null. The severity line carries a severity and the
# reviewer's own words; the file:line it is POINTING AT lives in the prose around
# it, and a guess would put invented coordinates in the layer we grade against.
engine_claims() {
  local out="$1"; shift
  local sp sl f state
  for sp in "$@"; do
    sl=$(slug "$sp")
    if   [ -s "$out/$sl.md" ];         then f="$sl.md";         state=ok
    elif [ -s "$out/$sl.md.partial" ]; then f="$sl.md.partial"; state=degraded
    # ★ No file means NO CLAIMS, which is not the same as a clean review, and
    # the difference is the whole false-green failure. This reviewer still shows
    # up in panel[] with state=absent, so a consumer counting denominators can
    # see that it was asked and never answered. Silence is not clearance.
    else continue
    fi
    engine_severity_lines "$out/$f" \
      | while IFS=$'\t' read -r ln sev text; do
          jq -cn --arg r "$sp" --arg st "$state" --arg fl "$f" \
                 --argjson ln "$ln" --arg sev "$sev" --arg tx "$text" \
            '{reviewer: $r, reviewer_state: $st,
              severity_stated: (if $sev == "" then null else $sev end),
              source: {file: $fl, line: $ln}, source_text: $tx,
              location: null}'
        done
  done
  return 0
}

# One severity line per output row: LINE <tab> SEVERITY <tab> TEXT.
#
# ★ The severity is re-matched with the SAME anchored pattern and the vocabulary
# word is taken from the END of that match, which is where the pattern puts it.
# Scanning the bare line for a vocabulary word instead would misread the one
# labelled shape the anchor deliberately admits: in `**Critical:** should-fix`
# the leftmost vocabulary word is in the LABEL, and the severity is the one after
# it. Taking the tail of the anchored match cannot make that mistake.
#
# ★ `-m1` rather than `| head -1`: this repo has already paid for a `grep`
# feeding a consumer that leaves early (agent_installed, 43 failing tests), and
# under `pipefail` the SIGPIPE would surface here as an empty severity on a line
# that matched perfectly well. `tail` is safe in the same pipeline for the
# opposite reason -- it reads to EOF, so nothing upstream is cut short.
#
# severity_stated is VERBATIM, never mapped onto blocking|should-fix|nit. The
# mapping is an interpretation ("major" -> which of the three?), and an
# interpretation belongs on findings[], not on the layer a reviewer is scored
# from. A consumer that wants the three-value vocabulary can normalize; it cannot
# recover the original once cadre has overwritten it.
#
# ★★ THE `return 0` IS LOAD-BEARING AND IT COST FOUR REAL CLAIMS. A review with
# no severity lines is a CLEAN REVIEW, not an error -- but `grep` says 1 for it,
# `pipefail` promotes that to the pipeline, and the 1 becomes this function's
# exit status. Every caller then reads "the extractor failed". Measured: a panel
# of finder,good ended its loop on `good`, which finds nothing, so engine_claims
# returned 1 and engine_write_findings' `|| claims='[]'` threw away four
# correctly extracted claims and wrote an empty array -- silently, over a review
# that had named a blocking bug. The projection LOOKED like an honest "this
# reviewer found nothing", which is the worst available failure for this file:
# the layer we grade from, wrong in the direction that clears a reviewer.
#
# Same shape as agent_installed's SIGPIPE bug and the same lesson: under
# `pipefail`, a `grep` whose no-match is a legitimate answer must have its status
# discarded on purpose, at the point where the meaning is known.
#
# ★ `-a` IS NOT OPTIONAL. One invalid byte anywhere in a review makes grep call
# the whole file binary: it prints "Binary file ... matches" and NOT ONE line
# number, so every finding in that review silently disappears from claims[] and
# the reviewer reads as having found nothing. Reviewers emit stray bytes for dull
# reasons -- a CLI's cursor escapes, a latin-1 quote, a truncated multi-byte
# character at a token boundary -- and this is the graded layer, so the loss lands
# in the direction that clears a reviewer that did its job. `-a` is in both GNU
# and BSD grep. Found by a cross-model review of this commit.
#
# ★ The digit guard is the belt to that braces, and it WARNS rather than dropping
# quietly. Anything that is not `<digits>:<text>` is not a grep -n line, so the
# claim cannot be trusted -- but a claim silently missing from the graded layer is
# exactly the failure being defended against, so it has to be said out loud.
engine_severity_lines() {
  local f="$1" ln text sev
  grep -anEi "$SEVERITY_RE" "$f" 2>/dev/null | while IFS=: read -r ln text; do
    case "$ln" in
      ''|*[!0-9]*)
        echo "cadre: ⚠ unparsable match in $f (\"$ln\"); that line is NOT in findings.json." >&2
        continue ;;
    esac
    sev=$(printf '%s' "$text" | grep -m1 -oEi "$SEVERITY_RE" \
          | grep -oEi "$SEVERITY_WORDS" | tail -1)
    printf '%s\t%s\t%s\n' "$ln" "$sev" "$text"
  done
  return 0
}

# ---- findings[]: the merged view ---------------------------------------------
#
# The synthesis is prose, so this is a LOSSY projection of it and says so in the
# contract: runs.jsonl and slots.tsv stay the durable per-seat record, and
# synthesis.md stays the thing a human reads. What survives into JSON is the one
# structured thing the synthesizer is asked to produce -- a severity and its
# [n/d] quorum -- so that a consumer can filter and count without a model.
#
# ★ agreement is copied, never computed. The denominator is the synthesizer's own
# arithmetic over a panel where absent reviewers are excluded by construction
# (the NO USABLE REVIEW block above), and recomputing it here from a count of
# files would quietly restore the bug that block exists to prevent: an absence
# read as a dissent. No tag means null, not [n/1].
#
# status/ledger_id start null and are the slots `cadre settle` fills in. They sit
# on findings[] and there is no equivalent on claims[] -- see the header.
engine_findings() {
  # ★ SEPARATE STATEMENTS, the same rule case_dir() in the smoke suite carries.
  # bash expands every word of a `local` line before any of its assignments take
  # effect, so `local out="$1" f="$out/synthesis.md"` sets f to "/synthesis.md".
  # This function shipped that way for one commit and WORKED, which is the part
  # worth remembering: dynamic scoping meant `$out` resolved to the caller's
  # variable of the same name, and engine_write_findings' `out` happens to hold
  # the identical value. Correct output, by coincidence, from a line that is
  # wrong -- and it fails the moment the caller renames its local or anything
  # calls this directly.
  local out="$1"
  local f="$out/synthesis.md"
  local q num den
  [ -s "$f" ] || return 0
  engine_severity_lines "$f" | while IFS=$'\t' read -r ln sev text; do
    q=$(printf '%s' "$text" | grep -m1 -oE '\[[0-9]+/[0-9]+\]')
    num=""; den=""
    if [ -n "$q" ]; then q=${q#[}; q=${q%]}; num=${q%/*}; den=${q#*/}; fi
    jq -cn --argjson ln "$ln" --arg sev "$sev" --arg tx "$text" \
           --arg num "$num" --arg den "$den" \
      '{severity: (if $sev == "" then null else $sev end),
        agreement: (if $den == "" then null
                    else {numerator: ($num | tonumber),
                          denominator: ($den | tonumber)} end),
        source: {file: "synthesis.md", line: $ln}, source_text: $tx,
        status: null, ledger_id: null}'
  done
  return 0
}

# Every roster member with the state its artifacts prove, absent ones included.
#
# ★ GATE-SKIPPED SEATS ARE IN HERE TOO, and they arrive by a separate channel
# because cmd_review never puts them in `specs` -- a seat whose `?min-lines` gate
# failed is filtered out before dispatch, so a panel built from `specs` alone
# reports a roster of two where the user asked for three. That is the same
# false-clearance shape as dropping a dead reviewer, just sourced from config
# instead of from a failure: the panel reads cleaner than it was. Found by a
# cross-model review of this commit.
#
# `skipped` is DISTINCT from `absent` and the difference is the whole point.
# absent = it was asked and did not answer, so its silence proves nothing.
# skipped = it was never asked, on purpose, and the reason is recorded.
# Collapsing them would turn a deliberate config choice into a reviewer failure.
engine_panel() {
  local out="$1" skipped_env="$2"; shift 2
  local sp sl state gate reason
  for sp in "$@"; do
    sl=$(slug "$sp")
    if   [ -s "$out/$sl.md" ];         then state=ok
    elif [ -s "$out/$sl.md.partial" ]; then state=degraded
    else state=absent
    fi
    jq -cn --arg r "$sp" --arg st "$state" \
      '{reviewer: $r, state: $st, skipped_gate: null, skipped_reason: null}'
  done
  # Same tab-separated `spec<TAB>gate<TAB>reason` rows cmd_review already builds
  # for CADRE_SKIPPED, so there is one format for a skip rather than two.
  [ -n "$skipped_env" ] || return 0
  while IFS=$'\t' read -r sp gate reason; do
    [ -n "$sp" ] || continue
    jq -cn --arg r "$sp" --arg g "$gate" --arg rs "$reason" \
      '{reviewer: $r, state: "skipped", skipped_gate: $g, skipped_reason: $rs}'
  done <<< "$skipped_env"
  return 0
}

# ---- findings.json -----------------------------------------------------------
#
# ★ Written on EVERY path, including the ones where no merge happened: a panel
# whose synthesizer was skipped by the capability preflight, whose merge came
# back a 429, or that had only one usable review, still produced claims. Hanging
# this off cmd_synthesize's success path would make a degraded run vanish from
# the benchmark's view entirely -- the same absence-read-as-nothing shape the NO
# USABLE REVIEW block above exists to stop, one layer up. So the caller invokes
# it unconditionally, `--synth none` included, and the synthesis status is
# derived from which artifact is on disk rather than from a flag some earlier
# `return 0` never got to set.
#
# ★ base_tree/reviewed_tree are content addresses and they are the identity of
# what was reviewed. Commit shas are not: run-review.sh builds the snapshot as an
# unreferenced stash commit that the next `git gc` reclaims, and on a dirty or
# `--full` tree there is no durable revision at all. They come out of
# manifest.txt, which cmd_review has already written. A manifest that cannot be
# read yields null and says so on stderr -- writing an invented tree id into the
# graded layer is the one outcome worse than admitting the gap.
engine_write_findings() {
  local out="$1" synth="$2" skipped_env="$3"; shift 3
  local specs=("$@")
  local mf="$out/manifest.txt" base="" rev="" sstatus
  [ -d "$out" ] || return 0

  if [ -s "$mf" ]; then
    base=$(sed -n 's/^base-tree:[[:space:]]*//p'     "$mf" | head -1)
    rev=$( sed -n 's/^reviewed-tree:[[:space:]]*//p' "$mf" | head -1)
  fi
  [ "$base" = unknown ] && base=""
  [ "$rev"  = unknown ] && rev=""
  { [ -n "$base" ] && [ -n "$rev" ]; } \
    || echo "cadre: ⚠ no tree ids in $mf; findings.json is not content-addressed." >&2

  # ★ Derived from the artifacts, not from a variable. `skipped` merges two
  # causes -- the capability preflight refused the synth slot, or fewer than two
  # reviews were usable to merge -- because on disk they are the same fact: no
  # merge was attempted. Neither is a failure, and neither costs the claims.
  if   [ -s "$out/synthesis.md" ];        then sstatus=ok
  elif [ -s "$out/synthesis.md.failed" ]; then sstatus=failed
  elif [ "$synth" = none ] || [ -z "$synth" ]; then sstatus=not_run
  else sstatus=skipped
  fi

  # ★ NO `|| x='[]'` HERE, and that is the fix for a bug this function shipped
  # with. Defaulting a failed projection to the empty array turns "the extractor
  # broke" into "the reviewer found nothing" -- identical on disk, opposite in
  # meaning, and the wrong one clears a reviewer that named a blocking bug. It
  # really happened: see the note on engine_severity_lines. `jq -s .` over no
  # input is already `[]` with status 0, so the empty case needs no help; the
  # nonzero case must reach the operator instead of being papered over.
  local claims findings panel
  claims=$(engine_claims     "$out" "${specs[@]}" | jq -s .)
  findings=$(engine_findings "$out"               | jq -s .)
  panel=$(engine_panel       "$out" "$skipped_env" "${specs[@]}" | jq -s .)
  if [ -z "$claims" ] || [ -z "$findings" ] || [ -z "$panel" ]; then
    echo "cadre: ⚠ the findings projection failed; no findings.json written for $out." >&2
    echo "     The reviews themselves are intact. Do not read a missing file as a clean panel." >&2
    return 0
  fi

  jq -n --arg base "$base" --arg rev "$rev" --arg synth "$synth" \
        --arg sstatus "$sstatus" \
        --argjson claims "$claims" --argjson findings "$findings" \
        --argjson panel "$panel" \
    '{schema: "cadre/findings@1",
      target: {base_tree:     (if $base == "" then null else $base end),
               reviewed_tree: (if $rev  == "" then null else $rev  end)},
      panel: $panel,
      synthesis: {status: $sstatus,
                  agent: (if $synth == "" or $synth == "none" then null
                          else $synth end)},
      verify: {ran: false},
      claims: $claims,
      findings: $findings}' > "$out/findings.json" \
    || { echo "cadre: ⚠ could not write $out/findings.json" >&2; return 0; }
  echo "saved: $out/findings.json"
}
