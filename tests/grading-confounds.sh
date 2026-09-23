#!/usr/bin/env bash
# Offline grading fixtures for #39: the regrade ledger, the confounds the
# footer names before the score, and the run-to-run noise floor. No reviewer
# or judge CLI is invoked.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export CADRE_ROOT="$ROOT" CADRE_HOME="$TMP/state" CADRE_WORK="$TMP/work"
export CADRE_JUDGE=j1 HOME="$TMP/user" PATH=/usr/bin:/bin
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
JS=$(slug j1)
REPORT="$CADRE_HOME/report-$SL-by-$JS.md"
fixture() {
  rm -rf "$CADRE_HOME"
  mkdir -p "$CADRE_HOME/p1"
  printf 'p1|%s|%s|%s|key.md\n' "$SHA" "$TMP/repo" "$SHA" > "$CADRE_HOME/passes.conf"
  cat > "$CADRE_HOME/key.md" <<'KEY'
#### K1 blocking - the changed operation drops an important write
details
#### K2 blocking - the authentication response exposes a private token
details
#### K3 should-fix - the reader issues a duplicate database operation
details
KEY
  : > "$TMP/judge-calls"
  JUDGE_SAYS='{"items":{"K1":"HIT","K2":"HIT","K3":"HIT"},"quotes":{"K1":"dropped write","K2":"token leak","K3":"duplicate read"},"extras":[]}'
}
runfile() { printf '%s/p1/%s-run%s.md' "$CADRE_HOME" "$SL" "$1"; }
gradefile() { printf '%s/p1/%s-run%s.by-%s.grade.json' "$CADRE_HOME" "$SL" "$1" "$JS"; }
good() { printf 'blocking: dropped write and token leak; duplicate read\nVerdict: blocking\n' > "$(runfile "$1")"; }
record() { # <run> <finish> <tokens> <cap>
  record_event "$CADRE_HOME/p1/runs.jsonl" event=complete slug="$SL" "run#=$1" state=ok "rc#=0" "secs#=1" \
    finish_reason="$2" "completion_tokens#=$3" "output_cap#=$4"
}
grade_one() {
  printf '%s\n' "$2" >> "$TMP/judge-calls"
  printf '%s\n' "$JUDGE_SAYS" > "$3"
}
grade() { # <runs> <rescore>
  RC=0
  run_gauntlet candidate "$1" "$2" > "$TMP/output" 2>&1 || RC=$?
}
has() { check grep -qF -- "$1" "$REPORT"; }
lacks() { check test "$(grep -cF -- "$1" "$REPORT")" -eq 0; }
ledger() { cat "$(gradefile "$1").regraded.jsonl"; }
line_no() { grep -nF -- "$1" "$REPORT" | head -1 | cut -d: -f1; }

# ---- 1. Auditable regrade ---------------------------------------------------
fixture
good 1
grade 1 1
check test "$RC" -eq 0
check test ! -e "$(gradefile 1).regraded.jsonl"      # first grade: nothing to keep
has 'item verdicts moved by this regrade: 0 across 0 run(s)'

# Same answer on a second reading is recorded, and moves nothing.
grade 1 1
check test "$(wc -l < "$(gradefile 1).regraded.jsonl")" -eq 1
check test "$(ledger 1 | jq -r '.changed | length')" -eq 0
check test "$(ledger 1 | jq -r '.prior_items.K2')" = HIT
check test "$(ledger 1 | jq -r '.key_sha256 | length')" -eq 64
check test "$(ledger 1 | jq -r '.harness_sha != null')" = true
lacks 'REGRADED, item verdicts moved'

# A moved verdict carries its prior value in the ledger AND in the report.
JUDGE_SAYS='{"items":{"K1":"HIT","K2":"MISS","K3":"HIT"},"quotes":{"K1":"dropped write","K3":"duplicate read"},"extras":[]}'
grade 1 1
check test "$RC" -eq 0
check test "$(wc -l < "$(gradefile 1).regraded.jsonl")" -eq 2
check test "$(ledger 1 | tail -1 | jq -r '.changed.K2.before')" = HIT
check test "$(ledger 1 | tail -1 | jq -r '.changed.K2.after')" = MISS
check test "$(ledger 1 | tail -1 | jq -r '.kept_prior')" = false
check test "$(jq -r '.items.K2' "$(gradefile 1)")" = MISS
has 'run 1: K1=HIT K2=MISS K3=HIT'
has 'REGRADED, item verdicts moved from the prior grade'
has "j1: K2 HIT→MISS (ledger: $SL-run1.by-$JS.grade.json.regraded.jsonl)"
has 'item verdicts moved by this regrade: 1 across 1 run(s)'
# ...and the table snapshots the ledger beside the grade it describes.
TABLE="${REPORT%.md}.table"
check test "$(jq -r '.runs[0].grades[0].regrade_log.file' "$TABLE/results.json")" = "grades/$(slug p1)/$SL-run1.by-$JS.grade.json.regraded.jsonl"
check cmp "$(gradefile 1).regraded.jsonl" "$TABLE/grades/$(slug p1)/$SL-run1.by-$JS.grade.json.regraded.jsonl"

