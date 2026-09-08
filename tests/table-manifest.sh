#!/usr/bin/env bash
# Offline table selection/provenance fixtures; no installed provider is called.
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
fixture() {
  rm -rf "$CADRE_HOME" "$TMP/before"
  mkdir -p "$CADRE_HOME/p1"
  printf 'p1|%s|%s|%s|key.md\n' "$SHA" "$TMP/repo" "$SHA" > "$CADRE_HOME/passes.conf"
  printf '#### K1 blocking - the changed operation drops an important pending write\ndetails\n' > "$CADRE_HOME/key.md"
  : > "$TMP/judge-calls"
  : > "$TMP/reviewer-calls"
  unset OUTAGE DRIFT_KEY
}
runfile() { printf '%s/p1/%s-run%s.md' "$CADRE_HOME" "$SL" "$1"; }
review() {
  if [ "$2" = HIT ]; then printf 'The operation drops its pending write.\nVerdict: blocking\n' > "$(runfile "$1")"
  else printf 'No defects found.\nVerdict: ship it\n' > "$(runfile "$1")"; fi
}
marker() { jq -n --arg reason "$2" '{reason:$reason}' > "$(runfile "$1").invalid.json"; }
grade_one() {
  printf '%s %s\n' "$CADRE_JUDGE" "$2" >> "$TMP/judge-calls"
  [ "${DRIFT_KEY:-}" != 1 ] || printf 'correction during grading\n' >> "$1"
  if [ "${OUTAGE:-}" = "$CADRE_JUDGE" ]; then
    printf '%s\n' "$UNUSABLE" > "$3"
    printf 'judge fixture outage\n' > "$3.judge-raw"
  elif grep -q 'drops its pending write' "$2"; then
    printf '%s\n' '{"items":{"K1":"HIT"},"quotes":{"K1":"The operation drops its pending write."},"extras":[]}' > "$3"
  else printf '%s\n' '{"items":{"K1":"MISS"},"extras":[]}' > "$3"; fi
}
grade() { # [runs] [selection] [freeze] [scope] [rescore]
  local table_selection="${2:-all-runs}" table_freeze="${3:-0}" scope="${4:-}"
  REPORT="$CADRE_HOME/report-$SL-by-$(slug "$CADRE_JUDGE")"
  [ -z "$scope" ] || REPORT="$REPORT-only-$(slug "$scope")"
  TABLE="$REPORT.table" MANIFEST="$REPORT.table/manifest.json" RESULTS="$REPORT.table/results.json"
  REPORT="$REPORT.md"
  RC=0
  run_gauntlet candidate "${1:-3}" "${5:-1}" "$scope" > "$TMP/output" 2>&1 || RC=$?
}
has() { check grep -qF -- "$1" "$REPORT"; }
json_matches() { jq -e "$1" "$2" > /dev/null; }
jmanifest() { check json_matches "$1" "$MANIFEST"; }
jresults() { check json_matches "$1" "$RESULTS"; }
filehash() { sha256sum < "$1" | cut -d' ' -f1; }
snapshot_state() { cp -a "$CADRE_HOME" "$TMP/before"; }
unchanged_state() { check diff -r --exclude='.gauntlet-*' "$TMP/before" "$CADRE_HOME"; }
verify_snapshots() {
  local path hash source
  while IFS=$'\t' read -r path hash; do
    check test -f "$TABLE/$path"
    check test "$(filehash "$TABLE/$path")" = "$hash"
    source="$CADRE_HOME/p1/$(basename "$path")"
    check cmp "$source" "$TABLE/$path"
  done < <(jq -r '.runs[].grades[] | ., (.judge_raw // empty) | [.file,.sha256] | @tsv' "$RESULTS")
  check test "$(filehash "$RESULTS")" = "$(jq -r .results_sha256 "$MANIFEST")"
  check test "$(filehash "$TABLE/report.md")" = "$(jq -r .report_sha256 "$MANIFEST")"
  check cmp "$REPORT" "$TABLE/report.md"
}

