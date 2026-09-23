#!/usr/bin/env bash
# Offline report and panel fixtures. No provider or judge CLI is called.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export CADRE_ROOT="$ROOT" CADRE_HOME="$TMP/state" CADRE_WORK="$TMP/work"
export HOME="$TMP/user" PATH=/usr/bin:/bin CADRE_JUDGE=j1,j2
mkdir -p "$HOME" "$CADRE_HOME" "$TMP/repo"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/grade.sh"
PASS=0 FAIL=0
check() {
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; fi
}
report() { # <file> <spec> <hits> <cost> [verdict] [rounds]
  cat > "$CADRE_HOME/$1" <<EOF
# Gauntlet: \`$2\`

## p1
- run 1: K1=HIT K2=MISS K3=MISS
## Verdict: ${5:-SEAT: needs a second reader}
- rounds per pass behind the blocking hit rate: **${6:-2}** (the fewest scored runs any pass had)
- blocking items hit: **$3**
- est. tokens per blocking item hit: **$4**
EOF
}
report report-a-by-j1.md alpha '1 / 2' 40
grade_report_metrics "$CADRE_HOME/report-a-by-j1.md"
check test "$METRIC_RATE" = '50.0% (1 / 2)'
check test "$METRIC_COST" = 40
report report-a-by-j2.md alpha '1 to 2 / 4' 80
sed -i 's/1 to 2 \/ 4\*\*$/1 to 2 \/ 4** (1 UNRESOLVED)/' "$CADRE_HOME/report-a-by-j2.md"
grade_report_metrics "$CADRE_HOME/report-a-by-j2.md"
check test "$METRIC_RATE" = '25.0% to 50.0% (1 to 2 / 4; UNRESOLVED)'
check test "$METRIC_COST" = 80
report report-nohits.md nohits '0 / 2' -
report report-missing.md missing-receipt '2 / 2' -
report report-clean.md clean '0 / 0' - INCONCLUSIVE
report report-invalid.md leaked '999 / 999' 1 'INVALID, answer-key leak suspected'
sed -i 's/K3=MISS/K3=HIT/' "$CADRE_HOME/report-invalid.md"
report report-unusable.md unusable '9 / 9' 1 'NOTHING GRADED'
report report-scope.md scoped '9 / 9' 1
sed -i '1c# One pass: `scoped` on `p1`' "$CADRE_HOME/report-scope.md"
cat > "$CADRE_HOME/report-old.md" <<'EOF'
# Gauntlet: `old`
## p1
- run 1: K1=MISS K2=HIT K3=MISS
## Verdict: SEAT: needs a second reader
EOF
# Operator prose before or after the footer cannot replace the known fields.
printf '\n### Operator-invalid runs\n- p1 run 2: old cost was - est. tokens per blocking item hit: **99999** and - blocking items hit: **999 / 999**\n' \
  >> "$CADRE_HOME/report-a-by-j1.md"
OUT=$("$ROOT/bin/cadre" panel --save)
check grep -qF 'Graded-only cost and hit rates (observational)' <<< "$OUT"
check grep -qE '^alpha.*judge: j1.*40 +2 +50\.0% \(1 / 2\)$' <<< "$OUT"
check grep -qE '^alpha.*judge: j2.*80 +2 +25\.0% to 50\.0%.*UNRESOLVED' <<< "$OUT"
check grep -qE '^old +- +- +-$' <<< "$OUT"
check grep -qE '^clean +- +2 +-$' <<< "$OUT"
check grep -qE '^nohits +- +2 +0\.0% \(0 / 2\)$' <<< "$OUT"
check grep -qE '^missing-receipt +- +2 +100\.0% \(2 / 2\)$' <<< "$OUT"
check grep -qE '^unusable +- +2 +-$' <<< "$OUT"
check grep -qF 'Observed blocking hit-rate bounds: 0.0% to 100.0% (4 report rows).' <<< "$OUT"
check grep -qF 'Observed est. tokens per credited blocking hit: 40 to 80 (2 report rows).' <<< "$OUT"
check grep -qF 'NOTHING in this lineup catches: p1/K3' <<< "$OUT"
check test "$(grep -c '^scoped ' <<< "$OUT")" -eq 0
check test "$(grep -c '99999\|999 / 999' <<< "$OUT")" -eq 0
check test "$(grep -n '^Graded-only cost' <<< "$OUT" | cut -d: -f1)" -lt "$(grep -n '^pass p1$' <<< "$OUT" | cut -d: -f1)"
check grep -qF '#   Observed est. tokens per credited blocking hit: 40 to 80' "$CADRE_HOME/roster"
check grep -q '^#   pass p1$' "$CADRE_HOME/roster"

