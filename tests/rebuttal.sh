#!/usr/bin/env bash
# `cadre review --rebut` (#4): the opt-in rebuttal round. Local stub adapters
# only. Each stub reviews with fixed findings, then, handed the rebuttal brief,
# finds each finding by a keyword in the brief and answers it the way this file
# tells it to. The expected marks come from the rule in the issue -- a refusal
# makes a finding contested whatever else held it, the author refuting its own
# finding retracts it, nobody else answering leaves it untested -- applied by
# hand to those fixed answers, not read back out of the code.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0
check() {
  local name="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); echo "  ok   $name"
  else FAIL=$((FAIL + 1)); echo "  FAIL $name"; fi
}
mkdir -p "$SANDBOX/bin" "$SANDBOX/agents.d" "$SANDBOX/state" "$SANDBOX/seen"
for a in alpha beta gamma broken merger; do
  printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/$a"; chmod +x "$SANDBOX/bin/$a"
done

# $SANDBOX/mode picks the rebuttal script: `main`, or `rough` (a truncated
# answer, a non-answer, and an id answered twice).
# fid KEY: the F-number whose block in the brief carries KEY.
cat > "$SANDBOX/agents.d/_shared.inc" <<A
fid() { printf '%s\n' "\$prompt" | awk -v k="\$1" '/^F[0-9]+\$/ { id = \$0 } index(\$0, k) { print id; exit }'; }
is_rebut() { printf '%s\n' "\$prompt" | grep -q '^===== FINDINGS ('; }
mode() { cat "$SANDBOX/mode"; }
A
cat > "$SANDBOX/agents.d/alpha.sh" <<A
. "$SANDBOX/agents.d/_shared.inc"
run_alpha() {
  if is_rebut; then
    printf '%s\n' "\$prompt" > "$SANDBOX/seen/alpha-rebut.txt"
    if [ "\$(mode)" = rough ]; then
      echo "\$(fid KW-THREE): HOLDS - looked fine at first"
      echo "\$(fid KW-THREE): REFUTED - on a second read the guard is there"
    else
      echo "**\$(fid KW-ONE):** HOLDS — the delete runs before the check, src/app.js:3"
      echo "\$(fid KW-THREE): CANNOT TELL - would need the caller"
    fi
    echo "Verdict: rebuttal complete"
    return 0
  fi
  echo "- blocking: src/app.js:3 KW-ONE drops the row before the check"
  echo "  The delete runs first, so a failed check has already lost the row."
  echo "- should-fix: src/app.js:9 KW-TWO leaks the handle"
  echo "Verdict: blocking"
}
A
cat > "$SANDBOX/agents.d/beta.sh" <<A
. "$SANDBOX/agents.d/_shared.inc"
run_beta() {
  if is_rebut; then
    echo "- \$(fid KW-ONE) - refuted: the check at src/app.js:2 runs first"
    if [ "\$(mode)" = rough ]; then echo "_TRUNCATED"; return 0; fi
    echo "\$(fid KW-TWO): HOLDS - the handle is never closed"
    echo "\$(fid KW-THREE): REFUTED - my mistake, the loop bound is right"
    echo "Verdict: rebuttal complete"
    return 0
  fi
  echo "- should-fix: src/app.js:5 KW-THREE is off by one"
  echo "Verdict: should-fix"
}
A
cat > "$SANDBOX/agents.d/gamma.sh" <<A
. "$SANDBOX/agents.d/_shared.inc"
run_gamma() {
  if is_rebut; then
    if [ "\$(mode)" = rough ]; then
      echo "I read the findings and the code. Overall the change looks careful."
      return 0
    fi
    echo "\$(fid KW-ONE): holds - confirmed by inspection"
    echo "\$(fid KW-TWO): HOLDS - same"
    echo "\$(fid KW-FOUR): HOLDS - mine, and I still think so"
    echo "Verdict: rebuttal complete"
    return 0
  fi
  echo "- nit: src/app.js:1 KW-FOUR is a vague name"
  echo "Verdict: ship it"
}
A
cat > "$SANDBOX/agents.d/broken.sh" <<'A'
run_broken() { return 1; }
A
cat > "$SANDBOX/agents.d/merger.sh" <<A
run_merger() {
  printf '%s\n' "\$prompt" > "$SANDBOX/seen/synth-prompt.txt"
  echo "- should-fix: merged [1/3]"
  echo "Verdict: should-fix"
}
A

