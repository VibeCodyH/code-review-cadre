#!/usr/bin/env bash
# Dead-model probe and cache (#76). Stub adapters and a fake curl only: nothing
# here reaches a network.
#
#   tests/dead-models.sh
#
# The rule under test is the honesty one: only a provider saying the model does
# not exist is cached as dead. A probe that could not tell is the operator's
# side, and the seat is dispatched as if no probe existed.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT
D="$SANDBOX"
mkdir -p "$D/bin" "$D/agents.d" "$D/fake" "$D/state"

# The optional SDK may be installed locally; keep the inventory to these stubs.
printf 'bin_pireview() { echo cadre-dead-pireview-not-installed; }\n' > "$D/agents.d/pireview.sh"
for n in good good2 gone lost live plain; do
  printf '#!/bin/sh\nexit 0\n' > "$D/bin/$n"; chmod +x "$D/bin/$n"
done
cat > "$D/agents.d/good.sh" <<'A'
run_good() { echo "REVIEW by good"; echo "Verdict: ship it"; }
A
sed 's/good/good2/g' "$D/agents.d/good.sh" > "$D/agents.d/good2.sh"
# Unquoted heredocs: the counters' paths are baked in, because the adapter runs
# under a scrubbed environment and cannot be told them.
# The provider says the model does not exist. Every call, probe or review, is
# counted, so "not dispatched" is measured rather than inferred.
cat > "$D/agents.d/gone.sh" <<A
alive_gone() { echo x >> "$D/gone.probes"; echo "dead: model '\$model' not found (404)"; }
run_gone() { echo x >> "$D/gone.calls"; echo "REVIEW by gone"; echo "Verdict: ship it"; }
A
# The probe could not reach the host. That is the operator's side, never the model's.
cat > "$D/agents.d/lost.sh" <<A
alive_lost() { echo x >> "$D/lost.probes"; echo "unknown: could not reach http://nowhere.invalid"; }
run_lost() { echo x >> "$D/lost.calls"; echo "REVIEW by lost"; echo "Verdict: ship it"; }
A
cat > "$D/agents.d/live.sh" <<A
alive_live() { echo alive; }
run_live() { echo x >> "$D/live.calls"; echo "REVIEW by live"; echo "Verdict: ship it"; }
A
# A probe that prints something outside the contract gets no benefit of the doubt.
cat > "$D/agents.d/plain.sh" <<'A'
alive_plain() { echo "HTTP/1.1 404 Not Found"; }
run_plain() { echo "REVIEW by plain"; echo "Verdict: ship it"; }
A

S="$D/src"
git init -q "$S"
git -C "$S" config user.email t@example.com
git -C "$S" config user.name t
echo orig > "$S/app.js"
git -C "$S" add -A; git -C "$S" commit -qm base; git -C "$S" branch -M main
git -C "$S" checkout -qb feature
echo change >> "$S/app.js"; git -C "$S" commit -qam feat

run_cadre() {
  CADRE_HOME="$D/state" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
  PATH="$D/bin:$PATH" "$ROOT/bin/cadre" "$@" 2>&1
}
alive() {  # alive <agent> [-M model]: the adapter's answer, as cadre reads it
  CADRE_HOME="$D/state" CADRE_AGENTS_D="$D/agents.d" PATH="$D/fake:$D/bin:$PATH" \
    "$ROOT/bin/agentcall" --alive "$@" 2>&1
}
dead_rec() { ls "$D"/state/dead/"$1"-* 2>/dev/null | head -1; }

echo "== agentcall --alive: the adapter answers, or says it cannot =="
check "an adapter with no probe says so"       "[ \"\$(alive good)\" = 'unprobed: good has no liveness probe' ]"
check "a dead answer passes through"           "[ \"\$(alive gone -M vendor/x)\" = \"dead: model 'vendor/x' not found (404)\" ]"
check "an off-contract answer is unknown"      "alive plain | grep -q '^unknown: plain probe gave no answer'"
rm -f "$D/gone.probes"