# Costs are numeric: lexicographic ordering would put 10 before 2.
sed -i 's/[*][*]40[*][*]/**10**/' "$CADRE_HOME/report-a-by-j1.md"
sed -i 's/[*][*]80[*][*]/**2**/' "$CADRE_HOME/report-a-by-j2.md"
OUT=$("$ROOT/bin/cadre" panel)
check grep -qF 'Observed est. tokens per credited blocking hit: 2 to 10 (2 report rows).' <<< "$OUT"

# Partial denominators stay visible at both the front and in panel rows.
sed -i 's/[*][*]10[*][*]$/**10** (partial denominator)/' "$CADRE_HOME/report-a-by-j1.md"
frontload_grade_cost "$CADRE_HOME/report-a-by-j1.md"
check grep -qF 'est. tokens per credited blocking hit: **10** (partial denominator)' "$CADRE_HOME/report-a-by-j1.md"
OUT=$("$ROOT/bin/cadre" panel)
check grep -qE '^alpha.*judge: j1.*10 +2 +50\.0%.*partial denominator' <<< "$OUT"

# A missing cost must not erase a known partial hit-rate denominator. These
# verdicts do not carry INCOMPLETE, so the footer is the only surviving receipt.
report report-partial-zero.md partial-zero '0 / 2' - 'DO NOT SLOT'
sed -i 's/[*][*]-[*][*]$/**-** (partial denominator)/' "$CADRE_HOME/report-partial-zero.md"
frontload_grade_cost "$CADRE_HOME/report-partial-zero.md"
check grep -qF 'blocking hit rate: **0.0% (0 / 2)** (partial denominator)' "$CADRE_HOME/report-partial-zero.md"
check grep -qF 'est. tokens per credited blocking hit: **-** (partial denominator)' "$CADRE_HOME/report-partial-zero.md"
report report-partial-unresolved.md partial-unresolved '0 to 1 / 2' - UNRESOLVED
sed -i -e 's/0 to 1 \/ 2\*\*$/0 to 1 \/ 2** (1 UNRESOLVED)/' \
  -e 's/[*][*]-[*][*]$/**-** (partial denominator)/' "$CADRE_HOME/report-partial-unresolved.md"
frontload_grade_cost "$CADRE_HOME/report-partial-unresolved.md"
check grep -qF 'blocking hit rate: **0.0% to 50.0% (0 to 1 / 2; UNRESOLVED)** (partial denominator)' "$CADRE_HOME/report-partial-unresolved.md"
OUT=$("$ROOT/bin/cadre" panel)
check grep -qE '^partial-zero +- +2 +0\.0%.*partial denominator' <<< "$OUT"
check grep -qE '^partial-unresolved +- +2 +0\.0% to 50\.0%.*partial denominator' <<< "$OUT"

# No available metrics means no spread, including genuinely missing legacy data.
rm -f "$CADRE_HOME"/report-*.md
report report-empty.md old '0 / 0' 0 INCONCLUSIVE
grade_report_metrics "$CADRE_HOME/report-empty.md"
check test "$METRIC_RATE" = -
check test "$METRIC_COST" = -
OUT=$("$ROOT/bin/cadre" panel)
check grep -qF 'Observed blocking hit-rate bounds: - (no eligible report rows).' <<< "$OUT"
check grep -qF 'Observed est. tokens per credited blocking hit: - (no eligible report rows).' <<< "$OUT"

# Inconsistent counts and duplicate anchored fields cannot create measurements.
for hits in '3 / 2' '2 to 1 / 4' '-'; do
  report report-empty.md old "$hits" 5
  grade_report_metrics "$CADRE_HOME/report-empty.md"
  check test "$METRIC_RATE" = -
  check test "$METRIC_COST" = -
