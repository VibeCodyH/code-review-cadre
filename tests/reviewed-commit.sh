#!/usr/bin/env bash
# The run record names the commit a seat reviewed, and `cadre grade` says so
# when the pass row no longer points at it (#93). Stub adapters only: no model,
# no network. The recorded value is checked against git, not against what the
# harness thinks it wrote.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" TZ=UTC LC_ALL=C.UTF-8
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export CADRE_ROOT="$ROOT" CADRE_HOME="$TMP/state" CADRE_WORK="$TMP/work"
export CADRE_AGENTS_D="$TMP/agents.d" CADRE_RETRY_WAIT=0 CADRE_JUDGE=judge
export CADRE_LOCK_FILE="$TMP/state/fixture.lock.json"
mkdir -p "$HOME" "$CADRE_HOME" "$CADRE_AGENTS_D" "$TMP/bin"
PASS=0 FAIL=0
check() {
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; fi
}
has() { check grep -qF -- "$1" "$2"; }
lacks() { check test "$(grep -cF -- "$1" "$2")" -eq 0; }

for n in candidate judge; do
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$n"; chmod +x "$TMP/bin/$n"
done
cat > "$CADRE_AGENTS_D/candidate.sh" <<'A'
run_candidate() {
  echo "- blocking: FOUND-K1 the retry path drops the write"
  echo "Verdict: blocking"
}
A
cat > "$CADRE_AGENTS_D/judge.sh" <<'A'
run_judge() {
  printf '{"items":{"K1":"HIT"},"quotes":{"K1":"FOUND-K1"},"verdict":"found","extras":[]}\n'
}
A
cat > "$CADRE_HOME/key.md" <<'KEY'
#### K1 blocking - the retry path drops the write
The early return skips write(x).
KEY

# base, then C1 (the tree reviewed), then C2 (a later commit on the same branch).
REPO="$TMP/repo"
git init -q -b main "$REPO"
printf 'let count = 0;\nfunction save(x) { count++; return write(x); }\n' > "$REPO/app.js"
git -C "$REPO" add -A; git -C "$REPO" commit -qm base
git -C "$REPO" checkout -qb feature
printf 'let count = 0;\nfunction save(x) { count++; if (retry) return; return write(x); }\n' > "$REPO/app.js"
git -C "$REPO" commit -qam change
printf 'let count = 0;\nfunction save(x) { count++; if (retry) return false; return write(x); }\n' > "$REPO/app.js"
git -C "$REPO" commit -qam later
BASE=$(git -C "$REPO" rev-parse main)
C1=$(git -C "$REPO" rev-parse feature~1)
C2=$(git -C "$REPO" rev-parse feature)
git clone -q "$REPO" "$TMP/checkout"
git -C "$TMP/checkout" checkout -q "$C1"
row() { printf 'p1|%s|%s|%s|key.md\n' "$1" "$TMP/checkout" "$BASE" > "$CADRE_HOME/passes.conf"; }
RUNLOG="$CADRE_HOME/p1/runs.jsonl"

# The two lines the report adds, so what is left can be compared across grades.
scores_only() { grep -v -e '^Reviewed commit:' -e '^Anchor positions below are checked' "$1"; }

# ---- 1. run: dispatch and complete both name the commit ---------------------
row "$C1"
"$ROOT/bin/cadre" lock --update > /dev/null || { echo "FAIL: cadre lock --update"; exit 1; }
"$ROOT/bin/cadre" run candidate 1 > "$TMP/run.out" 2>&1; RC=$?
check test "$RC" -eq 0
check test "$(jq -r 'select(.event == "dispatch") | .target_sha' "$RUNLOG")" = "$C1"
check test "$(jq -r 'select(.event == "complete") | .target_sha' "$RUNLOG")" = "$C1"
# Full id from git, whichever way the row spelled it.
check test "${#C1}" -ge 40
has "Reviewed commit: \`${C1:0:12}\` on every run record, matches the pass row." "$TMP/run.out"
lacks 'MISMATCH' "$TMP/run.out"
lacks 'Reviewed commit: not recorded' "$TMP/run.out"

# An abbreviated row spelling of the same commit is the same commit.
row "${C1:0:10}"
"$ROOT/bin/cadre" grade candidate 1 > "$TMP/short.out" 2>&1
has "Reviewed commit: \`${C1:0:12}\` on every run record, matches the pass row." "$TMP/short.out"
lacks 'MISMATCH' "$TMP/short.out"

# ---- 2. the row is edited after the run: reported by name -------------------
row "$C2"
"$ROOT/bin/cadre" grade candidate 1 > "$TMP/edited.out" 2>&1; RC=$?
check test "$RC" -eq 0
has 'Reviewed commit: ★ MISMATCH.' "$TMP/edited.out"
has "The run record names \`$C1\` (run 1)" "$TMP/edited.out"
has "the pass row now says \`$C2\`" "$TMP/edited.out"
has "Anchor positions below are checked against the pass row's commit" "$TMP/edited.out"
lacks 'matches the pass row' "$TMP/edited.out"
lacks 'Reviewed commit: not recorded' "$TMP/edited.out"

