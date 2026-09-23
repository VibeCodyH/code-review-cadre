#!/usr/bin/env bash
# The panel's wall clock against the parts that have their own timers (#10):
# the residual is recorded, reconciles exactly, and a negative one is reported
# as double counting (--jobs 1) or overlap (--jobs N), never clamped to zero.
# Stub adapters only; no model is called.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export CADRE_ROOT="$ROOT" CADRE_HOME="$SANDBOX/state" CADRE_WORK="$SANDBOX/work"
export CADRE_AGENTS_D="$SANDBOX/agents.d"
mkdir -p "$HOME" "$CADRE_AGENTS_D" "$SANDBOX/bin"
. "$ROOT/lib/common.sh"
PASS=0 FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  FAIL $1"; fi; }

printf 'bin_pireview() { echo cadre-accounting-pireview-not-installed; }\n' > "$CADRE_AGENTS_D/pireview.sh"
for n in quick nap nap2 nap3; do printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/$n"; chmod +x "$SANDBOX/bin/$n"; done
cat > "$CADRE_AGENTS_D/quick.sh" <<'A'
run_quick() { echo "- should-fix: the fixture line is not covered"; echo "Verdict: should-fix"; }
A
# Sleeps, so seat seconds are nonzero and three of them under --jobs 3 overlap
# by far more than the harness spends around them.
cat > "$CADRE_AGENTS_D/nap.sh" <<'A'
run_nap() { sleep 3; echo "- nit: the fixture sleeps"; echo "Verdict: ship it"; }
A
for n in nap2 nap3; do sed "s/nap/$n/g" "$CADRE_AGENTS_D/nap.sh" > "$CADRE_AGENTS_D/$n.sh"; done

REPO="$SANDBOX/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.name Fixture
git -C "$REPO" config user.email fixture@example.invalid
echo base > "$REPO/app.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm base
echo change >> "$REPO/app.txt"; git -C "$REPO" commit -qam change

review() {  # <label> <args...>
  local label="$1"; shift
  "$ROOT/bin/cadre" review --base HEAD~1 --synth none --label "$label" "$@" "$REPO" \
    > "$SANDBOX/$label.out" 2> "$SANDBOX/$label.err"
}
panel() { record_rows "$CADRE_HOME/reviews/$1/runs.jsonl" panel "${@:2}"; }
field() { panel "$1" "$2"; }

echo "== one seat at a time =="
review seq --roster quick,nap,ghost
R="$CADRE_HOME/reviews/seq"
check "exactly one panel event"          "[ \$(grep -c '\"event\":\"panel\"' '$R/runs.jsonl') -eq 1 ]"
check "and it is the last record"        "tail -1 '$R/runs.jsonl' | grep -q '\"event\":\"panel\"'"
check "jobs is recorded"                 "[ \"\$(field seq jobs)\" = 1 ]"
check "wall clock is measured"           "[[ \"\$(field seq wall_secs)\" =~ ^[0-9]+\$ ]] && [ \"\$(field seq wall_secs)\" -ge 2 ]"
SEATSUM=$(record_rows "$R/runs.jsonl" complete secs | awk '$1 != "" { s += $1 } END { print s + 0 }')
check "seat_secs is the sum of seat timers" "[ \"\$(field seq seat_secs)\" = '$SEATSUM' ]"
check "no pre-pass is null, not zero"   "grep -q '\"prerun_secs\":null' '$R/runs.jsonl'"
check "totals reconcile exactly" \
  "[ \$(( \$(field seq wall_secs) - \$(field seq seat_secs) )) -eq \"\$(field seq unattributed_secs)\" ]"