done
report report-empty.md old '1 / 2' 5
printf '%s\n' '- blocking items hit: **2 / 2**' >> "$CADRE_HOME/report-empty.md"
grade_report_metrics "$CADRE_HOME/report-empty.md"
check test "$METRIC_RATE" = -
check test "$METRIC_COST" = -
# A contradictory UNRESOLVED marker cannot become an exact percentage.
report report-empty.md old '1 to 1 / 2' 5
sed -i 's/1 to 1 \/ 2\*\*$/1 to 1 \/ 2** (1 UNRESOLVED)/' "$CADRE_HOME/report-empty.md"
grade_report_metrics "$CADRE_HOME/report-empty.md"
check test "$METRIC_RATE" = -
check test "$METRIC_COST" = -
# Different files claiming the same candidate/judge row stay ambiguous.
report report-first-by-j.md duplicate '1 / 2' 10
report report-second-by-j.md duplicate '2 / 2' 20
OUT=$("$ROOT/bin/cadre" panel)
check grep -qE '^duplicate.*judge: j.*- +- \(multiple report files\)$' <<< "$OUT"
check grep -qF 'Observed est. tokens per credited blocking hit: - (no eligible report rows).' <<< "$OUT"

# Exercise the real grader: front summary must reuse the existing arithmetic,
# preserve title/matrix/footer, and exclude CLEAN/failed-run spend.
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.name Test
git -C "$TMP/repo" config user.email test@example.invalid
printf 'fixture\n' > "$TMP/repo/app.txt"
git -C "$TMP/repo" add -- app.txt
git -C "$TMP/repo" commit -qm fixture
SHA=$(git -C "$TMP/repo" rev-parse HEAD)
SL=$(slug candidate)
REPORT="$CADRE_HOME/report-$SL-by-$(slug j1,j2).md"
fixture() {
  rm -rf "$CADRE_HOME"
  mkdir -p "$CADRE_HOME/p1"
  printf 'p1|%s|%s|%s|key.md\n' "$SHA" "$TMP/repo" "$SHA" > "$CADRE_HOME/passes.conf"
  cat > "$CADRE_HOME/key.md" <<'EOF'
#### K1 blocking - the changed operation drops an important write
details
#### K2 blocking - the authentication response exposes a private token
details
EOF
  printf 'blocking: dropped write and token leak\nVerdict: blocking\n' > "$CADRE_HOME/p1/$SL-run1.md"
  printf 'review the diff\n' > "$CADRE_HOME/p1/prompt.txt"
}
grade_one() {
  if key_is_clean "$1"; then printf '%s\n' '{"items":{},"extras":[]}' > "$3"
  elif [ "${MISSES:-}" = 1 ]; then printf '%s\n' '{"items":{"K1":"MISS","K2":"MISS"},"extras":[]}' > "$3"
  elif [ "${SPLIT:-}" = 1 ] && [ "$CADRE_JUDGE" = j2 ]; then
    printf '%s\n' '{"items":{"K1":"HIT","K2":"MISS"},"quotes":{"K1":"dropped write"},"extras":[]}' > "$3"
  else printf '%s\n' '{"items":{"K1":"HIT","K2":"HIT"},"quotes":{"K1":"dropped write","K2":"token leak"},"extras":[]}' > "$3"; fi
}
grade() { RC=0; run_gauntlet candidate "${1:-1}" 1 > "$TMP/output" 2>&1 || RC=$?; }
has() { check grep -qF -- "$1" "$REPORT"; }
fixture
bytes=$(wc -c < "$CADRE_HOME/p1/prompt.txt")
bytes=$((bytes + $(wc -c < "$CADRE_HOME/p1/$SL-run1.md")))
expected=$((bytes / 4 / 2))
grade
check test "$RC" -eq 0
check test "$(head -n 1 "$REPORT")" = '# Gauntlet: `candidate`'
has "- est. tokens per credited blocking hit: **$expected**"
has "- est. tokens per blocking item hit: **$expected**"
has '- blocking hit rate: **100.0% (2 / 2)**'
has 'run 1: K1=HIT K2=HIT'
check test "$(grep -n '^## Cost and hits' "$REPORT" | cut -d: -f1)" -lt "$(grep -n '^## p1$' "$REPORT" | cut -d: -f1)"
mkdir -p "$CADRE_HOME/clean"
printf '## CLEAN - no planted defects\n' > "$CADRE_HOME/clean.md"
printf 'clean|%s|%s|%s|clean.md\n' "$SHA" "$TMP/repo" "$SHA" >> "$CADRE_HOME/passes.conf"
printf 'Verdict: ship it\n' > "$CADRE_HOME/clean/$SL-run1.md"
head -c 10000 /dev/zero | tr '\0' x > "$CADRE_HOME/clean/prompt.txt"
: > "$CADRE_HOME/p1/$SL-run2.md.failed"
grade 2
has "- est. tokens per credited blocking hit: **$expected**"
has '| delivery-inclusive | 2 / 4 | 2 / 4 |'
has 'False-positive probes'
rm "$CADRE_HOME/p1/prompt.txt"
grade
has '- est. tokens per credited blocking hit: **-**'
has '- blocking hit rate: **100.0% (2 / 2)**'
fixture
MISSES=1 grade
has '- est. tokens per credited blocking hit: **-**'
has '- blocking hit rate: **0.0% (0 / 2)**'
# A registered pass with no artifact makes even a zero-hit result partial.
printf 'missing|%s|%s|%s|key.md\n' "$SHA" "$TMP/repo" "$SHA" >> "$CADRE_HOME/passes.conf"
MISSES=1 grade
# One round: a rate-derived DO NOT SLOT falls to the round floor (#23).
has '## Verdict: ONE ROUND, not slottable'
has '- est. tokens per credited blocking hit: **-** (partial denominator)'
has '- blocking hit rate: **0.0% (0 / 2)** (partial denominator)'
fixture
SPLIT=1 grade
has '- blocking hit rate: **50.0% to 100.0% (1 to 2 / 2; UNRESOLVED)**'
fixture
cp "$CADRE_HOME/key.md" "$CADRE_HOME/p1/$SL-run2.md"
grade 2
has '## Verdict: INVALID, answer-key leak suspected'
has '- est. tokens per credited blocking hit: **-**'
has '- blocking hit rate: **-**'
fixture
rm "$CADRE_HOME/p1/$SL-run1.md"
: > "$CADRE_HOME/p1/$SL-run1.md.failed"
grade
check test "$RC" -eq 7
has '- est. tokens per credited blocking hit: **-**'
has '- blocking hit rate: **-**'