run_cadre() {
  CADRE_ROOT="$ROOT" CADRE_HOME="$SANDBOX/state" CADRE_WORK="$SANDBOX/work" \
    CADRE_AGENTS_D="$SANDBOX/agents.d" PATH="$SANDBOX/bin:$PATH" \
    "$ROOT/bin/cadre" "$@" 2>&1
}
review() {  # <label> <mode> <args...>: must succeed
  local label="$1"; echo "$2" > "$SANDBOX/mode"; shift 2
  rm -f "$SANDBOX/seen/"*
  OUT=$(run_cadre review --label "$label" "$@"); RC=$?
  R="$SANDBOX/state/reviews/$label"
  [ "$RC" -eq 0 ] || printf '%s\n' "$OUT"
  check "$label completes" test "$RC" -eq 0
}
has() { grep -qF -- "$1" "$2"; }
lacks() { ! has "$1" "$2"; }
eq() { [ "$1" = "$2" ] || { echo "    got: $1 (want $2)"; return 1; }; }
# mark KEY: the mark on the finding whose source text carries KEY.
mark() { jq -r --arg k "$1" '.marks[] | select(.source_text | contains($k)) | .mark' "$R/rebuttal.json"; }
field() { jq -c --arg k "$1" ".marks[] | select(.source_text | contains(\$k)) | $2" "$R/rebuttal.json"; }
events() { jq -r --arg e "$1" 'select(.event == $e) | .seat' "$R/runs.jsonl" | wc -l | tr -d ' '; }

S="$SANDBOX/repo"
git init -q -b main "$S" && git -C "$S" config user.name Test \
  && git -C "$S" config user.email test@example.invalid || exit 1
mkdir -p "$S/src"; printf 'one\n' > "$S/src/app.js"; git -C "$S" add .; git -C "$S" commit -qm initial
git -C "$S" checkout -qb feature
printf 'one\ntwo\n' > "$S/src/app.js"; git -C "$S" add .; git -C "$S" commit -qm change
cd "$S" || exit 1

echo '== off unless asked =='
review plain main --base main --synth none --roster alpha,beta,gamma
check 'no rebuttal.json' test ! -e "$R/rebuttal.json"
check 'no rebuttal artifacts' test -z "$(ls "$R" | grep -F .rebut.)"
check 'no rebut events' eq "$(events rebut_complete)" 0
check 'findings.json has no rebuttal key' eq "$(jq 'has("rebuttal")' "$R/findings.json")" false
check 'report has no rebuttal section' lacks '## Rebuttal round' "$R/report.md"
check 'panel event has no rebut_secs' eq "$(jq -r 'select(.event == "panel") | has("rebut_secs")' "$R/runs.jsonl")" false
PLAIN_CLAIMS=$(jq -c .claims "$R/findings.json")

echo '== the marks =='
review rebut main --base main --synth merger --roster alpha,beta,gamma --rebut
check 'KW-ONE: refuted by beta, held by gamma -> contested' eq "$(mark KW-ONE)" contested
check 'KW-TWO: held by beta and gamma, refuted by none -> survived' eq "$(mark KW-TWO)" survived
check 'KW-THREE: its author refutes, nobody holds -> retracted' eq "$(mark KW-THREE)" retracted
check 'KW-FOUR: only its author answers -> untested' eq "$(mark KW-FOUR)" untested
check 'author vote kept apart from the peers' eq "$(field KW-ONE '[.author_vote, .held_by, .refuted_by]')" '["HOLDS",["gamma"],["beta"]]'
check 'unanswered is listed as no vote' eq "$(field KW-THREE '.no_vote')" '["gamma"]'
check 'refutation reason recorded' eq "$(field KW-ONE '.votes[] | select(.reviewer == "beta") | .reason')" '"the check at src/app.js:2 runs first"'
check 'every rebutter answered something' eq "$(jq -c '[.rebutters[] | .state]' "$R/rebuttal.json")" '["ok","ok","ok"]'
# Interleaved: one finding from each review in turn, then alpha's second.
check 'findings are interleaved across reviews' eq "$(jq -c '[.marks[] | .reviewer]' "$R/rebuttal.json")" '["alpha","beta","gamma","alpha"]'
check 'the brief names no seat' test -z "$(grep -oiE 'alpha|beta|gamma' "$SANDBOX/seen/alpha-rebut.txt")"
check 'the brief carries the finding prose, not just its line' has 'The delete runs first' "$SANDBOX/seen/alpha-rebut.txt"
# The checkout is built from synthetic commits, so the base to name is the one
# the review brief named, not main's sha in the user's repo.
REVIEW_DIFF=$(grep -o 'git diff [0-9a-f]*\.\.\.HEAD' "$R/prompt.txt" | head -1)
check 'the brief names the same diff the reviews checked' has "\`$REVIEW_DIFF\`" "$SANDBOX/seen/alpha-rebut.txt"
check 'the verdict line is not put to the panel' lacks 'Verdict: blocking' "$SANDBOX/seen/alpha-rebut.txt"
check 'claims[] is untouched by the round' eq "$(jq -c .claims "$R/findings.json")" "$PLAIN_CLAIMS"
check 'findings.json carries the marks beside claims[]' eq "$(jq -r '.rebuttal.marks | length' "$R/findings.json")" 4
check 'still one completion per seat' eq "$(events complete)" 3
check 'one rebut completion per seat' eq "$(events rebut_complete)" 3
check 'slots.tsv still one row per seat' eq "$(wc -l < "$R/slots.tsv" | tr -d ' ')" 3
ALPHA=$(cd "$R" && ls | grep -E '^alpha-[0-9]+\.md$')
check 'seat review untouched by its rebuttal' has 'KW-ONE drops the row' "$R/$ALPHA"
check 'rebuttal answers kept beside it' test -s "$R/${ALPHA%.md}.rebut.md"
check 'report leads with the counts' has '**1 contested, 1 retracted, 1 untested, 1 survived.**' "$R/report.md"
check 'report lists the refutation under Contested' has '`beta` REFUTED: the check at src/app.js:2 runs first' "$R/report.md"
check 'report states the spend outside the seat rows' has '> Rebuttal round: 3 call(s)' "$R/report.md"
check 'panel seconds reconcile with the round in them' eq "$(jq -r 'select(.event == "panel") | .wall_secs == ((.prerun_secs // 0) + .seat_secs + .rebut_secs + .unattributed_secs)' "$R/runs.jsonl")" true
check 'synthesizer is handed the counted marks' has 'REBUTTAL ROUND (COUNTED BY CADRE, NOT A MODEL)' "$SANDBOX/seen/synth-prompt.txt"
check 'synthesizer sees the split, not a verdict on it' has '-> CONTESTED (held: gamma; refuted: beta)' "$SANDBOX/seen/synth-prompt.txt"
check 'synthesizer is told not to break the tie' has 'do not decide between them' "$SANDBOX/seen/synth-prompt.txt"
if command -v python3 >/dev/null 2>&1; then
  EXPORT_OUT=$(run_cadre export-evidence "$R" "$SANDBOX/evidence"); EXPORT_RC=$?
  [ "$EXPORT_RC" -eq 0 ] || printf '%s\n' "$EXPORT_OUT"
  check 'a rebuttal panel still exports' test "$EXPORT_RC" -eq 0
  check 'export carries rebuttal.json' test -s "$SANDBOX/evidence/shared/rebuttal.json"
  check 'export carries each seat'"'"'s answers' test -n "$(find "$SANDBOX/evidence/cells" -name rebuttal.md | head -1)"