# A regrade that comes back UNUSABLE keeps the prior grade on disk, unscored.
grade_one() { printf '%s\n' "$2" >> "$TMP/judge-calls"; printf '%s\n' "$UNUSABLE" > "$3"; printf 'You have exceeded your monthly quota\n' > "$3.judge-raw"; }
grade 1 1
check test "$RC" -eq 5
check test "$(jq -r '.items.K2' "$(gradefile 1)")" = MISS   # prior survived
check test "$(ledger 1 | tail -1 | jq -r '.kept_prior')" = true
check test "$(ledger 1 | tail -1 | jq -r '.unusable')" = true
check test -s "$(gradefile 1).regrade-failed.judge-raw"
has 'the PRIOR grade is kept on disk unscored'
has 'RATE-LIMITED or OUT OF QUOTA'
has 'regrades that returned unusable and KEPT the prior grade on disk, unscored: 1'
has '## Verdict: NOTHING GRADED'

# `cadre run` (rescore=0) reuses the grade and appends nothing.
grade_one() { printf '%s\n' "$2" >> "$TMP/judge-calls"; printf '%s\n' "$JUDGE_SAYS" > "$3"; }
: > "$TMP/judge-calls"
grade 1 0
check test ! -s "$TMP/judge-calls"
check test "$(wc -l < "$(gradefile 1).regraded.jsonl")" -eq 3
lacks 'item verdicts moved by this regrade'

# ---- 2. Confounds named before the score ------------------------------------
fixture
good 1
printf 'partial finding\n' > "$(runfile 2).partial"
: > "$(runfile 3).failed"
good 4
record 1 stop 300 2048
record 4 length 2048 2048
grade 4 1
check test "$RC" -eq 0
has '- runs not scored, output cut off (partial review on disk): 1'
has '- runs not scored, provider returned nothing: 1'
has '- scored runs whose adapter reported the output cap was hit: 1'
has 'run 4: ★ the adapter reports the OUTPUT CAP was hit (finish_reason=length, 2048 tokens of a 2048 cap)'
has '- output cap: **2048 tokens** (declared by the adapter on every scored run)'
# Every confound line sits ABOVE the hit line.
HIT_AT=$(line_no '- blocking items hit:')
check test "$(line_no '- output cap:')" -lt "$HIT_AT"
check test "$(line_no '- runs not scored, output cut off')" -lt "$HIT_AT"
check test "$(line_no '- run-to-run spread')" -lt "$HIT_AT"
check test "$(line_no '- item verdicts moved by this regrade')" -lt "$HIT_AT"

# ---- 3. Caps: mixed and unrecorded are said, never averaged ------------------
fixture
good 1; good 2
record 1 stop 100 2048
record 2 stop 100 4096
grade 2 1
has '- output cap: **mixed** (2048, 4096); the scored runs were not cap-matched'
fixture
good 1; good 2
record 1 stop 100 2048
grade 2 1
has '- output cap: **mixed** (2048; unrecorded on some scored runs)'
fixture
good 1
grade 1 1
has '- output cap: **not recorded** (no adapter declared one'

# ---- 4. Noise floor: run-to-run spread across sweeps -------------------------
fixture
good 1
grade 1 1
has '- run-to-run spread (blocking hit rate): **not measured** (1 run per pass'
has '- noise floor (run-to-run spread): **not measured**'
grade_report_metrics "$REPORT"
check test "$METRIC_SPREAD" = -