# The same numbered reviews produce different, explicit denominators.
fixture
review 1 MISS; review 2 HIT; review 3 HIT
grade
check test "$RC" -eq 0
has '| graded-only | 2 / 3 | 2 / 3 |'
has 'Selection: `all-runs`.'
jmanifest '.schema == 1 and .status == "open" and .selection == "all-runs" and .requested_runs == 3 and .scope == null and .candidate == "candidate" and .judges == ["j1","j2"] and .excluded == []'
jmanifest ".passes == [{label:\"p1\",target_sha:\"$SHA\",key_sha256:\"$(filehash "$CADRE_HOME/key.md")\"}]"
jmanifest '.results == "results.json" and .report == "report.md"'
jresults '.schema == 1 and .candidate == "candidate" and .selection == "all-runs" and (.runs | length) == 3'
jresults '[.runs[].run] == [1,2,3] and [.runs[].items.K1] == ["MISS","HIT","HIT"]'
jresults "all(.runs[]; .run_id == (\"p1/$SL-run\" + (.run|tostring)) and .status == \"graded\" and (.grades|length) == 2)"
jresults '.summary.scored == true and .summary.graded_only.blocking == {hit_low:2,hit_high:2,total:3,unresolved:0} and .summary.delivery_inclusive == .summary.graded_only'
verify_snapshots
check test "$(wc -l < "$TMP/judge-calls")" -eq 6

: > "$TMP/judge-calls"
grade 3 first-run
check test "$RC" -eq 0
has '| graded-only | 0 / 1 | 0 / 1 |'
has 'Selection: `first-run`. Excluded: **2** entries.'
jmanifest '.selection == "first-run" and .requested_runs == 3 and [.excluded[].run] == [2,3] and all(.excluded[]; .kind == "selection" and (.reason|length) > 0)'
jresults '(.runs|length) == 1 and .runs[0].run == 1 and .runs[0].items.K1 == "MISS"'
jresults '.summary.graded_only.blocking == {hit_low:0,hit_high:0,total:1,unresolved:0}'
verify_snapshots
check test "$(wc -l < "$TMP/judge-calls")" -eq 2

# Open tables acquire the hash of the corrected key; never retain the old pin.
OLD_KEY=$(jq -r '.passes[0].key_sha256' "$MANIFEST")
printf 'operator correction\n' >> "$CADRE_HOME/key.md"
grade 3 first-run
check test "$RC" -eq 0
check test "$(jq -r '.passes[0].key_sha256' "$MANIFEST")" != "$OLD_KEY"
check test "$(jq -r '.passes[0].key_sha256' "$MANIFEST")" = "$(filehash "$CADRE_HOME/key.md")"

# A key edited during a judge call cannot publish grades under the starting
# key hash. The previously published report and table survive this failed pass.
cp "$REPORT" "$TMP/prior-report.md"
cp -a "$TABLE" "$TMP/prior-table"
DRIFT_KEY=1 grade 3 first-run
check test "$RC" -ne 0
check grep -qi key "$TMP/output"
check cmp "$TMP/prior-report.md" "$REPORT"
check diff -r "$TMP/prior-table" "$TABLE"

# Freeze preserves the whole published table and source grades before any judge
# or reviewer dispatch, even if a caller requests a different selection.
grade 3 first-run 1
check test "$RC" -eq 0
jmanifest '.status == "frozen"'
snapshot_state
CALLS=$(wc -l < "$TMP/judge-calls")
for selection in first-run all-runs; do
  grade 3 "$selection"
  check test "$RC" -ne 0
  check grep -qi frozen "$TMP/output"
  unchanged_state
  check test "$(wc -l < "$TMP/judge-calls")" -eq "$CALLS"
done
mkdir -p "$TMP/fake-root/lib"
printf '#!/usr/bin/env bash\nprintf "called\\n" >> "%s"\nexit 99\n' "$TMP/reviewer-calls" > "$TMP/fake-root/lib/run-pass.sh"
chmod +x "$TMP/fake-root/lib/run-pass.sh"
CADRE_ROOT="$TMP/fake-root" grade 3 all-runs 0 '' 0
check test "$RC" -ne 0
check grep -qi frozen "$TMP/output"
unchanged_state
check test ! -s "$TMP/reviewer-calls"
check test "$(wc -l < "$TMP/judge-calls")" -eq "$CALLS"

# A differently scoped report may rescore shared source grades. A frozen table
# must keep its saved grades even after those shared files change.
FROZEN_TABLE="$TABLE"
cp -a "$FROZEN_TABLE" "$TMP/frozen-table"
review 1 HIT
grade 3 all-runs 0 p1
check test "$RC" -eq 0
jmanifest '.scope == "p1" and .status == "open"'
check diff -r "$TMP/frozen-table" "$FROZEN_TABLE"
check json_matches '.items.K1 == "HIT"' "$CADRE_HOME/p1/$SL-run1.by-$(slug j1).grade.json"
check json_matches '.runs[0].items.K1 == "MISS"' "$FROZEN_TABLE/results.json"

