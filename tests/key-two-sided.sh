#!/usr/bin/env bash
# The two-sided key check (#23): an item is registered only when it cites a
# target line that the reference fix changes. Real Git history, a stub drafting
# agent for make-pass, and no model or network call anywhere.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export CADRE_ROOT="$ROOT" CADRE_HOME="$TMP/state" CADRE_WORK="$TMP/work"
export HOME="$TMP/user" PATH=/usr/bin:/bin CADRE_JUDGE=j1
mkdir -p "$HOME" "$CADRE_HOME"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/grade.sh"
PASS=0 FAIL=0
check() {
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; fi
}

# base -> target (plants line 12) -> an unrelated commit -> fix (repairs line
# 12, appends ten lines, adds a test). The unrelated commit makes fix^ differ
# from the target, so the key's coordinates must come from the target itself.
R="$TMP/repo"
mkdir -p "$R/src" "$R/test"
git -C "$R" init -q
git -C "$R" config user.name Test
git -C "$R" config user.email test@example.invalid
seq -f 'line %g' 1 20 > "$R/src/app.js"
seq -f 'other %g' 1 20 > "$R/src/other.js"
git -C "$R" add -A; git -C "$R" commit -qm base
sed -i '12s/.*/defect/' "$R/src/app.js"
git -C "$R" commit -qam 'feat: target'
TARGET=$(git -C "$R" rev-parse HEAD)
sed -i '2s/.*/unrelated/' "$R/src/other.js"
git -C "$R" commit -qam 'chore: in between'
sed -i '12s/.*/fixed/' "$R/src/app.js"
seq -f 'appended %g' 1 10 >> "$R/src/app.js"
printf 'assert fixed\n' > "$R/test/app.test.js"
git -C "$R" add -A; git -C "$R" commit -qm 'fix: repair line 12'
FIX=$(git -C "$R" rev-parse HEAD)

KD="$TMP/keys"
mkdir -p "$KD"
key() { # <name> <K1 body> [K2 body]
  {
    printf '# Answer key\n\n## The key\n\n### K1 - BLOCKING - the write is dropped\n\n%s\n\n' "$2"
    [ -z "${3:-}" ] || printf '### K2 - SHOULD-FIX - a second defect\n\n%s\n\n' "$3"
    printf '## Scoring rules\n\n- K1 is a HIT only if the review names src/app.js:3.\n'
  } > "$KD/$1.md"
}
probs() { key_two_sided "$KD/$1.md" "$R" "$TARGET" "$FIX"; }

# ---- 1. The check itself ----------------------------------------------------
key good 'src/app.js:12 drops the write. Executed.'
check test -z "$(probs good)"
# A unique basename resolves the same way anchor_scan's does.
key base 'app.js:12 drops the write.'
check test -z "$(probs base)"
# One citation passing both sides is enough; the rest may be context.
key mixed 'src/app.js:3 sets it up and src/app.js:11-13 drops it.'
check test -z "$(probs mixed)"