fixture
good 1; good 2
grade_one() {
  printf '%s\n' "$2" >> "$TMP/judge-calls"
  case "$2" in
    *run2.md) printf '{"items":{"K1":"HIT","K2":"MISS","K3":"HIT"},"quotes":{"K1":"dropped write","K3":"duplicate read"},"extras":[]}\n' > "$3" ;;
    *) printf '%s\n' "$JUDGE_SAYS" > "$3" ;;
  esac
}
grade 2 1
check test "$RC" -eq 0
has '- run-to-run spread (blocking hit rate): **50.0pp** (run 1: 2/2, run 2: 1/2); a difference between two seats smaller than this is noise'
has '- noise floor (run-to-run spread): **50.0pp**'
grade_report_metrics "$REPORT"
check test "$METRIC_SPREAD" = 50.0
check test "$METRIC_CAP" = -
check test "$METRIC_RATE" = '75.0% (3 / 4)'

# Two runs requested, one slot unusable everywhere: no second sweep, no floor.
fixture
good 1
: > "$(runfile 2).failed"
grade_one() { printf '%s\n' "$2" >> "$TMP/judge-calls"; printf '%s\n' "$JUDGE_SAYS" > "$3"; }
grade 2 1
has '- run-to-run spread (blocking hit rate): **not measured** (only 1 run slot produced graded blocking items)'