# ---- #39: noise floor and caps are read before the table -------------------
# Own fixtures: the block above left a real graded report in $CADRE_HOME.
rm -rf "$CADRE_HOME"; mkdir -p "$CADRE_HOME"
report report-a-by-j1.md alpha '1 / 2' 40
report report-b-by-j1.md beta '2 / 2' 80
report report-c-by-j1.md gamma '3 / 4' 20
# Nothing here ran a pass twice, so the floor is NOT MEASURED and says so.
OUT=$("$ROOT/bin/cadre" panel)
check grep -qF 'Noise floor: NOT MEASURED. No report ran a pass more than once' <<< "$OUT"
check test "$(grep -n '^Noise floor' <<< "$OUT" | cut -d: -f1)" -lt "$(grep -n '^Graded-only cost' <<< "$OUT" | cut -d: -f1)"
check test "$(grep -c 'Output caps differ' <<< "$OUT")" -eq 0
check test "$(grep -c 'Within the noise floor' <<< "$OUT")" -eq 0

# One row measured a spread: it becomes the floor. Rows whose rate sits within
# it of the top rate are NAMED, not ranked; rows that never measured one are
# listed as unmeasured rather than treated as having no noise.
spread() { printf -- '- run-to-run spread (blocking hit rate): **%s** (run 1: 1/2, run 2: 0/2); a difference between two seats smaller than this is noise\n' "$1" >> "$CADRE_HOME/$2"; }
# A duplicate of the field, bold or not, makes it ambiguous rather than the
# first one authoritative.
spread 60.0pp report-a-by-j1.md
grade_report_metrics "$CADRE_HOME/report-a-by-j1.md"
check test "$METRIC_SPREAD" = 60.0
OUT=$("$ROOT/bin/cadre" panel)
check grep -qF 'Noise floor: 60.0pp, the largest run-to-run spread one row showed against' <<< "$OUT"
check grep -qF 'itself (alpha  (judge: j1)).' <<< "$OUT"
check grep -qE '^Spread not measured \(one run per pass\): .*beta' <<< "$OUT"
check grep -qF 'Within the noise floor of the top rate (100.0%): alpha  (judge: j1), beta  (judge: j1), gamma  (judge: j1)' <<< "$OUT"
# The largest measured spread wins, not the first or last one read.
spread 10.0pp report-c-by-j1.md
OUT=$("$ROOT/bin/cadre" panel)
check grep -qF 'Noise floor: 60.0pp' <<< "$OUT"
# As the floor drops, seats stop being indistinguishable one at a time.
# alpha is 50%, gamma 75%, beta 100%: at 30pp only gamma still ties the top.
sed -i 's/[*][*]60\.0pp[*][*]/**30.0pp**/' "$CADRE_HOME/report-a-by-j1.md"
OUT=$("$ROOT/bin/cadre" panel)
check grep -qF 'Within the noise floor of the top rate (100.0%): beta  (judge: j1), gamma  (judge: j1)' <<< "$OUT"
sed -i 's/[*][*]30\.0pp[*][*]/**20.0pp**/' "$CADRE_HOME/report-a-by-j1.md"
OUT=$("$ROOT/bin/cadre" panel)
check grep -qF 'Within the noise floor of the top rate (100.0%): beta  (judge: j1)' <<< "$OUT"
check test "$(grep -c 'Within the noise floor of the top rate (100.0%): .*gamma' <<< "$OUT")" -eq 0
# ★ A row whose rate is a RANGE is not placed against an exact one. Placing it
# by its low bound called an exact row "top" while a row that may in fact be
# the highest sat below it.
report report-d-by-j1.md delta '1 to 2 / 2' 30
sed -i 's|1 to 2 / 2\*\*$|1 to 2 / 2** (1 UNRESOLVED)|' "$CADRE_HOME/report-d-by-j1.md"
grade_report_metrics "$CADRE_HOME/report-d-by-j1.md"
check test "$METRIC_RATE" = '50.0% to 100.0% (1 to 2 / 2; UNRESOLVED)'
OUT=$("$ROOT/bin/cadre" panel)
check grep -qF 'Not placed, their rate is an UNRESOLVED range rather than a rate: delta' <<< "$OUT"
check test "$(grep -c 'Within the noise floor of the top rate (100.0%): .*delta' <<< "$OUT")" -eq 0
check grep -qF 'Within the noise floor of the top rate (100.0%): beta  (judge: j1)' <<< "$OUT"
# Every row split means nothing is ranked at all, and the fix is named.
rm -f "$CADRE_HOME/report-a-by-j1.md" "$CADRE_HOME/report-b-by-j1.md" "$CADRE_HOME/report-c-by-j1.md"
report report-e-by-j1.md epsilon '0 to 1 / 2' 10
sed -i 's|0 to 1 / 2\*\*$|0 to 1 / 2** (1 UNRESOLVED)|' "$CADRE_HOME/report-e-by-j1.md"
spread 20.0pp report-e-by-j1.md
OUT=$("$ROOT/bin/cadre" panel)
check grep -qF 'Every row carries a split, so nothing here is ranked. Tighten the key and re-grade.' <<< "$OUT"
check test "$(grep -c 'Within the noise floor of the top rate' <<< "$OUT")" -eq 0
rm -f "$CADRE_HOME/report-d-by-j1.md" "$CADRE_HOME/report-e-by-j1.md"
report report-a-by-j1.md alpha '1 / 2' 40
report report-b-by-j1.md beta '2 / 2' 80
report report-c-by-j1.md gamma '3 / 4' 20
spread 20.0pp report-a-by-j1.md