# First means run 1, never the next usable or non-invalid review.
for kind in failed invalid missing; do
  fixture
  review 2 HIT; review 3 HIT
  case "$kind" in
    failed) printf 'unusable provider output\n' > "$(runfile 1).failed" ;;
    invalid) review 1 HIT; marker 1 'Harness corruption once claimed K99=HIT.' ;;
  esac
  grade 3 first-run
  check test "$RC" -ne 0
  jresults '(.runs|length) == 1 and .runs[0].run == 1 and .runs[0].items == {} and .runs[0].grades == []'
  jmanifest '[.excluded[] | select(.kind == "selection") | .run] == [2,3]'
  check test ! -s "$TMP/judge-calls"
  has '| graded-only | - (no eligible items) | - (no eligible items) |'
  case "$kind" in
    failed)
      jresults '.runs[0].status == "failed"'
      jresults '.summary.graded_only == null and .summary.delivery_inclusive.blocking == {hit_low:0,hit_high:0,total:1,unresolved:0}'
      has '| delivery-inclusive | 0 / 1 | 0 / 1 |' ;;
    invalid)
      jresults '.runs[0].status == "operator-invalid"'
      jmanifest 'any(.excluded[]; .kind == "operator-invalid" and .reason == "Harness corruption once claimed K99=HIT.")'
      PANEL=$("$ROOT/bin/cadre" panel)
      check test "$(grep -c 'K99\|pass Selection\|pass Operator-invalid' <<< "$PANEL")" -eq 0 ;;
    missing)
      jresults '.runs[0].status == "missing"'
      jmanifest 'any(.excluded[]; .kind == "missing" and .run == 1)' ;;
  esac
done

# Judge failures remain failures, with each judge's actual available grade saved.
fixture
review 1 HIT
OUTAGE=j2 grade 1
check test "$RC" -eq 5
jresults '(.runs|length) == 1 and .runs[0].status == "grading-failed" and .runs[0].items == {} and (.runs[0].grades|length) == 2'
jmanifest 'any(.excluded[]; .kind == "grading-failed" and .run == 1)'
jresults '.summary == {scored:false,graded_only:null,delivery_inclusive:null}'
verify_snapshots
check json_matches '.unusable == true' "$TABLE/grades/$(slug p1)/$SL-run1.by-$(slug j2).grade.json"
jresults '[.runs[0].grades[] | select(.judge_raw != null)] | length == 1'
RAW_PATH=$(jq -r '.runs[0].grades[] | select(.judge_raw != null) | .judge_raw.file' "$RESULTS")
check test "$(cat "$TABLE/$RAW_PATH")" = 'judge fixture outage'
check test "$(filehash "$TABLE/$RAW_PATH")" = "$(jq -r '.runs[0].grades[] | select(.judge_raw != null) | .judge_raw.sha256' "$RESULTS")"
OUTAGE=j2 grade 1 all-runs 1
check test "$RC" -eq 5
jmanifest '.status == "frozen"'
FROZEN_OUTAGE="$TABLE"
cp -a "$TABLE" "$TMP/frozen-outage"
grade 1 all-runs 0 p1
check test "$RC" -eq 0
check test ! -e "$CADRE_HOME/p1/$SL-run1.by-$(slug j2).grade.json.judge-raw"
check diff -r "$TMP/frozen-outage" "$FROZEN_OUTAGE"
check test "$(cat "$FROZEN_OUTAGE/$RAW_PATH")" = 'judge fixture outage'

# Registration and scope omissions stay explicit, and absent inputs have null
# pins rather than the current working directory's HEAD or a made-up digest.
fixture
review 1 HIT
printf 'no-key|%s|%s|%s|absent.md\n' "$SHA" "$TMP/repo" "$SHA" >> "$CADRE_HOME/passes.conf"
printf 'no-checkout|%s|%s|%s|key.md\n' "$SHA" "$TMP/absent-repo" "$SHA" >> "$CADRE_HOME/passes.conf"
grade 1
check test "$RC" -eq 0
has '(partial denominator)'
jmanifest 'any(.excluded[]; .kind == "missing-key" and .label == "no-key" and .run == null) and any(.excluded[]; .kind == "missing-checkout" and .label == "no-checkout" and .run == null)'
jmanifest '(.passes[] | select(.label == "no-key") | .key_sha256) == null and (.passes[] | select(.label == "no-checkout") | .target_sha) == null'
grade 1 all-runs 0 p1
check test "$RC" -eq 0
jmanifest '.scope == "p1" and ([.excluded[]|select(.kind == "scope")|.label] == ["no-key","no-checkout"])'
jresults '(.runs|length) == 1 and .runs[0].label == "p1"'