# ★ Two sweeps that did not grade the same items are not a spread. Pass p2's
# run 2 is unusable, so slot 1 carries 4 blocking items and slot 2 carries 2:
# dividing each by its own denominator prints a gap that is the missing pass.
fixture
mkdir -p "$CADRE_HOME/p2"
printf 'p2|%s|%s|%s|key.md\n' "$SHA" "$TMP/repo" "$SHA" >> "$CADRE_HOME/passes.conf"
p2run() { printf 'blocking: dropped write and token leak; duplicate read\nVerdict: blocking\n' > "$CADRE_HOME/p2/$SL-run$1.md"; }
good 1; good 2; p2run 1
: > "$CADRE_HOME/p2/$SL-run2.md.failed"
grade_one() {
  case "$2" in
    */p2/*run1.md) printf '{"items":{"K1":"HIT","K2":"MISS","K3":"HIT"},"quotes":{"K1":"a","K3":"c"},"extras":[]}\n' > "$3" ;;
    *) printf '%s\n' "$JUDGE_SAYS" > "$3" ;;
  esac
}
grade 2 1
check test "$RC" -eq 0
has '- run-to-run spread (blocking hit rate): **unavailable**, the sweeps did not grade the same items (run 1: 3/4, run 2: 2/2); a pass missing from one sweep moves this gap by the pass, not by the candidate'
lacks 'pp**'
grade_report_metrics "$REPORT"
check test "$METRIC_SPREAD" = -
# ...and an unavailable spread is NOT a floor for the panel table.
PANEL=$("$ROOT/bin/cadre" panel)
check grep -qF 'Noise floor: NOT MEASURED' <<< "$PANEL"

# ★ An UNRESOLVED item leaves each sweep a lower bound, so the gap between the
# bounds is partly the split. One judge reaches this through a quote credited
# to two items, which is the collision gate, not a disagreement.
fixture
good 1; good 2
grade_one() {
  case "$2" in
    *run2.md) printf '{"items":{"K1":"HIT","K2":"HIT","K3":"HIT"},"quotes":{"K1":"one sentence for both","K2":"one sentence for both","K3":"c"},"extras":[]}\n' > "$3" ;;
    *) printf '%s\n' "$JUDGE_SAYS" > "$3" ;;
  esac
}
grade 2 1
has 'K1 **UNRESOLVED**, credited to a sentence that also credits another item'
has '- run-to-run spread (blocking hit rate): **unavailable**, 2 UNRESOLVED item(s) leave each sweep a lower bound (run 1: 2/2, run 2: 0/2 (+2 unresolved)); tighten the key and re-grade'
grade_report_metrics "$REPORT"
check test "$METRIC_SPREAD" = -

# ---- Codex round 1 regressions ----------------------------------------------

# ★ EQUAL DENOMINATORS DO NOT PROVE EQUAL CONTENTS. p1 scores in slot 1 only and
# p2 in slot 2 only: both slots carry 2 blocking items over completely different
# passes, so a spread computed from them is 100% the difference between passes.
fixture
mkdir -p "$CADRE_HOME/p2"
printf 'p2|%s|%s|%s|key.md\n' "$SHA" "$TMP/repo" "$SHA" >> "$CADRE_HOME/passes.conf"
good 1
: > "$(runfile 2).failed"
printf 'blocking: dropped write and token leak; duplicate read\nVerdict: blocking\n' > "$CADRE_HOME/p2/$SL-run2.md"
: > "$CADRE_HOME/p2/$SL-run1.md.failed"
grade_one() {
  case "$2" in
    */p2/*) printf '{"items":{"K1":"MISS","K2":"MISS","K3":"MISS"},"quotes":{},"extras":[]}\n' > "$3" ;;
    *) printf '%s\n' "$JUDGE_SAYS" > "$3" ;;
  esac
}
grade 2 1
check test "$RC" -eq 0
has '- run-to-run spread (blocking hit rate): **unavailable**, the sweeps did not grade the same items (run 1: 2/2, run 2: 0/2)'
lacks 'pp**'
grade_report_metrics "$REPORT"
check test "$METRIC_SPREAD" = -

# ★ A pass whose DISPATCH aborted still contributes its cut-off and empty runs.
# The counters are read in the loop that precedes the abort check; counted in
# the grading loop they printed 0 over results that held one of each.
STUBROOT="$TMP/stubroot"
mkdir -p "$STUBROOT/lib"
for f in "$ROOT"/*; do
  [ "$(basename "$f")" = lib ] || ln -sfn "$f" "$STUBROOT/$(basename "$f")"
done
for f in "$ROOT"/lib/*; do
  [ "$(basename "$f")" = run-pass.sh ] || ln -sfn "$f" "$STUBROOT/lib/$(basename "$f")"
done
# Aborts on p2 only, so p1 still grades and the sweep reaches the normal
# footer -- which is where the counts appeared as 0 over results holding one
# of each. A sweep that aborts on its FIRST pass takes the NOTHING MEASURED
# footer instead and states no counts at all.
printf '%s\n' '#!/usr/bin/env bash' '[ "$1" = p2 ] && exit 4' 'exit 0' > "$STUBROOT/lib/run-pass.sh"
chmod +x "$STUBROOT/lib/run-pass.sh"
fixture
mkdir -p "$CADRE_HOME/p2"
printf 'p2|%s|%s|%s|key.md\n' "$SHA" "$TMP/repo" "$SHA" >> "$CADRE_HOME/passes.conf"
good 1; good 2
printf 'partial finding\n' > "$CADRE_HOME/p2/$SL-run1.md.partial"
: > "$CADRE_HOME/p2/$SL-run2.md.failed"
grade_one() { printf '%s\n' "$JUDGE_SAYS" > "$3"; }
CADRE_ROOT="$STUBROOT" grade 2 0
check test "$RC" -eq 4
has '- runs not scored, output cut off (partial review on disk): 1'
has '- runs not scored, provider returned nothing: 1'
has 'p2: no usable review, run-pass.sh exited 4'

# ★ Moved items and moved runs must count the same population. Judge j1 moves an
# item, j2 comes back unusable on that run: the item landed on disk, so gating
# the run count on a SCORED run reported "1 across 0 run(s)".
SAVED_JUDGE="$CADRE_JUDGE"
export CADRE_JUDGE=j1,j2
TWO_REPORT="$CADRE_HOME/report-$SL-by-$(slug j1,j2).md"
fixture
good 1; good 2
grade_one() { printf '%s\n' "$JUDGE_SAYS" > "$3"; }
grade 2 1
# Run 2 keeps the sweep scored, so the footer prints; run 1 is the case under
# test, where the moved grade landed and the OTHER judge then failed.
grade_one() {
  case "$2:$CADRE_JUDGE" in
    *run1.md:j2) printf '%s\n' "$UNUSABLE" > "$3" ;;
    *run1.md:*)  printf '{"items":{"K1":"HIT","K2":"MISS","K3":"HIT"},"quotes":{"K1":"a","K3":"c"},"extras":[]}\n' > "$3" ;;
    *) printf '%s\n' "$JUDGE_SAYS" > "$3" ;;
  esac
}
grade 2 1
# ★ Exit 5 even though run 2 scored: the refused regrade took run 1 out of the
# denominator, so a green exit would report a shrunken benchmark as a clean one.
check test "$RC" -eq 5
check grep -qF -- 'regrades that returned unusable and KEPT the prior grade on disk, unscored: 1' "$TWO_REPORT"
check grep -qF -- '- item verdicts moved by this regrade: 1 across 1 run(s)' "$TWO_REPORT"
check test "$(grep -cF -- '1 across 0 run(s)' "$TWO_REPORT")" -eq 0
check test "$(jq -r '.items.K2' "$(gradefile 1)")" = MISS
export CADRE_JUDGE="$SAVED_JUDGE"

# ★ A ledger that cannot be appended REFUSES the swap and keeps BOTH the prior
# grade and the reply that was not applied. A directory in the ledger's place is
# the cheapest unwritable path there is.
fixture
good 1
grade_one() { printf '%s\n' "$JUDGE_SAYS" > "$3"; }
grade 1 1
mkdir -p "$(gradefile 1).regraded.jsonl"
grade_one() {
  printf '{"items":{"K1":"MISS","K2":"MISS","K3":"MISS"},"quotes":{},"extras":[]}\n' > "$3"
  printf 'the reply that was not applied\n' > "$3.judge-raw"
}
grade 1 1
check test "$RC" -eq 5
check test "$(jq -r '.items.K1' "$(gradefile 1)")" = HIT
check test "$(jq -r '.items.K1' "$(gradefile 1).unapplied.json")" = MISS
check grep -qF 'the reply that was not applied' "$(gradefile 1).unapplied.judge-raw"
has 'the new grade is kept at'
rmdir "$(gradefile 1).regraded.jsonl"
# ...and applying a later grade clears both, so a stale file cannot be cited.
grade_one() { printf '%s\n' "$JUDGE_SAYS" > "$3"; }
grade 1 1
check test ! -e "$(gradefile 1).unapplied.json"
check test ! -e "$(gradefile 1).unapplied.judge-raw"

# ★ The saved table carries the refused regrade's reply. The report cites that
# file as the evidence for keeping the prior grade; a bundle without it cites an
# artifact it does not hold.
fixture
good 1
grade 1 1
grade_one() { printf '%s\n' "$UNUSABLE" > "$3"; printf 'You have exceeded your monthly quota\n' > "$3.judge-raw"; }
grade 1 1
TABLE="${REPORT%.md}.table"
REF=$(jq -r '.runs[0].grades[0].regrade_refused_raw.file' "$TABLE/results.json")
check test "$REF" = "grades/$(slug p1)/$SL-run1.by-$JS.grade.json.regrade-failed.judge-raw"
check cmp "$(gradefile 1).regrade-failed.judge-raw" "$TABLE/$REF"
check test "$(jq -r '.runs[0].grades[0].regrade_refused_raw.sha256 | length' "$TABLE/results.json")" -eq 64

# ★ The meta channel cannot put a non-JSON number on the run record. JSON has no
# leading zeros, and the record is what every downstream reader joins on.
META="$TMP/meta-probe"
printf 'output_cap=02048\ncompletion_tokens=0\nfinish=stop\n' > "$META"
check test "$(meta_num "$META" output_cap)" = 2048
check test "$(meta_num "$META" completion_tokens)" = 0
check test "$(meta_field "$META" finish)" = stop
printf 'output_cap=12 tokens\n' > "$META"
check test -z "$(meta_num "$META" output_cap)"
printf 'output_cap=9999999999999999999999\n' > "$META"
check test -z "$(meta_num "$META" output_cap)"
record_event "$TMP/probe.jsonl" event=complete "output_cap#=$(meta_num "$TMP/meta-probe" output_cap)"
check jq -e . "$TMP/probe.jsonl" >/dev/null
printf 'output_cap=02048\n' > "$META"
record_event "$TMP/probe2.jsonl" event=complete "output_cap#=$(meta_num "$META" output_cap)"
check jq -e '.output_cap == 2048' "$TMP/probe2.jsonl" >/dev/null

# ---- 5. The round floor (#23) -------------------------------------------------
# One round is one draw. Its rate is printed WITH its count, and no seat is
# recommended from it, in either direction; a DEFER is an act, not a rate.
grade_one() { printf '%s\n' "$JUDGE_SAYS" > "$3"; }
fixture
good 1
grade 1 1
check test "$RC" -eq 0
has '## Verdict: ONE ROUND, not slottable'
has 'At least one pass was scored in only 1 run'
has 'On the one round: Caught every blocking item in every run (2/2).'
has '- rounds per pass behind the blocking hit rate: **1** (the fewest scored runs any pass had); below the floor of 2, so no seat is recommended from it'
has '- blocking hit rate: **100.0% (2 / 2)** over **1** round(s) per pass; below the floor of 2'
check test "$(line_no '- rounds per pass behind')" -lt "$(line_no '- blocking items hit:')"
grade_report_metrics "$REPORT"
check test "$METRIC_ROUNDS" = 1
# Mutation: a second round is the only change, and the seat comes back.
good 2
grade 2 1
has '## Verdict: SEAT: can review alone'
has '- rounds per pass behind the blocking hit rate: **2** (the fewest scored runs any pass had)'
has '- blocking hit rate: **100.0% (4 / 4)** over **2** round(s) per pass'
lacks 'ONE ROUND'
lacks 'below the floor of 2'
grade_report_metrics "$REPORT"
check test "$METRIC_ROUNDS" = 2

# A LOW single round is the same draw: "caught only 0/2" falls to the floor too.
fixture
good 1
JUDGE_SAYS='{"items":{"K1":"MISS","K2":"MISS","K3":"MISS"},"quotes":{},"extras":[]}'
grade 1 1
has '## Verdict: ONE ROUND, not slottable'
has 'On the one round: Caught only 0/2 blocking items'
# ...but a quoted DEFER on a blocking item is evidence in hand, and stands.
fixture
good 1
JUDGE_SAYS='{"items":{"K1":"DEFER","K2":"HIT","K3":"HIT"},"quotes":{"K1":"argued it was fine","K2":"token leak","K3":"duplicate read"},"extras":[]}'
grade 1 1
has '## Verdict: DO NOT SLOT'
has 'Deferred on a BLOCKING item 1 time(s)'
lacks 'ONE ROUND'

# ★ Two run slots over DIFFERENT passes are one round of each, the same trap the
# spread line refuses: p1 scores only in slot 1, p2 only in slot 2.
fixture
mkdir -p "$CADRE_HOME/p2"
printf 'p2|%s|%s|%s|key.md\n' "$SHA" "$TMP/repo" "$SHA" >> "$CADRE_HOME/passes.conf"
good 1
: > "$(runfile 2).failed"
printf 'blocking: dropped write and token leak; duplicate read\nVerdict: blocking\n' > "$CADRE_HOME/p2/$SL-run2.md"
: > "$CADRE_HOME/p2/$SL-run1.md.failed"
grade 2 1
has '- rounds per pass behind the blocking hit rate: **1**'
has '## Verdict: ONE ROUND, not slottable'
# No blocking item graded is no rounds, not zero of them.
fixture
cat > "$CADRE_HOME/key.md" <<'KEY'
#### K1 nit - a comment is out of date
details
KEY
good 1
JUDGE_SAYS='{"items":{"K1":"HIT"},"quotes":{"K1":"dropped write"},"extras":[]}'
grade 1 1
has '- rounds per pass behind the blocking hit rate: **-** (no pass graded a blocking item)'
has '## Verdict: INCONCLUSIVE'
JUDGE_SAYS='{"items":{"K1":"HIT","K2":"HIT","K3":"HIT"},"quotes":{"K1":"dropped write","K2":"token leak","K3":"duplicate read"},"extras":[]}'

# ---- the declaration seam ----------------------------------------------------
# ★ Static, like tests/engine-seam.sh: these are crossings between the adapter
# and the record, and the fixtures above write the record directly, so deleting
# the wiring would red nothing. Reading the code for the crossing is the same
# trade that file already makes -- it proves the call site exists, not that a
# provider populated it.
seam() { check grep -qF -- "$2" "$ROOT/$1"; }
seam bin/agentcall 'cadre_finish() {'
seam bin/agentcall 'cadre_cap() {'
seam bin/agentcall "printf 'finish=%s"
seam bin/agentcall "printf 'output_cap=%s"
seam bin/agentcall "printf 'completion_tokens=%s"
for f in lib/run-pass.sh lib/run-review.sh; do
  seam "$f" 'finish_reason="$(meta_field'
  seam "$f" '"completion_tokens#=$(meta_num'
  seam "$f" '"output_cap#=$(meta_num'
done
# The ollama adapter reads the RESPONSE, never the request: a cap echoed back
# from what cadre asked for is not a measurement of what served.
seam agents.d/ollama.sh 'cadre_cap "$cap"'
seam agents.d/ollama.sh ".done_reason // empty"
seam agents.d/ollama.sh ".eval_count // empty"
# A non-numeric cap is refused outright rather than written to the record.
CAPMETA="$TMP/capmeta"
: > "$CAPMETA"
CADRE_RUN_META="$CAPMETA" bash -c '. <(sed -n "/^cadre_cap() {/,/^}/p" "$0"); cadre_cap "not-a-number"; cadre_cap 4096' "$ROOT/bin/agentcall"
check test "$(meta_num "$CAPMETA" output_cap)" = 4096
check test "$(grep -c output_cap "$CAPMETA")" -eq 1

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