# A footer that states the line twice is not a measurement.
spread 20.0pp report-a-by-j1.md
grade_report_metrics "$CADRE_HOME/report-a-by-j1.md"
check test "$METRIC_SPREAD" = -
sed -i '$d' "$CADRE_HOME/report-a-by-j1.md"

# Caps: rows under different caps refuse the bounds line and name the fix.
cap() { printf -- '- output cap: **%s tokens** (declared by the adapter on every scored run)\n' "$1" >> "$CADRE_HOME/$2"; }
cap 2048 report-a-by-j1.md
cap 4096 report-b-by-j1.md
printf -- '- output cap: **mixed** (2048, 4096); the scored runs were not cap-matched, so their rates are not one measurement\n' >> "$CADRE_HOME/report-c-by-j1.md"
grade_report_metrics "$CADRE_HOME/report-a-by-j1.md"
check test "$METRIC_CAP" = 2048
grade_report_metrics "$CADRE_HOME/report-c-by-j1.md"
check test "$METRIC_CAP" = mixed
OUT=$("$ROOT/bin/cadre" panel)
check grep -qF 'Output caps differ across rows:' <<< "$OUT"
check grep -qE '^  alpha  \(judge: j1\): 2048 tokens$' <<< "$OUT"
check grep -qE '^  beta  \(judge: j1\): 4096 tokens$' <<< "$OUT"
check grep -qF 'Observed blocking hit-rate bounds: - (rows are not cap-matched).' <<< "$OUT"
check grep -qF 'Ran under more than one cap within one report, so not one measurement: gamma' <<< "$OUT"
# A refused comparison must not still name a winner within the floor.
check test "$(grep -c 'Within the noise floor' <<< "$OUT")" -eq 0
# Cost bounds are a per-row receipt, not a comparison, so they survive.
check grep -qF 'Observed est. tokens per credited blocking hit: 20 to 80 (3 report rows).' <<< "$OUT"
# ★ Matching the two single-cap rows is NOT enough while a third row ran under
# two caps itself. Naming that row in a warning and then ranking it anyway was
# the gap: the warning is not the refusal, and a reader takes the number.
sed -i 's/[*][*]4096 tokens[*][*]/**2048 tokens**/' "$CADRE_HOME/report-b-by-j1.md"
OUT=$("$ROOT/bin/cadre" panel)
# The two single-cap rows now agree, so the cross-row sentence is FALSE and is
# not printed -- but the internally-mixed row still refuses on its own.
check test "$(grep -c 'Output caps differ' <<< "$OUT")" -eq 0
check grep -qF 'Ran under more than one cap within one report, so not one measurement: gamma' <<< "$OUT"
check grep -qF 'That row alone refuses the comparison; re-run it under one cap.' <<< "$OUT"
check grep -qF 'Observed blocking hit-rate bounds: - (rows are not cap-matched).' <<< "$OUT"
check test "$(grep -c 'Within the noise floor' <<< "$OUT")" -eq 0
# With every row on one cap, the comparison returns.
sed -i 's/^- output cap: [*][*]mixed[*][*].*$/- output cap: **2048 tokens** (declared by the adapter on every scored run)/' "$CADRE_HOME/report-c-by-j1.md"
OUT=$("$ROOT/bin/cadre" panel)
check grep -qF 'Observed blocking hit-rate bounds: 50.0% to 100.0% (3 report rows).' <<< "$OUT"
check grep -qF 'Within the noise floor of the top rate (100.0%): beta  (judge: j1)' <<< "$OUT"

