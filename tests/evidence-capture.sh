#!/usr/bin/env bash
# The saved binary patch must reconstruct the exact tree reviewed by the seats.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home" PATH="/usr/bin:/bin"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export CADRE_ROOT="$ROOT" CADRE_HOME="$SANDBOX/state" CADRE_WORK="$SANDBOX/work"
export CADRE_AGENTS_D="$SANDBOX/adapters" CADRE_ROSTER=fixture
mkdir -p "$HOME" "$CADRE_AGENTS_D" "$SANDBOX/bin"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/fixture"
chmod +x "$SANDBOX/bin/fixture"
export PATH="$SANDBOX/bin:$PATH"
cat > "$CADRE_AGENTS_D/fixture.sh" <<'EOF'
run_fixture() { echo 'Synthetic capture fixture. No model was called.'; echo 'Verdict: ship it'; }
EOF
REPO="$SANDBOX/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.name Fixture
git -C "$REPO" config user.email fixture@example.invalid
printf 'before\n' > "$REPO/app.txt"
printf 'deleted\n' > "$REPO/deleted.txt"
printf '\x00\x01\x02before\x00' > "$REPO/binary.dat"
git -C "$REPO" add .
git -C "$REPO" commit -qm Base
printf 'after\n' > "$REPO/app.txt"
rm "$REPO/deleted.txt"
printf '\x00\x01\x02after\x00' > "$REPO/binary.dat"
printf 'new file\n' > "$REPO/with space.txt"
# A global display preference must not turn a gitlink change into unapplyable
# prose. No submodule checkout is needed to test the recorded object and mode.
git -C "$REPO" update-index --add --cacheinfo 160000,"$(git -C "$REPO" rev-parse HEAD)",module
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.submodule GIT_CONFIG_VALUE_0=log

"$ROOT/bin/cadre" review --base main --synth none --label saved-diff "$REPO" > "$SANDBOX/review.log" 2>&1 || {
  cat "$SANDBOX/review.log"; exit 1;
}
PANEL="$CADRE_HOME/reviews/saved-diff"
assert_patch() {
  local panel="$1" base expected actual hash
  base=$(sed -n 's/^base-tree: //p' "$panel/manifest.txt")
  expected=$(sed -n 's/^reviewed-tree: //p' "$panel/manifest.txt")
  hash=$(sha256sum < "$panel/diff.patch" | cut -d' ' -f1)
  [ "$hash" = "$(cat "$panel/diff.sha256")" ]
  [ "$hash" = "$(sed -n 's/^diff-sha256: //p' "$panel/manifest.txt")" ]
  # A separate index checks content and file modes without changing the source.
  GIT_INDEX_FILE="$SANDBOX/patch-index" git -C "$REPO" read-tree "$base"
  GIT_INDEX_FILE="$SANDBOX/patch-index" git -C "$REPO" apply --cached --binary "$panel/diff.patch"
  actual=$(GIT_INDEX_FILE="$SANDBOX/patch-index" git -C "$REPO" write-tree)
  [ "$actual" = "$expected" ]
}
assert_patch "$PANEL"
grep -q 'GIT binary patch' "$PANEL/diff.patch"
grep -q 'deleted file mode' "$PANEL/diff.patch"
grep -q 'with space.txt' "$PANEL/diff.patch"
grep -q 'new file mode 160000' "$PANEL/diff.patch"
echo 'ok: saved patch reconstructs dirty, deleted, binary, untracked and gitlink content'

"$ROOT/bin/cadre" review --base main --synth none --label saved-diff --force "$REPO" > "$SANDBOX/force.log" 2>&1 || {
  cat "$SANDBOX/force.log"; exit 1;
}
assert_patch "$PANEL"
echo 'ok: force remeasurement retains its own complete patch'

# Moving the source afterwards must not change the export's evidence.
printf 'later branch content\n' > "$REPO/app.txt"
"$ROOT/bin/cadre" export-evidence "$PANEL" "$SANDBOX/export" > "$SANDBOX/export.log" 2>&1 || {
  cat "$SANDBOX/export.log"; exit 1;
}
python3 - "$SANDBOX/export" "$PANEL/diff.patch" <<'PY'
from pathlib import Path
import sys
patches = list(Path(sys.argv[1]).rglob('diff.patch'))
assert patches, 'export has no diff'
assert all(p.read_bytes() == Path(sys.argv[2]).read_bytes() for p in patches)
PY
echo 'ok: exported diff survives a changed source branch'

# Full-target reviews have an empty base and must retain the complete target.
git -C "$REPO" update-index --force-remove module
git -C "$REPO" add .
git -C "$REPO" commit -qm Changed
"$ROOT/bin/cadre" review --full --synth none --label saved-full "$REPO" > "$SANDBOX/full.log" 2>&1 || {
  cat "$SANDBOX/full.log"; exit 1;
}
assert_patch "$CADRE_HOME/reviews/saved-full"
echo 'ok: full-target patch reconstructs the entire reviewed tree'

# No-change patches are valid evidence, even though they are empty files.
git -C "$REPO" commit --allow-empty -qm 'Same tree'
"$ROOT/bin/cadre" review --base HEAD~1 --synth none --label saved-empty "$REPO" > "$SANDBOX/empty.log" 2>&1 || {
  cat "$SANDBOX/empty.log"; exit 1;
}
[ -f "$CADRE_HOME/reviews/saved-empty/diff.patch" ]
[ ! -s "$CADRE_HOME/reviews/saved-empty/diff.patch" ]
"$ROOT/bin/cadre" export-evidence "$CADRE_HOME/reviews/saved-empty" "$SANDBOX/empty-export" > "$SANDBOX/empty-export.log" 2>&1 || {
  cat "$SANDBOX/empty-export.log"; exit 1;
}
echo 'ok: no-change review exports an empty, hashed patch'