# ---- 3. restored: back to quiet ---------------------------------------------
row "$C1"
"$ROOT/bin/cadre" grade candidate 1 > "$TMP/restored.out" 2>&1
has "Reviewed commit: \`${C1:0:12}\` on every run record, matches the pass row." "$TMP/restored.out"
lacks 'MISMATCH' "$TMP/restored.out"

# ---- 4. a record from before the field: unverifiable, never either verdict --
# The same record with `target_sha` taken off every event, as an older cadre
# wrote it. Run it against the row that matched AND the row that did not: with
# nothing recorded, neither can be a mismatch and neither can be verified.
sed 's/"target_sha":"[0-9a-f]*",//' "$RUNLOG" > "$TMP/legacy.jsonl"
check test "$(grep -c target_sha "$TMP/legacy.jsonl")" -eq 0
check test "$(wc -l < "$TMP/legacy.jsonl")" -eq "$(wc -l < "$RUNLOG")"
cp "$TMP/legacy.jsonl" "$RUNLOG"
row "$C1"
"$ROOT/bin/cadre" grade candidate 1 > "$TMP/legacy-match.out" 2>&1; RC=$?
check test "$RC" -eq 0
has "Reviewed commit: not recorded (the run record predates the field, or this candidate has none)" "$TMP/legacy-match.out"
has "Pass row: \`${C1:0:12}\`." "$TMP/legacy-match.out"
lacks 'MISMATCH' "$TMP/legacy-match.out"
lacks 'matches the pass row' "$TMP/legacy-match.out"
row "$C2"
"$ROOT/bin/cadre" grade candidate 1 > "$TMP/legacy-edited.out" 2>&1
has 'Reviewed commit: not recorded' "$TMP/legacy-edited.out"
lacks 'MISMATCH' "$TMP/legacy-edited.out"
lacks 'matches the pass row' "$TMP/legacy-edited.out"

# ---- 5. reporting only: nothing else in the report moves --------------------
# Same reviews, same judge, three different commit verdicts. Take the added
# lines out and the reports are the same bytes.
scores_only "$TMP/restored.out" > "$TMP/a.txt"
scores_only "$TMP/edited.out" > "$TMP/b.txt"
scores_only "$TMP/legacy-match.out" > "$TMP/c.txt"
check cmp -s "$TMP/a.txt" "$TMP/b.txt"
check cmp -s "$TMP/a.txt" "$TMP/c.txt"
has 'K1' "$TMP/b.txt"
has 'HIT' "$TMP/b.txt"

# ---- 6. the shapes a pass record can take, read straight --------------------
. "$ROOT/lib/common.sh"
. "$ROOT/lib/grade.sh"
LOG="$TMP/shapes.jsonl"
rec() { # <slug> <run> [target_sha]
  if [ $# -ge 3 ]; then
    record_event "$LOG" event=complete slug="$1" "run#=$2" state=ok target_sha="$3"
  else
    record_event "$LOG" event=complete slug="$1" "run#=$2" state=ok
  fi
}
shape() { reviewed_commit_line "$LOG" cand "$1" "$2"; }

# Two runs recorded two commits: both named, neither picked.
: > "$LOG"; rec cand 1 "$C1"; rec cand 2 "$C2"
OUT=$(shape 2 "$C1")
check grep -qF "★ MISMATCH." <<< "$OUT"
check grep -qF "\`$C1\` (run 1, the row's commit), \`$C2\` (run 2)" <<< "$OUT"
check grep -qF "disagrees with itself: 2 different commits." <<< "$OUT"
# Run 2 is outside a one-run grade, so it is not part of what is being graded.
OUT=$(shape 1 "$C1")
check grep -qF "matches the pass row." <<< "$OUT"
check test "$(grep -cF 'disagrees' <<< "$OUT")" -eq 0

# Another candidate's completions, at another commit, say nothing about this one.
: > "$LOG"; rec cand 1 "$C1"; rec other 1 "$C2"
OUT=$(shape 1 "$C1")
check grep -qF "on every run record, matches the pass row." <<< "$OUT"

# One run recorded, one from before the field: the recorded one is checked, the
# other is named unverifiable. The row's spelling is irrelevant to a missing field.
: > "$LOG"; rec cand 1 "$C1"; rec cand 2
OUT=$(shape 2 "$C1")
check grep -qF "(run 1), matches the pass row. No commit recorded for run 2, so that is unverifiable." <<< "$OUT"
OUT=$(shape 2 "$C2")
check grep -qF "★ MISMATCH." <<< "$OUT"
check grep -qF "No commit recorded for run 2, so that is unverifiable." <<< "$OUT"

# No record at all, and an empty row commit: nothing is compared, nothing crashes.
: > "$LOG"
OUT=$(shape 1 "$C1")
check grep -qF "Reviewed commit: not recorded" <<< "$OUT"
: > "$LOG"; rec cand 1 "$C1"
OUT=$(shape 1 "")
check grep -qF "★ MISMATCH." <<< "$OUT"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
