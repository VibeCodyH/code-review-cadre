#!/usr/bin/env bash
# Offline grading fixtures; no installed reviewer or judge CLI is invoked.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export CADRE_ROOT="$ROOT" CADRE_HOME="$TMP/state" CADRE_WORK="$TMP/work"
export CADRE_JUDGE=j1,j2 HOME="$TMP/user" PATH=/usr/bin:/bin
mkdir -p "$HOME" "$CADRE_HOME" "$TMP/repo"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/grade.sh"
PASS=0 FAIL=0
check() {
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; fi
}
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.name Test
git -C "$TMP/repo" config user.email test@example.invalid
printf 'fixture\n' > "$TMP/repo/app.txt"
git -C "$TMP/repo" add -- app.txt
git -C "$TMP/repo" commit -qm fixture
SHA=$(git -C "$TMP/repo" rev-parse HEAD)
SL=$(slug candidate)
REPORT="$CADRE_HOME/report-$SL-by-$(slug j1,j2).md"
HITS='{"items":{"K1":"HIT","K2":"HIT","K3":"HIT"},"quotes":{"K1":"dropped write","K2":"token leak","K3":"duplicate read"},"extras":[]}'
fixture() {
  rm -rf "$CADRE_HOME"
  mkdir -p "$CADRE_HOME/p1"
  printf 'p1|%s|%s|%s|key.md\n' "$SHA" "$TMP/repo" "$SHA" > "$CADRE_HOME/passes.conf"
  cat > "$CADRE_HOME/key.md" <<'EOF'
#### K1 blocking - the changed operation drops an important write
details
#### K2 blocking - the authentication response exposes a private token
details
#### K3 should-fix - the reader issues a duplicate database operation
details
EOF
  : > "$TMP/judge-calls"
}
runfile() { printf '%s/p1/%s-run%s.md' "$CADRE_HOME" "$SL" "$1"; }
good() { printf 'blocking: dropped write and token leak; duplicate read\nVerdict: blocking\n' > "$(runfile "$1")"; }
marker() { jq -n --arg reason "$2" '{reason:$reason}' > "$(runfile "$1").invalid.json"; }
record() {
  jq -cn --arg slug "$1" --arg run "$2" --arg rc "$3" \
    '{event:"complete",slug:$slug,run:$run,state:"failed",rc:$rc,secs:1}' >> "$CADRE_HOME/p1/runs.jsonl"
}
grade_one() {
  printf '%s\n' "$2" >> "$TMP/judge-calls"
  if grep -q 'judge-outage' "$2"; then printf '%s\n' "$UNUSABLE" > "$3"
  elif [ "${SPLIT:-}" = 1 ] && [ "$CADRE_JUDGE" = j2 ]; then
    jq '.items.K2="MISS"' <<< "$HITS" > "$3"
  else printf '%s\n' "$HITS" > "$3"; fi
}
grade() {
  RC=0
  run_gauntlet candidate "$1" 1 > "$TMP/output" 2>&1 || RC=$?
}
has() { check grep -qF -- "$1" "$REPORT"; }
lacks() { check test "$(grep -cF -- "$1" "$REPORT")" -eq 0; }

fixture
good 1
: > "$(runfile 2).failed"
printf 'provider returned unusable garbage\n' > "$(runfile 3).failed"
printf 'DID NOT RUN, misconfigured: install the tool\n' > "$(runfile 4).failed"
printf 'work in progress\n' > "$(runfile 5).failed"
# Another seat and an older attempt must not supply the timeout classification.
record "$SL" 5 1
record "$SL" 5 124
record another-seat 5 1
printf 'failed transport\n' > "$(runfile 6).failed"
marker 6 'Operator stopped this run to fix the route.'
printf 'I will look at the code.\n' > "$(runfile 7).inconclusive"
printf 'partial finding\n' > "$(runfile 8).partial"
good 10
printf 'judge-outage\n' >> "$(runfile 10)"
grade 10
check test "$RC" -eq 0
has '| graded-only | 2 / 2 | 3 / 3 |'
has '| delivery-inclusive | 2 / 6 | 3 / 9 |'
has '1 no-output and'
has '1 failed run(s) with output but no usable review'
has '### Operator-invalid runs'
has 'p1 run 6: Operator stopped this run to fix the route.'
has 'run 5: **UNUSABLE** (TIMED OUT'
has 'run 1: K1=HIT K2=HIT K3=HIT'
has '## Verdict: SEAT: can review alone'
check test "$(wc -l < "$TMP/judge-calls")" -eq 4

