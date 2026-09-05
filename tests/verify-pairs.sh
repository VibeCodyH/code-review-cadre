#!/usr/bin/env bash
# Offline execution fixtures: prove both arms, and prove the caller stays intact.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
export CADRE_ROOT="$ROOT" CADRE_HOME="$TMP/state" CADRE_WORK="$TMP/work"
export CADRE_TEST_CMD='bash test/check.sh' CADRE_VERIFY_TIMEOUT=2
unset CADRE_VERIFY_PAIRS
PASS=0 FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "ok $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; fi; }
S="$TMP/source"
mkdir -p "$S/test"
git -C "$S" init -q
git -C "$S" config user.name Test
git -C "$S" config user.email test@example.invalid
printf 'bad\n' > "$S/value [x].js"
git -C "$S" add .
git -C "$S" commit -qm 'feat: initial value'
printf 'good\n' > "$S/value [x].js"
printf '#!/bin/bash\ngrep -qx good "value [x].js"\n' > "$S/test/check.sh"
git -C "$S" add .
git -C "$S" commit -qm 'fix: return the right value'
FIX=$(git -C "$S" rev-parse HEAD)
# Dirty/untracked caller data must survive every execution.
printf 'user edit\n' > "$S/value [x].js"
printf 'keep\n' > "$S/untracked"
BEFORE=$(git -C "$S" status --porcelain)
OUT=$("$ROOT/bin/cadre" setup "$S" 20 2>&1)
check 'default labels candidate unverified' "grep -q 'unverified' '$CADRE_HOME/shortlist-source.tsv'"
check 'default does not execute or create receipts' "[ ! -d '$CADRE_HOME/verification' ]"
OUT=$("$ROOT/bin/cadre" setup "$S" 20 --verify 2>&1)
check 'actual source regression is verified' "tail -1 '$CADRE_HOME/shortlist-source.tsv' | grep -q $'\tverified$'"
check 'source index and worktree untouched' '[ "$BEFORE" = "$(git -C "$S" status --porcelain)" ]'
check 'source HEAD unchanged' '[ "$FIX" = "$(git -C "$S" rev-parse HEAD)" ]'
check 'execution trees cleaned' '[ -z "$(ls -A "$CADRE_WORK")" ]'
check 'both exit codes recorded' "cat '$CADRE_HOME'/verification/*/'$FIX'/result.tsv | grep -q $'verified\tfixed-green-reverted-red\t0\t1'"
check 'fixed tests retained on reverted source' "cat '$CADRE_HOME'/verification/*/'$FIX'/source-revert.patch | grep -q 'value' && ! cat '$CADRE_HOME'/verification/*/'$FIX'/source-revert.patch | grep -q 'test/check'"

run_with() {
  CADRE_TEST_CMD="$1" CADRE_VERIFY_PAIRS=1 "$ROOT/lib/mine-fixes.sh" "$S" 20 > "$TMP/table" 2> "$TMP/log"
}
run_with 'true'
check 'a test that passes both arms is unverified' "tail -1 '$TMP/table' | grep -q $'\tunverified$'"
run_with 'false'
check 'a test that fails at the fix is unverified' "tail -1 '$TMP/table' | grep -q $'\tunverified$'"
run_with 'if grep -qx good "value [x].js"; then exit 0; else sleep 10; fi'
check 'reverted timeout is unverified' "tail -1 '$TMP/table' | grep -q $'\tunverified$'"
run_with 'sleep 10'
check 'fixed timeout is unverified' "tail -1 '$TMP/table' | grep -q $'\tunverified$'"
run_with 'if grep -qx good "value [x].js"; then exit 0; else exit 127; fi'
check 'command launch error is unverified' "tail -1 '$TMP/table' | grep -q $'\tunverified$'"
run_with ''
check 'unknown test runner has own status' "tail -1 '$TMP/table' | grep -q $'\tno-test-cmd$'"
run_with 'if [ -e generated ]; then exit 1; fi; touch generated; true'
check 'each arm starts clean' "tail -1 '$TMP/table' | grep -q $'\tunverified$'"
OUT=$(CADRE_WORK="$CADRE_HOME/nested" "$ROOT/bin/cadre" setup "$S" --verify 2>&1); RC=$?
check 'refuses execution inside answer-key tree' '[ "$RC" -ne 0 ]'
OUT=$(CADRE_WORK="$S/work" "$ROOT/bin/cadre" setup "$S" --verify 2>&1); RC=$?
check 'refuses execution inside user repo' '[ "$RC" -ne 0 ]'
OUT=$(CADRE_WORK="$S/work" "$ROOT/bin/cadre" setup "$S/test" --verify 2>&1); RC=$?
check 'subdirectory input cannot bypass source-root guard' '[ "$RC" -ne 0 ] && [ ! -d "$S/work" ]'
mkdir -p "$TMP/relative"
OUT=$(cd "$TMP/relative" && CADRE_HOME=state CADRE_WORK=work "$ROOT/bin/cadre" setup "$S" --verify 2>&1); RC=$?
check 'relative state and work directories resolve before execution' '[ "$RC" -eq 0 ] && tail -1 "$TMP/relative/state/shortlist-source.tsv" | grep -q $'"'"'\tverified$'"'"''
OUT=$(CADRE_VERIFY_TIMEOUT=no "$ROOT/bin/cadre" setup "$S" --verify 2>&1); RC=$?
check 'invalid timeout propagates setup failure' '[ "$RC" -ne 0 ]'
OUT=$(CADRE_VERIFY_TIMEOUT=00 "$ROOT/bin/cadre" setup "$S" --verify 2>&1); RC=$?
check 'zero-padded zero cannot disable timeout' '[ "$RC" -ne 0 ]'
OUT=$("$ROOT/bin/cadre" setup "$S" --typo 2>&1); RC=$?
check 'unknown setup flags fail' '[ "$RC" -ne 0 ]'
. "$ROOT/lib/common.sh"
. "$ROOT/lib/verify-pair.sh"
export CADRE_TEST_CMD='bash test/check.sh'
VERIFY_RECEIPTS="$TMP/receipts"
mkdir -p "$VERIFY_RECEIPTS"
for shape in add delete rename; do
  R="$TMP/$shape"
  mkdir -p "$R/test"
  git -C "$R" init -q
  git -C "$R" config user.name Test
  git -C "$R" config user.email test@example.invalid
  printf 'old\n' > "$R/old.js"
  git -C "$R" add .
  git -C "$R" commit -qm initial
  case "$shape" in
    add) printf 'new\n' > "$R/new.js"; printf '[ -f new.js ]\n' > "$R/test/check.sh" ;;
    delete) rm "$R/old.js"; printf '[ ! -e old.js ]\n' > "$R/test/check.sh" ;;
    rename) mv "$R/old.js" "$R/new.js"; printf '[ -f new.js ] && [ ! -e old.js ]\n' > "$R/test/check.sh" ;;
  esac
  git -C "$R" add .
  git -C "$R" commit -qm "fix: $shape source"
  V=$(verify_pair "$R" "$(git -C "$R" rev-parse HEAD)")
  check "$shape source patch is reversible without reverting test" '[ "$V" = verified ]'