# A leak on the selected run still invalidates the table ahead of an operator
# assertion. The assertion cannot turn compromised evidence into a clean table.
fixture
printf '#### K2 blocking - the authentication response exposes a private token\ndetails\n' >> "$CADRE_HOME/key.md"
cp "$CADRE_HOME/key.md" "$(runfile 1)"
marker 1 'Operator requests an exclusion.'
review 2 HIT
grade 2 first-run
check test "$RC" -ne 0
has '## Verdict: INVALID, answer-key leak suspected'
jresults '(.runs|length) == 1 and .runs[0].status == "suspect" and .runs[0].items == {}'
jresults '.summary == {scored:false,graded_only:null,delivery_inclusive:null}'
jmanifest 'any(.excluded[]; .kind == "suspect") and all(.excluded[]; .kind != "operator-invalid")'
check test ! -s "$TMP/judge-calls"

# Broken or incomplete manifests must fail closed before replacing report bytes
# or calling a judge. A directory without its manifest is equally ambiguous.
for bad in broken-json '{}' '{"status":"open"}' missing; do
  fixture
  review 1 HIT
  grade 1
  check test "$RC" -eq 0
  if [ "$bad" = missing ]; then rm "$MANIFEST"
  else printf '%s\n' "$bad" > "$MANIFEST"; fi
  snapshot_state
  CALLS=$(wc -l < "$TMP/judge-calls")
  grade 1
  check test "$RC" -ne 0
  check grep -qi manifest "$TMP/output"
  unchanged_state
  check test "$(wc -l < "$TMP/judge-calls")" -eq "$CALLS"
done

# Invalid CLI selection is diagnosed before installed-judge checks, so a typo
# cannot accidentally invoke the user's real provider from their environment.
fixture
for args in '--selection best-run' '--selection'; do
  RC=0
  # shellcheck disable=SC2086 # intentional fixture argument splitting
  CADRE_JUDGE=definitely-uninstalled "$ROOT/bin/cadre" grade candidate 3 $args > "$TMP/output" 2>&1 || RC=$?
  check test "$RC" -ne 0
  check grep -qi selection "$TMP/output"
  check test "$(grep -c 'not installed\|no judge available' "$TMP/output")" -eq 0
  check test ! -e "$CADRE_HOME/report-$SL-by-$(slug definitely-uninstalled).md"
done

# Exercise successful option parsing through the real CLI with an isolated
# adapter. The adapter is the judge here and only emits a fixed offline grade.
fixture
review 1 MISS; review 2 HIT; review 3 HIT
mkdir -p "$TMP/bin" "$TMP/agents"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/manifestjudge"
chmod +x "$TMP/bin/manifestjudge"
cat > "$TMP/agents/manifestjudge.sh" <<'EOF'
run_manifestjudge() {
  printf '%s\n' '{"items":{"K1":"MISS"},"extras":[]}'
}
EOF
RC=0
CADRE_AGENTS_D="$TMP/agents" CADRE_JUDGE=manifestjudge PATH="$TMP/bin:/usr/bin:/bin" \
  "$ROOT/bin/cadre" grade candidate --freeze 3 p1 --selection first-run > "$TMP/output" 2>&1 || RC=$?
check test "$RC" -eq 0
REPORT="$CADRE_HOME/report-$SL-by-$(slug manifestjudge)-only-$(slug p1).md"
TABLE="${REPORT%.md}.table" MANIFEST="${REPORT%.md}.table/manifest.json" RESULTS="${REPORT%.md}.table/results.json"
jmanifest '.status == "frozen" and .scope == "p1" and .selection == "first-run" and .requested_runs == 3 and .judges == ["manifestjudge"]'
jresults '(.runs|length) == 1 and .runs[0].run == 1 and .runs[0].items.K1 == "MISS"'
verify_snapshots

printf '%s passed; %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