# Operator prose must not create a new pass or a grade in the panel matrix.
marker 6 'Harness corruption made the old judge claim K99=HIT.'
grade 10
PANEL=$("$ROOT/bin/cadre" panel)
check grep -q '^pass p1$' <<< "$PANEL"
check test "$(grep -c 'K99\|pass Hit rates\|pass Operator-invalid' <<< "$PANEL")" -eq 0

# All delivery failures still fail grading, but now retain their denominator.
fixture
: > "$(runfile 1).failed"
printf 'garbage\n' > "$(runfile 2).failed"
grade 2
check test "$RC" -eq 4
has '| graded-only | - (no eligible items) | - (no eligible items) |'
has '| delivery-inclusive | 0 / 4 | 0 / 6 |'
has '## Verdict: NOTHING MEASURED'
check test ! -s "$TMP/judge-calls"

# Recorded clock kills stay out of the delivery rate even when empty. Keep
# the existing no-output diagnostic and exit code; scoring has a stricter gate.
for timeout_rc in 124 137; do
  fixture
  : > "$(runfile 1).failed"
  record "$SL" 1 "$timeout_rc"
  grade 1
  check test "$RC" -eq 7
  has '| delivery-inclusive | - (no eligible items) | - (no eligible items) |'
  has '## Verdict: NOT MEASURED -- PROVIDER RETURNED NOTHING'
done

# Excluded failures cannot manufacture 0/0, including reasoned invalid runs.
fixture
printf 'DID NOT RUN, misconfigured: missing binary\n' > "$(runfile 1).failed"
printf 'DID NOT COMPLETE, killed at the 900s timeout\n' > "$(runfile 2).failed"
: > "$(runfile 3).failed"
marker 3 'Known harness routing error.'
grade 3
check test "$RC" -eq 4
has '| delivery-inclusive | - (no eligible items) | - (no eligible items) |'
has 'p1 run 3: Known harness routing error.'
lacks '0 / 0'

# A valid review can also be operator-invalid, with no judge call or HIT.
fixture
good 1
marker 1 'Reviewed the wrong checkout.'
grade 1
check test "$RC" -eq 4
has '| graded-only | - (no eligible items) | - (no eligible items) |'
has '| delivery-inclusive | - (no eligible items) | - (no eligible items) |'
check test ! -s "$TMP/judge-calls"
lacks 'K1=HIT'

# Judge outages remain a distinct failure with no delivery denominator.
fixture
printf 'judge-outage\nVerdict: blocking\n' > "$(runfile 1)"
grade 1
check test "$RC" -eq 5
has '## Verdict: NOTHING GRADED'
has '| delivery-inclusive | - (no eligible items) | - (no eligible items) |'

# Unresolved ranges keep the same uncertainty in the second rate.
fixture
good 1
: > "$(runfile 2).failed"
SPLIT=1 grade 2
has '| graded-only | 1 to 2 / 2 (1 UNRESOLVED) | 2 to 3 / 3 (1 UNRESOLVED) |'
has '| delivery-inclusive | 1 to 2 / 4 (1 UNRESOLVED) | 2 to 3 / 6 (1 UNRESOLVED) |'
has 'run 1: K1=HIT K2=UNRESOLVED K3=HIT'

# A malformed marker is rejected, visible, and never silently excludes a run.
for bad_marker in '{}' '{"reason":"  \n\t"}' '{"reason":false}' '{"reason":"\u0000"}' 'broken-json' '' \
                  '{"reason":"one"}{"reason":"two"}'; do
  fixture
  good 1
  printf '%s' "$bad_marker" > "$(runfile 1).invalid.json"
  grade 1
  check test "$RC" -eq 1
  has '### Rejected invalid-run markers'
  has 'nonblank string reason; exclusion rejected'
  has '## Verdict: SEAT: can review alone'
  has '| graded-only | 2 / 2 | 3 / 3 |'
  has '| delivery-inclusive | 2 / 2 | 3 / 3 |'
  has 'run 1: K1=HIT K2=HIT K3=HIT'
  lacks '### Operator-invalid runs'
done