done
R="$TMP/inline-rust"
mkdir -p "$R/tests"
git -C "$R" init -q
git -C "$R" config user.name Test
git -C "$R" config user.email test@example.invalid
printf 'pub fn value() -> u8 { 0 }\n#[test]\nfn example() { assert_eq!(value(), 1); }\n' > "$R/lib.rs"
git -C "$R" add .
git -C "$R" commit -qm initial
printf 'pub fn value() -> u8 { 0 }\n#[test]\nfn example() { assert_eq!(value(), 0); }\n' > "$R/lib.rs"
printf 'updated\n' > "$R/tests/README.md"
git -C "$R" add .
git -C "$R" commit -qm 'fix: change assertion only'
V=$(CADRE_TEST_CMD='grep -q "value(), 0" lib.rs' verify_pair "$R" "$(git -C "$R" rev-parse HEAD)")
check 'embedded Rust test edits cannot prove a source defect' '[ "$V" = unverified ]'
mv "$R/lib.rs" "$R/new.rs"
git -C "$R" add .
git -C "$R" commit -qm 'fix: relocate inline test'
V=$(CADRE_TEST_CMD='grep -q "value(), 0" new.rs' verify_pair "$R" "$(git -C "$R" rev-parse HEAD)")
check 'new Rust test file cannot bypass inline-test guard' '[ "$V" = unverified ]'
# CADRE_WORK may itself be inside a different git repo. Applying from a nested
# path must not silently skip the patch while reporting success.
git -C "$CADRE_WORK" init -q
V=$(verify_pair "$TMP/rename" "$(git -C "$TMP/rename" rev-parse HEAD)")
check 'work under unrelated repo still applies source patch' '[ "$V" = verified ]'
for testname in value_test.go test_value.py value_test.py value_spec.rb spec_value.rb value_test.rb test_value.rb ValueTest.java ValueTests.java TestValue.java; do
  R="$TMP/conventional-$testname"
  mkdir -p "$R/test"
  git -C "$R" init -q
  git -C "$R" config user.name Test
  git -C "$R" config user.email test@example.invalid
  printf 'good\n' > "$R/value.js"
  printf 'old\n' > "$R/$testname"
  git -C "$R" add .
  git -C "$R" commit -qm initial
  printf 'good\n// cosmetic change\n' > "$R/value.js"
  printf 'new\n' > "$R/$testname"
  printf 'grep -qx new "%s"\n' "$testname" > "$R/test/check.sh"
  git -C "$R" add .
  git -C "$R" commit -qm 'fix: update test expectation'
  V=$(verify_pair "$R" "$(git -C "$R" rev-parse HEAD)")
  check "$testname is retained, never reverted as source" '[ "$V" = unverified ]'
done
mkdir -p "$TMP/detect"
touch "$TMP/detect/go.mod"
unset CADRE_TEST_CMD
check 'targeted detector placeholder becomes full suite' '[ "$(verify_test_cmd "$TMP/detect")" = "go test ./..." ]'
rm "$TMP/detect/go.mod"
printf '{"devDependencies":{"vitest":"*"}}\n' > "$TMP/detect/package.json"
check 'detected JS runner cannot implicitly install' '[ "$(verify_test_cmd "$TMP/detect")" = "npx --no-install vitest run" ]'
export CADRE_TEST_CMD='custom < input'
check 'explicit test command stays literal' '[ "$(verify_test_cmd "$TMP/detect")" = "custom < input" ]'
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
