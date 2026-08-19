#!/usr/bin/env bash
# Holds the engine/benchmark seam (#25). Static and fast: no models, no reviews.
#
#   tests/engine-seam.sh
#
# The seam is the claim that lib/engine/ PRODUCES findings.json and the benchmark
# half of cadre only CONSUMES it. That claim is worth nothing as prose -- the
# whole reason it is written down is that every future change is a chance to
# reach across it for one convenient symbol, and nothing about that would fail.
#
# ⚠ STRUCTURAL, and honestly weaker than it will be. `bin/cadre` is still one
# binary that sources both halves, so at runtime every function is in scope no
# matter who owns it: these checks read the source rather than observing a
# refusal. The two-binary split (#25 PR3) is what turns them into real isolation.
# Until then this catches the ordinary way the seam gets crossed -- somebody
# calls an engine function from the grading path because it was right there.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Comment lines are exempt throughout. The comments that EXPLAIN this seam name
# the symbols on both sides of it, and a rule that cannot tell a call from an
# explanation punishes documentation. Same exemption the \x1b ban in
# review-smoke.sh needs, for the same reason.
code_only() { grep -vE '^[[:space:]]*#'; }

echo "== the benchmark must not call into the engine =="
# grade, the judges and the pass runner are the benchmark. If any of them calls
# an engine_* function or cmd_synthesize, then grading a FOREIGN findings.json
# stops being possible and nobody finds out until they try.
BENCH="$ROOT/lib/grade.sh $ROOT/lib/adjudicate.sh $ROOT/lib/run-pass.sh $ROOT/lib/aggregate.sh"
for f in $BENCH; do
  check "$(basename "$f") calls no engine_* function" \
    "! code_only < '$f' | grep -qE '\bengine_[a-z_]+'"
  check "$(basename "$f") does not call cmd_synthesize" \
    "! code_only < '$f' | grep -q 'cmd_synthesize'"
  check "$(basename "$f") sources nothing from lib/engine" \
    "! code_only < '$f' | grep -q 'lib/engine'"
done

echo "== and the engine must not reach back into the benchmark =="
# The other direction, which is the one that looks harmless. An engine that
# knows about grades, judges or answer keys cannot be handed to somebody who
# only wants a review, and the packaging goal (#7) dies quietly.
for f in "$ROOT"/lib/engine/*.sh; do
  check "$(basename "$f") does not call the grader" \
    "! code_only < '$f' | grep -qE 'cmd_grade|judge_[a-z_]+|answer_key|score_'"
  check "$(basename "$f") does not read slots.tsv or the pass config" \
    "! code_only < '$f' | grep -qE 'slots\.tsv|passes\.conf'"
done

echo "== the graded layer is verbatim: nothing downstream may write to it =="
# ★ THE RAIL, asserted in the source as well as in the output. review-smoke.sh
# checks that a real findings.json has no settle or verify keys on its claims;
# this checks that no code was written with the intent of putting them there. A
# `status` or `ledger_id` assigned inside the claims projection is the whole
# failure -- a reviewer's score becoming a function of a later model's opinion --
# and it would still produce a valid-looking file.
CLAIMS=$(sed -n '/^engine_claims()/,/^}/p' "$ROOT/lib/engine/synthesize.sh")
check "engine_claims writes no status field" "! grep -q 'status:' <<<\"\$CLAIMS\""
check "engine_claims writes no ledger_id"    "! grep -q 'ledger_id' <<<\"\$CLAIMS\""
check "engine_claims writes no verdict"      "! grep -q 'verdict' <<<\"\$CLAIMS\""
# ...and the merged layer is where they DO belong, so settle has somewhere to go.
FINDS=$(sed -n '/^engine_findings()/,/^}/p' "$ROOT/lib/engine/synthesize.sh")
check "engine_findings keeps the settle slots" \
  "grep -q 'status:' <<<\"\$FINDS\" && grep -q 'ledger_id' <<<\"\$FINDS\""
check "verify defaults to off"  "grep -q 'ran: false' '$ROOT/lib/engine/synthesize.sh'"

echo "== one severity pattern, not two =="
# ★ The extraction pattern is shared with review_findings() out of a single
# variable in common.sh. A literal copy in lib/engine/ would drift the moment
# either side is tuned, and drift where nothing compares the two numbers: the
# count says 13 findings, the projection emits 4, and both look fine alone.
check "the pattern is defined once" \
  "[ \$(grep -c '^SEVERITY_RE=' '$ROOT/lib/common.sh') -eq 1 ]"
check "the engine holds no copy of it" \
  "! code_only < '$ROOT/lib/engine/synthesize.sh' | grep -q 'should\[ -\]fix'"
check "the engine uses the shared one" \
  "grep -q 'SEVERITY_RE' '$ROOT/lib/engine/synthesize.sh'"

echo "== a FOREIGN findings.json is readable with no cadre code at all =="
# The acceptance test for the contract itself: this fixture was not produced by
# cadre, and everything below is plain jq. If the format needed an engine helper
# to interpret, the seam would be a seam in name only.
#
# ⚠ What this does NOT yet prove: that `cadre grade` scores it. Grading still
# reads review.md by design in PR1, so the consumer half lands with the grade
# migration (#25 PR3) and this fixture is what it will be pointed at.
FX="$ROOT/tests/fixtures/foreign-findings.json"
check "the fixture is valid json"    "jq -e . '$FX' >/dev/null"
check "it declares the schema"       "[ \"\$(jq -r .schema '$FX')\" = 'cadre/findings@1' ]"
check "it is content-addressed"      "jq -e '.target.base_tree and .target.reviewed_tree' '$FX' >/dev/null"
check "every claim names a reviewer"  \
  "[ \$(jq '[.claims[] | select(.reviewer == null)] | length' '$FX') -eq 0 ]"
check "every claim carries its own words" \
  "[ \$(jq '[.claims[] | select(.source_text == null or .source_text == \"\")] | length' '$FX') -eq 0 ]"
# ★ Verbatim means a severity cadre's own vocabulary does not contain must
# survive the round trip. This fixture says `major`, and a contract that quietly
# rewrote it to should-fix would be grading its own paraphrase.
check "a foreign severity is not rewritten" \
  "[ \"\$(jq -r '.claims[0].severity_stated' '$FX')\" = 'major' ]"
check "an unknown key does not invalidate it" "jq -e '._note' '$FX' >/dev/null"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