echo "== ollama's probe: only a 404 naming the model is dead =="
cat > "$D/fake/curl" <<'A'
#!/bin/sh
o=""
while [ $# -gt 0 ]; do
  [ "$1" = -o ] && o="$2"
  case "$1" in */api/*) echo "$1" >> "$FAKE_LOG" ;; esac
  shift
done
cat > /dev/null
[ -n "$o" ] && printf '%s' "$FAKE_BODY" > "$o"
printf '%s' "$FAKE_CODE"
exit "${FAKE_RC:-0}"
A
chmod +x "$D/fake/curl"
ollama_says() {  # ollama_says <code> <body> [curl-rc]
  FAKE_CODE="$1" FAKE_BODY="$2" FAKE_RC="${3:-0}" FAKE_LOG="$D/fake.log" \
    CADRE_OLLAMA_URL=http://ollama.invalid:11434 alive ollama -M qwen3-judge
}
check "200 is alive"                           "[ \"\$(ollama_says 200 '{\"modelfile\":\"x\"}')\" = alive ]"
check "it asked /api/show, not a generation"   "grep -qx 'http://ollama.invalid:11434/api/show' '$D/fake.log' && ! grep -q generate '$D/fake.log'"
check "404 naming the model is dead"           "ollama_says 404 '{\"error\":\"model '\\''qwen3-judge'\\'' not found\"}' | grep -q \"^dead: http://ollama.invalid:11434: model 'qwen3-judge' not found\""
check "404 from something else is unknown"     "ollama_says 404 '<html>Not Found</html>' | grep -q '^unknown: .*without naming the model'"
check "a JSON 404 not about a model is unknown" "ollama_says 404 '{\"error\":\"not found\"}' | grep -q '^unknown:'"
check "401 is unknown, not dead"               "ollama_says 401 '{\"error\":\"unauthorized\"}' | grep -q '^unknown: .*HTTP 401'"
check "no connection is unknown, not dead"     "ollama_says 000 '' 7 | grep -q '^unknown: could not reach'"
check "no host configured is unknown"          "CADRE_HOME='$D/state' CADRE_AGENTS_D='$D/agents.d' '$ROOT/bin/agentcall' --alive ollama -M m 2>&1 | grep -q '^unknown:'"

echo "== a dead model is skipped, cached, and never dispatched =="
OUT=$(run_cadre review --roster gone:vendor/x,good --synth none --base main --label dead1 "$S"); RC=$?
R="$D/state/reviews/dead1"
check "the panel still succeeds"               "[ $RC -eq 0 ]"
check "the probe was asked once"               "[ \$(wc -l < '$D/gone.probes') -eq 1 ]"
check "the seat was never dispatched"          "[ ! -e '$D/gone.calls' ] && ! ls '$R'/gone*.md* >/dev/null 2>&1"
check "console names it, with the answer"      "grep -q \"gone:vendor/x: SKIPPED, model not served (model 'vendor/x' not found (404)), benched until 20\" <<<\"\$OUT\""
check "report names it as a dead model"        "grep -q 'SKIPPED, model not served.*liveness probe was told the model does not exist' '$R/report.md'"
check "slots.tsv rows it as skipped"           "awk -F '\t' '\$2 == \"gone:vendor/x\" && \$4 == \"skipped\"' '$R/slots.tsv' | grep -q ."
check "runs.jsonl records skipped, no spend"   "jq -e 'select(.event == \"complete\" and .seat == \"gone:vendor/x\") | .state == \"skipped\" and .secs == null and .bytes == 0' '$R/runs.jsonl' >/dev/null"
check "counted as skipped, not failed"         "grep -q '1 ok, 0 degraded, 0 inconclusive, 0 failed, 1 skipped' <<<\"\$OUT\""
check "the record is under \$CADRE_HOME/dead"  "[ -s \"\$(dead_rec gone)\" ]"
check "it expires in a day by default"         "t=\$(sed -n 1p \"\$(dead_rec gone)\"); n=\$(date +%s); [ \$((t - n)) -gt 86000 ] && [ \$((t - n)) -le 86400 ]"
check "and keeps the provider's answer"        "sed -n 2p \"\$(dead_rec gone)\" | grep -q \"model 'vendor/x' not found\""

OUT=$(run_cadre review --roster gone:vendor/x,good --synth none --base main --label dead2 "$S")
check "next review skips from the record"      "grep -q 'gone:vendor/x: SKIPPED, model not served' <<<\"\$OUT\""
check "without asking the probe again"         "[ \$(wc -l < '$D/gone.probes') -eq 1 ]"
check "or dispatching the seat"                "[ ! -e '$D/gone.calls' ]"

# Per spec, not per agent: a dead model on a gateway says nothing about the
# gateway's other models. The stub answers dead for everything, so the
# evidence is that it was ASKED about the other spec rather than skipped.
OUT=$(run_cadre review --roster gone:vendor/y,good --synth none --base main --label dead3 "$S")
check "another model on the adapter is probed" "[ \$(wc -l < '$D/gone.probes') -eq 2 ]"

# The synthesizer draws on the same model. A cached-dead spec is not asked to merge.
OUT=$(run_cadre review --roster good,good2 --synth gone:vendor/x --base main --label deadsynth "$S")
R="$D/state/reviews/deadsynth"
check "synth: a cached-dead spec is not dispatched" "[ ! -e '$D/gone.calls' ]"
check "synth: the skip is said, console and report" "grep -q 'synthesis SKIPPED, model not served' <<<\"\$OUT\" && grep -q 'Synthesis.*SKIPPED, model not served' '$R/report.md'"
check "synth: both reviews remain"             "ls '$R'/good-*.md '$R'/good2-*.md >/dev/null 2>&1"

echo "== a stale record is forgotten, and the model probed again =="
printf '1\nold answer\n' > "$(dead_rec gone)"
: > "$D/gone.probes"
OUT=$(run_cadre review --roster gone:vendor/x,good --synth none --base main --label dead4 "$S")
check "an expired record re-probes"            "[ \$(wc -l < '$D/gone.probes') -eq 1 ]"
check "and re-records a fresh expiry"          "[ \"\$(sed -n 1p \"\$(dead_rec gone)\")\" -gt \$(date +%s) ]"
rm -f "$D"/state/dead/*
OUT=$(CADRE_DEAD_TTL=120 run_cadre review --roster gone:vendor/x,good --synth none --base main --label deadttl "$S")
check "CADRE_DEAD_TTL sets the bench"          "t=\$(sed -n 1p \"\$(dead_rec gone)\"); n=\$(date +%s); [ \$((t - n)) -gt 60 ] && [ \$((t - n)) -le 120 ]"

echo "== could not tell is not dead =="
OUT=$(run_cadre review --roster lost,live,good --synth none --base main --label unknown1 "$S"); RC=$?
check "an unknown probe dispatches the seat"   "[ -s '$D/lost.calls' ] && ls '$D/state/reviews/unknown1'/lost-*.md >/dev/null 2>&1"
check "and says the probe could not tell"      "grep -q 'lost: liveness probe could not tell (could not reach http://nowhere.invalid); dispatching' <<<\"\$OUT\""
check "and caches nothing"                     "[ -z \"\$(dead_rec lost)\" ]"
check "an alive seat dispatches, uncached"     "[ -s '$D/live.calls' ] && [ -z \"\$(dead_rec live)\" ]"
check "the whole panel is ok"                  "[ $RC -eq 0 ] && grep -q '3 ok, 0 degraded, 0 inconclusive, 0 failed\\.' <<<\"\$OUT\""

echo "== CADRE_PROBE=0 turns the probe off, not the record =="
rm -f "$D"/state/dead/* "$D/gone.calls"; : > "$D/gone.probes"
OUT=$(CADRE_PROBE=0 run_cadre review --roster gone:vendor/x,good --synth none --base main --label noprobe "$S")
check "no probe is asked"                      "[ ! -s '$D/gone.probes' ]"
check "the seat dispatches as before"          "[ -s '$D/gone.calls' ]"
run_cadre review --roster gone:vendor/x --synth none --base main --label seedrec "$S" >/dev/null
rm -f "$D/gone.calls"
OUT=$(CADRE_PROBE=0 run_cadre review --roster gone:vendor/x,good --synth none --base main --label noprobe2 "$S")
check "an existing record still skips"         "grep -q 'gone:vendor/x: SKIPPED, model not served' <<<\"\$OUT\" && [ ! -e '$D/gone.calls' ]"

echo "== a panel of dead seats owes the caller a failure =="
OUT=$(run_cadre review --roster gone:vendor/x --synth none --base main --label deadonly "$S"); RC=$?
check "an all-dead panel exits 1"              "[ $RC -eq 1 ]"
check "and says why"                           "grep -q 'no usable reviews; 1 reviewer(s) skipped because the provider does not serve their model' <<<\"\$OUT\""
check "and keeps its report"                   "[ -s '$D/state/reviews/deadonly/report.md' ]"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
