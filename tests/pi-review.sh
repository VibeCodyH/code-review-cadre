#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/artifacts"
cat > "$T/bin/node" <<'STUB'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = --out ]; then out="$2"; shift; fi
  shift
done
mkdir -p "$out"
case "$PI_TEST_STATE" in
  ok) printf '{"status":"ok"}\n' > "$out/result.json"; printf 'Verdict: no defects found\n' > "$out/review.md" ;;
  degraded) printf '{"status":"degraded"}\n' > "$out/result.json"; printf '**blocking**\nA real partial finding\n_TRUNCATED: timeout\n' > "$out/review.md" ;;
  lie) printf '{"status":"ok"}\n' > "$out/result.json"; printf 'Verdict: no defects found\n' > "$out/review.md" ;;
  failed) printf '{"status":"failed"}\n' > "$out/result.json"; printf 'DID NOT COMPLETE\n' > "$out/review.md" ;;
esac
echo 'CLI stdout is not the persisted review'
[ "$PI_TEST_STATE" = ok ]
STUB
chmod +x "$T/bin/node"
for state in ok degraded lie failed; do
  : > "$T/meta"
  rc=0
  out=$(printf 'Review this tree\n' | env PATH="$T/bin:$PATH" PI_TEST_STATE="$state" \
    CADRE_HOME="$T/home" CADRE_RUN_META="$T/meta" CADRE_PI_REVIEW_ARTIFACTS="$T/artifacts" \
    bash "$ROOT/bin/agentcall" pireview -d "$T" -M provider/model) || rc=$?
  if [ "$state" = ok ]; then
    [ "$rc" -eq 0 ]; grep -q '^state=ok$' "$T/meta"; grep -q '^Verdict: no defects found$' <<< "$out"
  elif [ "$state" = degraded ]; then
    [ "$rc" -ne 0 ]; grep -q '^state=degraded$' "$T/meta"; grep -q '^\*\*blocking\*\*$' <<< "$out"
    ! grep -q '^DID NOT COMPLETE' <<< "$out"
  else
    [ "$rc" -ne 0 ]; grep -q '^state=failed$' "$T/meta"; ! grep -q '^Verdict:' <<< "$out"
  fi
  ! grep -q 'CLI stdout' <<< "$out"
  echo "ok adapter $state"
done

# A change to SDK code must change the adapter fingerprint.
mkdir -p "$T/repo/agents.d" "$T/repo/integrations/pi-review"
cp "$ROOT/agents.d/pireview.sh" "$T/repo/agents.d/"
for f in cli.mjs review.mjs package.json package-lock.json; do
  cp "$ROOT/integrations/pi-review/$f" "$T/repo/integrations/pi-review/$f"
done
first=$(CADRE_ROOT="$T/repo" CADRE_HOME="$T/home" bash -c 'source "$1/lib/common.sh"; adapter_sha pireview' _ "$ROOT")
echo '// changed execution behavior' >> "$T/repo/integrations/pi-review/review.mjs"
second=$(CADRE_ROOT="$T/repo" CADRE_HOME="$T/home" bash -c 'source "$1/lib/common.sh"; adapter_sha pireview' _ "$ROOT")
[ -n "$first" ]; [ -n "$second" ]; [ "$first" != "$second" ]
echo 'ok SDK source participates in adapter fingerprint'

mkdir "$T/src"
git -C "$T/src" init -q -b main
git -C "$T/src" config user.name Fixture
git -C "$T/src" config user.email fixture@example.invalid
echo before > "$T/src/app.js"
git -C "$T/src" add app.js
git -C "$T/src" -c core.hooksPath=/dev/null commit -qm base
echo after > "$T/src/app.js"
env PATH="$T/bin:$PATH" PI_TEST_STATE=ok CADRE_HOME="$T/home" CADRE_WORK="$T/work" \
  CADRE_PI_REVIEW_ARTIFACTS="$T/artifacts" \
  bash "$ROOT/bin/cadre" review --roster pireview:provider/model --base main --synth none --label sdk "$T/src" > "$T/panel.log" 2>&1
note=$(jq -r 'select(.event == "complete") | .adapter_note' "$T/home/reviews/sdk/runs.jsonl")
[ -n "$note" ]; [ "$note" != null ]
artifact="${note#pi-review artifacts: }"
[ -s "$artifact/result.json" ]
echo 'ok panel retains durable SDK artifact location'