# SUSPECT precedes both valid and malformed markers, even for failed artifacts
# and all-unusable reports. A marker cannot hide compromised evidence.
for suffix in '' .failed; do
  for reason in valid malformed; do
    fixture
    cp "$CADRE_HOME/key.md" "$(runfile 1)$suffix"
    if [ "$reason" = valid ]; then marker 1 'Operator says ignore this run.'
    else printf '{}\n' > "$(runfile 1).invalid.json"; fi
    grade 1
    check test "$RC" -ne 0
    has '## Verdict: INVALID, answer-key leak suspected'
    has 'Graded-only and delivery-inclusive: **NOT SCORED, answer-key leak suspected**'
    has 'p1 run 1: SUSPECT'
    lacks '### Operator-invalid runs'
    lacks '### Rejected invalid-run markers'
    check test ! -s "$TMP/judge-calls"
  done
done
fixture
good 1
cp "$CADRE_HOME/key.md" "$(runfile 2).failed"
marker 2 'Cannot hide this.'
grade 2
has '## Verdict: INVALID, answer-key leak suspected'
lacks '| delivery-inclusive |'
has '- blocking items hit: **NOT SCORED**'

# CLEAN probes have no denominator even when delivery fails.
fixture
printf '## CLEAN - no planted defects\n' > "$CADRE_HOME/key.md"
: > "$(runfile 1).failed"
grade 1
has '| delivery-inclusive | - (no eligible items) | - (no eligible items) |'

# Exercise dispatch's early-abort path with a real offline adapter. It must
# report delivery failures from p1, keep exit 4, and not count unattempted p2.
fixture
mkdir -p "$TMP/agents" "$TMP/bin"
export CADRE_AGENTS_D="$TMP/agents" PATH="$TMP/bin:/usr/bin:/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/candidate"
chmod +x "$TMP/bin/candidate"
printf 'run_candidate() { echo unusable-garbage; return 1; }\n' > "$TMP/agents/candidate.sh"
printf 'p2|%s|%s|%s|key.md\n' "$SHA" "$TMP/repo" "$SHA" >> "$CADRE_HOME/passes.conf"
RC=0
CADRE_RETRIES=1 run_gauntlet candidate 2 0 > "$TMP/output" 2>&1 || RC=$?
check test "$RC" -eq 4
has '| graded-only | - (no eligible items) | - (no eligible items) |'
has '| delivery-inclusive | 0 / 4 | 0 / 6 |'
has 'p2: NOT ATTEMPTED'
check test ! -s "$TMP/judge-calls"

# A marker invalidates one attempt. Resuming a failed slot must preserve the
# old reason/output and allow the new review to count. Reusing it does not
# dispatch again and therefore must keep any marker on that same review.
fixture
printf 'You have exceeded your monthly quota\n' > "$(runfile 1).failed"
marker 1 'Operator used an account with no remaining quota.'
cp "$(runfile 1).failed" "$TMP/prior.failed"
cp "$(runfile 1).invalid.json" "$TMP/prior.invalid.json"
grade 1
has 'p1 run 1: Operator used an account with no remaining quota.'
printf 'run_candidate() { echo "Verdict: ship it"; }\n' > "$TMP/agents/candidate.sh"
RC=0
run_gauntlet candidate 1 0 > "$TMP/output" 2>&1 || RC=$?
check test "$RC" -eq 0
has '| graded-only | 2 / 2 | 3 / 3 |'
has '| delivery-inclusive | 2 / 2 | 3 / 3 |'
check test ! -e "$(runfile 1).invalid.json"
archives=("$(runfile 1)".invalidated.*)
check test "${#archives[@]}" -eq 1
check cmp "$TMP/prior.failed" "${archives[0]}/$SL-run1.md.failed"
check cmp "$TMP/prior.invalid.json" "${archives[0]}/$SL-run1.md.invalid.json"
marker 1 'The completed review used the wrong checkout.'
RC=0
run_gauntlet candidate 1 0 > "$TMP/output" 2>&1 || RC=$?
check test "$RC" -eq 4
check test -f "$(runfile 1).invalid.json"
has 'p1 run 1: The completed review used the wrong checkout.'
has '| delivery-inclusive | - (no eligible items) | - (no eligible items) |'
archives=("$(runfile 1)".invalidated.*)
check test "${#archives[@]}" -eq 1

printf '%s passed; %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
