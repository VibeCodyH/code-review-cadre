#!/usr/bin/env bash
# Runner exit-contract lint: a passing script must prove it can fail.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() {
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; fi
}

new_fixture_dir() {
  FIXTURE=$(mktemp -d -p "$TMP")
}

# Mixed fixture dir: honest passes, lying shape, errexit abort, honest exit 7.
new_fixture_dir
MIXED="$FIXTURE"

cat > "$MIXED/errexit-pass.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
true
echo ok
EOF

cat > "$MIXED/counter-pass.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
check() { if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi; }
check true
printf '%s passed; %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
EOF

cat > "$MIXED/lying.sh" <<'EOF'
#!/usr/bin/env bash
false
echo "all done"
EOF

cat > "$MIXED/errexit-false-echo.sh" <<'EOF'
#!/usr/bin/env bash
set -e
false
echo "should not reach"
EOF

cat > "$MIXED/exit7.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 7
EOF

OUT=$(CADRE_TEST_DIR="$MIXED" bash "$ROOT/test.sh" 2>&1); RC=$?

# Honest errexit and counter passes must be reported PASS.
check grep -q "PASS $MIXED/errexit-pass.sh" <<<"$OUT"
check grep -q "PASS $MIXED/counter-pass.sh" <<<"$OUT"

# Lying shape must be rejected by lint, not executed.
check grep -q "FAIL $MIXED/lying.sh (no exit contract:" <<<"$OUT"
check grep -q "no exit contract" <<<"$OUT"
if grep -q "PASS $MIXED/lying.sh" <<<"$OUT"; then FAIL=$((FAIL+1)); printf 'FAIL: lying shape should not PASS\n'; else PASS=$((PASS+1)); fi

# Errexit false-then-echo must FAIL via errexit (not lint).
check grep -q "FAIL $MIXED/errexit-false-echo.sh" <<<"$OUT"
if grep -q "FAIL $MIXED/errexit-false-echo.sh (no exit contract:" <<<"$OUT"; then FAIL=$((FAIL+1)); printf 'FAIL: errexit false-echo should fail via errexit, not lint\n'; else PASS=$((PASS+1)); fi

# Honest exit 7 must be reported as FAIL.
check grep -q "FAIL $MIXED/exit7.sh" <<<"$OUT"

# Mixed dir contains failures, so overall exit must be non-zero.
check test "$RC" -ne 0

# Guard against recursion: fixture dir must not include this test itself.
check test ! -f "$MIXED/runner-contract.sh"
if grep -q "runner-contract" <<<"$OUT"; then FAIL=$((FAIL+1)); printf 'FAIL: fixture dir must not include runner-contract.sh\n'; else PASS=$((PASS+1)); fi

# Clean all-pass dir must exit 0 (lint does not red-flag honest tests).
new_fixture_dir
CLEAN="$FIXTURE"
cat > "$CLEAN/errexit-pass.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
true
EOF
cat > "$CLEAN/counter-pass.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
check() { if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi; }
check true
[ "$FAIL" -eq 0 ]
EOF

OUT2=$(CADRE_TEST_DIR="$CLEAN" bash "$ROOT/test.sh" 2>&1); RC2=$?
check test "$RC2" -eq 0
check grep -q "PASS $CLEAN/errexit-pass.sh" <<<"$OUT2"
check grep -q "PASS $CLEAN/counter-pass.sh" <<<"$OUT2"
if grep -q "no exit contract" <<<"$OUT2"; then FAIL=$((FAIL+1)); printf 'FAIL: clean dir should have no lint failures\n%s\n' "$OUT2"; else PASS=$((PASS+1)); fi

printf '%s passed; %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