fi

echo '== the same marks with seats in parallel =='
SEQ_MARKS=$(jq -c '[.marks[] | .mark]' "$R/rebuttal.json")
review rebut-jobs main --base main --synth none --roster alpha,beta,gamma --rebut --jobs 2
check 'parallel rebuttals give the sequential marks' eq "$(jq -c '[.marks[] | .mark]' "$R/rebuttal.json")" "$SEQ_MARKS"
check 'every parallel rebutter is recorded' eq "$(jq -c '[.rebutters[] | .state]' "$R/rebuttal.json")" '["ok","ok","ok"]'
check 'one rebut completion per seat in parallel' eq "$(events rebut_complete)" 3

echo '== a whole-tree review =='
review rebut-full main --full --synth none --roster alpha,beta,gamma --rebut
check 'the round runs on --full' eq "$(jq -r '.ran' "$R/rebuttal.json")" true
check 'the brief names the tree, not a diff' has 'this checkout as it stands' "$SANDBOX/seen/alpha-rebut.txt"

echo '== degraded, inconclusive, and a contradiction =='
review rough rough --base main --synth none --roster alpha,beta,gamma --rebut
check 'truncated answer is degraded' eq "$(jq -r '.rebutters[] | select(.reviewer == "beta") | .state' "$R/rebuttal.json")" degraded
check 'text with no answers is inconclusive' eq "$(jq -r '.rebutters[] | select(.reviewer == "gamma") | .state' "$R/rebuttal.json")" inconclusive
check 'a degraded refusal still counts -> contested' eq "$(mark KW-ONE)" contested
check 'unreached by the degraded seat, no other answer -> untested' eq "$(mark KW-TWO)" untested
check 'an id answered both ways is no vote' eq "$(field KW-THREE '[.conflicting, .mark]')" '[["alpha"],"untested"]'
check 'the inconclusive seat casts no vote anywhere' eq "$(jq -r '[.marks[] | .votes[] | select(.reviewer == "gamma")] | length' "$R/rebuttal.json")" 0
check 'report names the degraded rebutter' has '`beta` **DEGRADED**' "$R/report.md"

echo '== too few reviews to rebut =='
review thin main --base main --synth none --roster alpha,broken --rebut
check 'skipped, with the reason recorded' eq "$(jq -r '.ran' "$R/rebuttal.json")" false
check 'report says it was skipped' has 'Requested, but skipped: 1 usable review(s)' "$R/report.md"
check 'no seat was asked' eq "$(events rebut_dispatch)" 0
check 'skip is carried into findings.json' eq "$(jq -r '.rebuttal.ran' "$R/findings.json")" false

echo
echo "rebuttal: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
