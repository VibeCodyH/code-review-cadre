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
report() { # <file> <spec> <hits> <cost> [verdict]
  cat > "$CADRE_HOME/$1" <<EOF
# Gauntlet: \`$2\`

## p1
- run 1: K1=HIT K2=MISS K3=MISS
## Verdict: ${5:-SEAT: needs a second reader}
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
check grep -qE '^alpha.*judge: j1.*40 +50\.0% \(1 / 2\)$' <<< "$OUT"
check grep -qE '^alpha.*judge: j2.*80 +25\.0% to 50\.0%.*UNRESOLVED' <<< "$OUT"
check grep -qE '^old +- +-$' <<< "$OUT"
check grep -qE '^clean +- +-$' <<< "$OUT"
check grep -qE '^nohits +- +0\.0% \(0 / 2\)$' <<< "$OUT"
check grep -qE '^missing-receipt +- +100\.0% \(2 / 2\)$' <<< "$OUT"
check grep -qE '^unusable +- +-$' <<< "$OUT"
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
check grep -qE '^alpha.*judge: j1.*10 +50\.0%.*partial denominator' <<< "$OUT"

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
check grep -qE '^partial-zero +- +0\.0%.*partial denominator' <<< "$OUT"
check grep -qE '^partial-unresolved +- +0\.0% to 50\.0%.*partial denominator' <<< "$OUT"

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
has '## Verdict: DO NOT SLOT'
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

printf '%s passed; %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