check "sequential residual is not negative" "[ \"\$(field seq unattributed_secs)\" -ge 0 ]"
check "the uninstalled seat is untimed" "[ \"\$(field seq timed_seats)\" = 2 ] && [ \"\$(field seq untimed_seats)\" = 1 ]"
check "token residual is unmeasured"    "grep -q '\"unattributed_tokens\":null' '$R/runs.jsonl'"
EST=$(sed -n 's/^| \*\*panel total\*\* |.* | \([0-9]*\) |$/\1/p' "$R/report.md")
check "est_tokens matches the Receipts total" "[ -n '$EST' ] && [ \"\$(field seq est_tokens)\" = '$EST' ]"
check "report states the residual"      "grep -qF \"**Unattributed: \$(field seq unattributed_secs)s**\" '$R/report.md'"
check "report names the untimed seat"   "grep -q '1 seat(s) were never timed' '$R/report.md'"
check "report names what is not timed"  "grep -q 'Not timed: this table' '$R/report.md'"
check "no double-count warning"         "! grep -q 'counted twice' '$R/report.md' '$SANDBOX/seq.err'"
# Readers of the record are untouched: a new event name, and slots.tsv keeps
# its twelve columns.
check "slots.tsv shape is unchanged"    "awk -F '\t' 'NF != 12 { exit 1 }' '$R/slots.tsv'"
# Captured, not piped into grep -q: under pipefail an early-exiting grep hands
# back the writer's SIGPIPE as the status.
RECEIPTS=$("$ROOT/bin/cadre" receipts "$CADRE_HOME/reviews" 2>&1)
SEATS=$("$ROOT/bin/cadre" seats "$CADRE_HOME/reviews" 2>&1)
check "receipts still reads the panel"  "grep -q '^quick ' <<<\"\$RECEIPTS\""
check "seats still reads the panel"     "grep -q '^quick ' <<<\"\$SEATS\""
check "evidence export keeps the record" \
  "'$ROOT/bin/cadre' export-evidence '$R' '$SANDBOX/evidence' >/dev/null && cmp -s '$SANDBOX/evidence/shared/panel.jsonl' <(tail -1 '$R/runs.jsonl')"

echo "== a pre-pass is its own attributed part =="
review pre --roster quick --prerun 'sleep 1'
check "prerun is timed"                 "[ \"\$(field pre prerun_secs)\" -ge 1 ]"
check "and reconciles with the seats" \
  "[ \$(( \$(field pre wall_secs) - \$(field pre prerun_secs) - \$(field pre seat_secs) )) -eq \"\$(field pre unattributed_secs)\" ]"
check "report names the pre-pass part"  "grep -q 's in the pre-pass' '$CADRE_HOME/reviews/pre/report.md'"

echo "== seats in parallel overlap =="
review par --roster nap,nap2,nap3 --jobs 3
check "jobs 3 is recorded"              "[ \"\$(field par jobs)\" = 3 ]"
check "seat seconds pass the wall clock" "[ \"\$(field par seat_secs)\" -gt \"\$(field par wall_secs)\" ]"
check "so the residual is negative, and kept" "[ \"\$(field par unattributed_secs)\" -lt 0 ]"
check "report calls it overlap"         "grep -q 'a negative figure is that overlap' '$CADRE_HOME/reviews/par/report.md'"
check "not double counting"             "! grep -q 'counted twice' '$CADRE_HOME/reviews/par/report.md' '$SANDBOX/par.err'"

echo "== a clock that runs backwards is reported, not clamped =="
# The first `date` run-review.sh makes is the panel's start. Skewing only that
# one reads to the harness exactly like a second counted twice: the timers sum
# past the wall clock with seats run one at a time.
REAL_DATE=$(command -v date)
mkdir -p "$SANDBOX/skew"
cat > "$SANDBOX/skew/date" <<A
#!/bin/sh
if [ ! -e "$SANDBOX/skew/used" ]; then : > "$SANDBOX/skew/used"; echo \$(( \$($REAL_DATE +%s) + 1000 )); exit 0; fi
exec $REAL_DATE "\$@"
A
chmod +x "$SANDBOX/skew/date"
mkdir -p "$SANDBOX/out-skew"
PATH="$SANDBOX/skew:$PATH" "$ROOT/lib/run-review.sh" "$REPO" HEAD~1 "$SANDBOX/out-skew" 1 quick \
  > "$SANDBOX/skew.out" 2> "$SANDBOX/skew.err"
SK=$(record_rows "$SANDBOX/out-skew/runs.jsonl" panel wall_secs unattributed_secs)
check "the skewed start was the panel's"  "[ \"\$(cut -f1 <<<'$SK')\" -lt 0 ]"
check "negative residual is recorded"     "[ \"\$(cut -f2 <<<'$SK')\" -lt 0 ]"
check "report flags double counting"      "grep -q 'counted twice' '$SANDBOX/out-skew/report.md'"
check "and so does stderr"                "grep -q 'counted twice' '$SANDBOX/skew.err'"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