# Clean side fails: the fix never touched line 3, so the clean tree still holds
# exactly the code this item calls a defect.
key outside 'src/app.js:3 drops the write.'
P=$(probs outside)
check grep -qF 'K1 has no citation the reference fix changes: outside every line the fix changes, so the clean tree still holds that code: src/app.js:3' <<< "$P"
# Defective side fails: past the end of the file at the target.
key past 'src/app.js:900 drops the write.'
P=$(probs past)
check grep -qF 'K1 has no citation the reference fix changes: past the end of the file at the target: src/app.js:900' <<< "$P"
# ★ Line 25 exists only in the FIX's numbering (keygen.md rule 7). Both hunk
# sides are the old side here, so the fixed file cannot lend it a line.
key fixside 'src/app.js:25 drops the write.'
P=$(probs fixside)
check grep -qF 'past the end of the file at the target: src/app.js:25' <<< "$P"
# No citation at all, or one into a file the fix never touched.
key none 'The write is dropped somewhere in the handler.'
P=$(probs none)
check grep -qF 'K1 cites no path:line in a file the reference fix changes (src/app.js, test/app.test.js), so nothing ties it to the repair' <<< "$P"
key elsewhere 'src/other.js:2 drops the write.'
check grep -qF 'K1 cites no path:line in a file the reference fix changes' <<< "$(probs elsewhere)"
# Only the failing item is named, and one item's citation cannot prove another.
key pair 'src/app.js:12 drops the write.' 'src/app.js:3 is also wrong.'
P=$(probs pair)
check test "$(grep -c . <<< "$P")" -eq 1
check grep -q '^K2 has no citation' <<< "$P"
key borrow 'The write is dropped.' 'src/app.js:12 is where.'
P=$(probs borrow)
check grep -q '^K1 cites no path:line' <<< "$P"
check test "$(grep -c '^K2' <<< "$P")" -eq 0
# The Scoring rules section cites src/app.js:3 and must not be read as K2's.
check test "$(key_item_text "$KD/pair.md" K2 | grep -c 'Scoring rules')" -eq 0
# K1 is not K10.
printf '### K10 - NIT - x\n\nsrc/app.js:12\n\n### K1 - NIT - y\n\nnothing\n' > "$KD/ten.md"
check test "$(key_item_text "$KD/ten.md" K1 | grep -c 'src/app.js')" -eq 0
# A CLEAN key has no items and nothing to prove.
printf '# Pass\n\n## CLEAN - no planted defects\n' > "$KD/clean.md"
check test -z "$(key_two_sided "$KD/clean.md" "$R" "$TARGET" "$FIX")"
# A reference fix that is not in the repo is a refusal, never a vacuous pass.
check grep -qF 'is not in' <<< "$(key_two_sided "$KD/good.md" "$R" "$TARGET" 0000000000000000000000000000000000000000)"

# ---- 2. add-pass refuses, then registers ------------------------------------
LABEL=p1
mkdir -p "$CADRE_HOME/keys" "$CADRE_HOME/passes.d"
printf '%s|%s|%s|HEAD~1|keys/%s.md\n' "$LABEL" "${TARGET:0:9}" "$TMP/checkout" "$LABEL" > "$CADRE_HOME/passes.d/$LABEL.meta"
cp "$KD/pair.md" "$CADRE_HOME/keys/$LABEL.md"
OUT=$("$ROOT/bin/cadre" add-pass "$LABEL" 2>&1); RC=$?
check test "$RC" -ne 0
check grep -qF 'no reference fix recorded' <<< "$OUT"
check test "$(grep -c "^$LABEL|" "$CADRE_HOME/passes.conf" 2>/dev/null)" -eq 0
printf '%s\t%s\t%s\n' "$R" "$TARGET" "$FIX" > "$CADRE_HOME/passes.d/$LABEL.fix"
OUT=$("$ROOT/bin/cadre" add-pass "$LABEL" 2>&1); RC=$?
check test "$RC" -ne 0
check grep -qF 'Not every item is proved on both trees' <<< "$OUT"
check grep -qF 'K2 has no citation the reference fix changes' <<< "$OUT"
check test "$(grep -c "^$LABEL|" "$CADRE_HOME/passes.conf" 2>/dev/null)" -eq 0
check test ! -e "$CADRE_HOME/passes.d/$LABEL.two-sided"
# Mutation: correct K2's citation and nothing else, and it registers.
key pair 'src/app.js:12 drops the write.' 'src/app.js:14 is also wrong.'
cp "$KD/pair.md" "$CADRE_HOME/keys/$LABEL.md"
OUT=$("$ROOT/bin/cadre" add-pass "$LABEL" 2>&1); RC=$?
check test "$RC" -eq 0
check grep -qF 'two-sided: K1 K2 each cite a target line the reference fix changes' <<< "$OUT"
check grep -q "^$LABEL|" "$CADRE_HOME/passes.conf"
check test "$(cat "$CADRE_HOME/passes.d/$LABEL.two-sided")" = $'K1\nK2'
# A CLEAN pass registers with no reference fix, and records no proof.
printf 'clean|%s|%s|HEAD~1|keys/clean.md\n' "${TARGET:0:9}" "$TMP/checkout" > "$CADRE_HOME/passes.d/clean.meta"
cp "$KD/clean.md" "$CADRE_HOME/keys/clean.md"
OUT=$("$ROOT/bin/cadre" add-pass clean 2>&1); RC=$?
check test "$RC" -eq 0
check test ! -e "$CADRE_HOME/passes.d/clean.two-sided"