# ★ Finding 6: operator prose around a field is not the field. The whole line
# has to be the sentence cadre wrote, and a second mention of the field makes
# it ambiguous whether or not that second one is bold.
prose() { printf -- '%s\n' "$2" >> "$CADRE_HOME/$1"; }
report report-prose-by-j1.md prose '1 / 2' 40
prose report-prose-by-j1.md '- output cap: **2048 tokens** was the old setting; current cap not recorded'
prose report-prose-by-j1.md '- run-to-run spread (blocking hit rate): **99.0pp** is an example, not measured'
grade_report_metrics "$CADRE_HOME/report-prose-by-j1.md"
check test "$METRIC_CAP" = -
check test "$METRIC_SPREAD" = -
report report-prose-by-j1.md prose '1 / 2' 40
printf -- '- output cap: **2048 tokens** (declared by the adapter on every scored run)\n' >> "$CADRE_HOME/report-prose-by-j1.md"
grade_report_metrics "$CADRE_HOME/report-prose-by-j1.md"
check test "$METRIC_CAP" = 2048
# A second mention WITHOUT bold still makes it ambiguous.
prose report-prose-by-j1.md '- output cap: not recorded after all'
grade_report_metrics "$CADRE_HOME/report-prose-by-j1.md"
check test "$METRIC_CAP" = -
rm -f "$CADRE_HOME/report-prose-by-j1.md"

