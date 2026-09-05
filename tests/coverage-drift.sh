#!/usr/bin/env bash
# No adapters, models, or network. Real Git diffs and synthetic saved reports.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export CADRE_ROOT="$ROOT"
. "$ROOT/lib/grade.sh"
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() {
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; fi
}
repo="$TMP/repo"
mkdir -p "$repo/src/a" "$repo/src/b" "$repo/app/(group)/[id]" "$repo/unchanged"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name Test
files=('src/a/index.ts' 'src/b/index.ts' 'src/unique.ts' 'src/myunique.ts'
       'app/(group)/[id]/a+(x).ts' 'src/space name.ts' 'src/deleted.ts'
       'src/other.ts' 'src/pure.ts' 'src/alias.ts' 'unchanged/alias.ts' 'src/rename.ts'
       'name.ts' 'x).ts' 'src/apostrophe'"'"'name.ts')
for f in "${files[@]}"; do seq 1 60 > "$repo/$f"; done
printf '\0base\n' > "$repo/binary.dat"
git -C "$repo" add -- .
git -C "$repo" commit -qm base
BASE=$(git -C "$repo" rev-parse HEAD)
for f in "${files[@]}"; do
  case "$f" in src/deleted.ts|src/pure.ts|src/rename.ts|unchanged/*) continue ;; esac
  awk 'NR==30{$0="changed"} {print}' "$repo/$f" > "$TMP/edited"
  cp "$TMP/edited" "$repo/$f"
done
rm "$repo/src/deleted.ts"
# Pure deletion at line 50. The other.ts hunk is at 30; never borrow it.
awk 'NR != 50' "$repo/src/pure.ts" > "$TMP/edited"
cp "$TMP/edited" "$repo/src/pure.ts"
printf 'new line\n' > "$repo/src/new.ts"
printf '\0changed\n' > "$repo/binary.dat"
mv "$repo/src/rename.ts" "$repo/src/renamed.ts"
git -C "$repo" add -- .
git -C "$repo" commit -qm change
SHA=$(git -C "$repo" rev-parse HEAD)
scan() {
  printf '%s\n' "$1" > "$TMP/review"
  anchor_scan "$TMP/review" "$repo" "$BASE" "$SHA"
  check test "$ANCHOR_CHECKED" -eq "$2"
  check test "$ANCHOR_DRIFT" -eq "$3"
}

scan 'src/unique.ts:30 src/unique.ts:2' 2 1
check test "$ANCHOR_DRIFT_LIST" = 'src/unique.ts:2'
scan 'src/myunique.ts:30' 1 0                    # no suffix unique.ts attribution
scan 'unknown/src/unique.ts:900' 0 0           # no substring full-path attribution
scan 'src/a/index.ts:30' 1 0                   # no sibling basename attribution
scan 'index.ts:900 alias.ts:900' 0 0           # unchanged siblings also ambiguous
scan 'unique.ts:900' 1 1
scan 'app/(group)/[id]/a+(x).ts:30' 1 0
scan 'a+(x).ts:30' 1 0
scan 'src/space name.ts:30' 1 0
scan 'space name.ts:30' 1 0                   # do not fragment into root name.ts
scan "src/apostrophe'name.ts:30" 1 0
scan 'src/unique.ts:2-30' 1 0                  # range starts outside, overlaps later
scan 'src/unique.ts:2–30 src/unique.ts:2+30' 0 0 # unsupported ranges cannot become points
scan 'src/unique.ts:2..30 src/unique.ts:2,30' 0 0
scan 'src/unique.ts:1-2' 1 1
scan 'src/unique.ts#L2-L30' 1 0
scan 'src/unique.ts#L900-L901' 1 1
scan 'src/unique.ts:27 src/unique.ts:33' 2 0    # the three context lines count
scan 'src/deleted.ts:50' 1 0                   # old side exists, new side is empty
scan 'src/deleted.ts:900 src/other.ts:30' 2 1
scan 'src/pure.ts:50 src/pure.ts:30' 2 1        # per-file hunk isolation
check test "$ANCHOR_DRIFT_LIST" = 'src/pure.ts:30'
scan 'src/new.ts:1 src/new.ts:2' 2 1
scan 'src/rename.ts:30 src/renamed.ts:30' 2 0   # renames are deletion + addition
scan 'src/new.ts:0 src/new.ts:4-2 src/new.ts:1:99' 0 0
scan 'binary.dat:900 missing.ts:900 localhost:3000 node:18' 0 0
scan 'src/unique.ts:30foo src/unique.ts:30-unknown' 0 0
printf 'src/unique.ts:900\n' > "$TMP/review"
anchor_scan "$TMP/review" "$repo" '' "$SHA"
check test "$ANCHOR_CHECKED" -eq 0
anchor_scan "$TMP/review" "$repo" invalid-ref "$SHA"
check test "$ANCHOR_CHECKED" -eq 0
anchor_scan "$TMP/review" "$repo" "$SHA" "$SHA"
check test "$ANCHOR_CHECKED" -eq 0

# A side with zero length contains no position. Exercise exact hunk headers
# independently of context expansion in Git, including a deletion at EOF.
printf 'src/deleted.ts:50 src/deleted.ts:1\n' > "$TMP/review"
OUT=$(CADRE_ANCHOR_PATH=src/deleted.ts CADRE_ANCHOR_BASENAME=deleted.ts \
      CADRE_ANCHOR_PATCH='@@ -50 +0,0 @@' awk -v unique=1 -f "$ROOT/lib/anchor-scan.awk" "$TMP/review")
check test "$OUT" = $'2\t1\tsrc/deleted.ts:1'

# Panel means per-run ratios, not pooled files, and keeps observations separate.
mkdir -p "$TMP/home"
cat > "$TMP/home/report-one-by-j1.md" <<'EOF'
# Gauntlet: `one`
## alpha
- run 1 coverage: 1/2 changed files mentioned
- run 1: K1=HIT
- run 2 coverage: 4/4 changed files mentioned
- run 2: K1=HIT
## beta
- run 1 coverage: — (all 2 changed file(s) ambiguous by shared basename)
- run 1: K1=MISS
## Verdict: SEAT: can review alone
EOF
cat > "$TMP/home/report-one-by-j2.md" <<'EOF'
# Gauntlet: `one`
## alpha
- run 1 coverage: 0/2 changed files mentioned
- run 1: K1=MISS
## Verdict: DO NOT SLOT
EOF
cat > "$TMP/home/report-old.md" <<'EOF'
# Gauntlet: `old`
## alpha
- run 1: K1=HIT
## Verdict: SEAT: can review alone
EOF
cat > "$TMP/home/report-invalid.md" <<'EOF'
# Gauntlet: `leaked`
## alpha
- run 1 coverage: 9/9 changed files mentioned
- run 1: K1=HIT
## Verdict: INVALID, leaked key
EOF
OUT=$(CADRE_HOME="$TMP/home" "$ROOT/bin/cadre" panel --save)
check grep -qF 'FILES % (runs)' <<< "$OUT"
check grep -qE '^one.*judge: j1.*HIT.*75% \(2\)$' <<< "$OUT"
check grep -qE '^one.*judge: j2.*MISS.*0% \(1\)$' <<< "$OUT"
check grep -qE '^old +HIT +-$' <<< "$OUT"
check grep -qE '^one.*judge: j1.*MISS.*-$' <<< "$OUT"
check grep -qF 'Weigh FILES alongside item hits' <<< "$OUT"
check grep -qE '^# +one.*judge: j1.*75% \(2\)$' "$TMP/home/roster"
check test "$(grep -c '99%\|100%' <<< "$OUT")" -eq 0

# Exercise the real grade report path with deterministic judges. No reviewer
# runs, no provider calls; drift must remain advisory even at a 100% hit rate.
export CADRE_HOME="$TMP/grade-home" CADRE_WORK="$TMP/work" CADRE_JUDGE='j1,j2'
. "$ROOT/lib/common.sh"
mkdir -p "$CADRE_HOME/alpha"
PASSES="$CADRE_HOME/passes.conf"
printf 'alpha|%s|%s|%s|key.md\n' "$SHA" "$repo" "$BASE" > "$PASSES"
cat > "$CADRE_HOME/key.md" <<'EOF'
#### K1 blocking - the changed operation drops an important write
details
#### K2 blocking - the authentication response exposes a private token
details
EOF
sl=$(slug one)
printf '**blocking** src/unique.ts:900 — dropped write and leaked token\nVerdict: blocking\n' > "$CADRE_HOME/alpha/$sl-run1.md"
grade_one() {
  printf '%s\n' '{"items":{"K1":"HIT","K2":"HIT"},"quotes":{"K1":"dropped write","K2":"leaked token"},"extras":[]}' > "$3"
}
run_gauntlet one 1 1 > "$TMP/grade-output" 2>&1
grade_rc=$?
check test "$grade_rc" -eq 0
[ "$grade_rc" -eq 0 ] || cat "$TMP/grade-output"
report="$CADRE_HOME/report-$sl-by-$(slug j1,j2).md"
check grep -qF 'run 1 anchor positions: 1/1 outside diff hunks' "$report"
check grep -qF 'outside hunks: src/unique.ts:900' "$report"
check grep -qF '## Verdict: SEAT: can review alone' "$report"
check grep -qF 'K1=HIT' "$report"
check grep -qF 'run 1 coverage:' "$report"
# Suspected key leaks skip both coverage and anchor measurement.
cp "$CADRE_HOME/key.md" "$CADRE_HOME/alpha/$sl-run1.md"
printf '\nsrc/unique.ts:900\nVerdict: blocking\n' >> "$CADRE_HOME/alpha/$sl-run1.md"
run_gauntlet one 1 1 > "$TMP/leaked-output" 2>&1
check grep -q 'SUSPECT' "$report"
check test "$(grep -c 'anchor positions:' "$report")" -eq 0

printf '%s passed; %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