# ---- 3. The report states it per pass ---------------------------------------
check grep -qF 'Two-sided key check: K1, K2 proved at add-pass' <<< "$(two_sided_line "$LABEL" "$CADRE_HOME/keys/$LABEL.md")"
# An item folded into the key after registration carries no proof, and says so.
printf '### K3 - NIT - folded in later\n\nsrc/other.js:2\n' >> "$CADRE_HOME/keys/$LABEL.md"
check grep -qF 'K1, K2 proved at add-pass; ★ K3 added to the key since, with no two-sided proof' <<< "$(two_sided_line "$LABEL" "$CADRE_HOME/keys/$LABEL.md")"
check grep -qF 'Two-sided key check: not recorded' <<< "$(two_sided_line handmade "$CADRE_HOME/keys/$LABEL.md")"
# ...in a real gauntlet report, keyed passes only.
G="$TMP/grade-home"
mkdir -p "$G/p1" "$G/passes.d"
git -C "$TMP" clone -q "$R" checkout
printf 'p1|%s|%s|%s|key.md\nclean|%s|%s|%s|clean.md\n' "$FIX" "$TMP/checkout" "$FIX" "$FIX" "$TMP/checkout" "$FIX" > "$G/passes.conf"
cp "$KD/good.md" "$G/key.md"; cp "$KD/clean.md" "$G/clean.md"
printf 'K1\n' > "$G/passes.d/p1.two-sided"
SL=$(slug candidate)
mkdir -p "$G/clean"
printf 'blocking: the write is dropped\nVerdict: blocking\n' > "$G/p1/$SL-run1.md"
printf 'Verdict: ship it\n' > "$G/clean/$SL-run1.md"
grade_one() { if key_is_clean "$1"; then echo '{"items":{},"extras":[]}' > "$3"; else echo '{"items":{"K1":"HIT"},"quotes":{"K1":"the write is dropped"},"extras":[]}' > "$3"; fi; }
CADRE_HOME="$G" run_gauntlet candidate 1 1 > "$TMP/grade-output" 2>&1
REPORT="$G/report-$SL-by-$(slug j1).md"
check grep -qF 'Two-sided key check: K1 proved at add-pass (each cites a target line the reference fix changes)' "$REPORT"
check test "$(grep -c 'Two-sided key check' "$REPORT")" -eq 1

# ---- 4. make-pass records the reference fix beside the meta ------------------
# A stub drafting agent: make-pass needs a judge to transcribe, never to grade.
mkdir -p "$TMP/bin" "$TMP/agents.d"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/drafter"; chmod +x "$TMP/bin/drafter"
printf 'run_drafter() { echo "### K1 - BLOCKING - drafted"; }\n' > "$TMP/agents.d/drafter.sh"
OUT=$(CADRE_JUDGE=drafter CADRE_AGENTS_D="$TMP/agents.d" PATH="$TMP/bin:$PATH" \
      "$ROOT/bin/cadre" make-pass drafted "$R" "$TARGET" "$FIX" 2>&1); RC=$?
check test "$RC" -eq 0
check test "$(cat "$CADRE_HOME/passes.d/drafted.fix")" = "$(readlink -f "$R")"$'\t'"$TARGET"$'\t'"$FIX"
check grep -qF 'add-pass' <<< "$OUT"
check grep -qF 'cite a TARGET path:line that the fix changes' <<< "$OUT"
# Never inside the checkout a reviewer reads.
CHK=$(cut -d'|' -f3 "$CADRE_HOME/passes.d/drafted.meta")
check test "$(grep -rl "$FIX" "$CHK" --exclude-dir=.git 2>/dev/null | wc -l)" -eq 0

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