# ---- #23: a rate is shown with its round count, and one round is not placed --
rm -f "$CADRE_HOME"/report-*.md
report report-a-by-j1.md alpha '1 / 2' 40
report report-b-by-j1.md beta '2 / 2' 80 'SEAT: can review alone' 1
report report-c-by-j1.md gamma '3 / 4' 20
spread 60.0pp report-a-by-j1.md
grade_report_metrics "$CADRE_HOME/report-a-by-j1.md"
check test "$METRIC_ROUNDS" = 2
grade_report_metrics "$CADRE_HOME/report-b-by-j1.md"
check test "$METRIC_ROUNDS" = 1
OUT=$("$ROOT/bin/cadre" panel)
check grep -qE '^CANDIDATE +EST.TOKENS/HIT +ROUNDS +BLOCKING HIT RATE$' <<< "$OUT"
check grep -qE '^beta  \(judge: j1\) +80 +1 +100\.0% \(2 / 2\)$' <<< "$OUT"
# beta has the top rate off one round: it is not the top, it is not placed.
check grep -qF 'Within the noise floor of the top rate (75.0%): alpha  (judge: j1), gamma  (judge: j1)' <<< "$OUT"
check grep -qF 'Not placed, under 2 rounds per pass (or none recorded) behind their rate: beta  (judge: j1)' <<< "$OUT"
# Mutation: a second round places it again, as the top.
report report-b-by-j1.md beta '2 / 2' 80 'SEAT: can review alone' 2
OUT=$("$ROOT/bin/cadre" panel)
check grep -qF 'Within the noise floor of the top rate (100.0%): alpha  (judge: j1), beta  (judge: j1), gamma  (judge: j1)' <<< "$OUT"
check test "$(grep -c 'Not placed, under 2 rounds' <<< "$OUT")" -eq 0
# A report that predates the line has an UNKNOWN count, which is not enough.
sed -i '/^- rounds per pass/d' "$CADRE_HOME/report-c-by-j1.md"
grade_report_metrics "$CADRE_HOME/report-c-by-j1.md"
check test "$METRIC_ROUNDS" = -
OUT=$("$ROOT/bin/cadre" panel)
check grep -qE '^gamma  \(judge: j1\) +20 +- +75\.0% \(3 / 4\)$' <<< "$OUT"
check grep -qF 'Not placed, under 2 rounds per pass (or none recorded) behind their rate: gamma  (judge: j1)' <<< "$OUT"
# Every row under the floor: nothing is ranked, and the fix is named.
report report-a-by-j1.md alpha '1 / 2' 40 '' 1
spread 60.0pp report-a-by-j1.md
report report-b-by-j1.md beta '2 / 2' 80 '' 1
OUT=$("$ROOT/bin/cadre" panel)
check test "$(grep -c 'Within the noise floor of the top rate' <<< "$OUT")" -eq 0
check grep -qF 'Nothing here is ranked: no row has an exact rate over 2 or more rounds per pass.' <<< "$OUT"
# Operator prose and duplicates are not a count, the same rule as every field.
report report-a-by-j1.md alpha '1 / 2' 40
printf -- '- rounds per pass behind the blocking hit rate: **9** was the plan\n' >> "$CADRE_HOME/report-a-by-j1.md"
grade_report_metrics "$CADRE_HOME/report-a-by-j1.md"
check test "$METRIC_ROUNDS" = -
report report-a-by-j1.md alpha '1 / 2' 40
sed -i 's/^- rounds per pass behind the blocking hit rate: [*][*]2[*][*].*$/- rounds per pass behind the blocking hit rate: **2** (the fewest scored runs any pass had) as of last week/' "$CADRE_HOME/report-a-by-j1.md"
grade_report_metrics "$CADRE_HOME/report-a-by-j1.md"
check test "$METRIC_ROUNDS" = -
rm -f "$CADRE_HOME"/report-*.md

printf '%s passed; %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
