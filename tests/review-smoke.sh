#!/usr/bin/env bash
# Smoke tests for `cadre review`. Stub adapters only: this checks the harness,
# not any model. Runs in seconds.
#
#   tests/review-smoke.sh
#
# Every case here is a bug that was actually in the code at some point. The
# three marked ★ were found by a panel run against this repo's own diff.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

# One stub agent that echoes what it can see, one that truncates, one that dies.
setup_agents() {
  mkdir -p "$1/bin" "$1/agents.d"
  local n
  for n in good good2 trunc dead echoer chrome terse ratepart ratelim \
           synthquote synthtrunc synthrate synthtiny; do
    printf '#!/bin/sh\nexit 0\n' > "$1/bin/$n"; chmod +x "$1/bin/$n"
  done
  cat > "$1/agents.d/good.sh" <<'A'
run_good() {
  echo "REVIEW by good"
  ( cd "$dir" && echo "--ls-files--" && git ls-files \
      && echo "--diff--" && git diff --name-only "$CADRE_PASS_BASE...HEAD" )
}
A
  sed 's/good/good2/g' "$1/agents.d/good.sh" > "$1/agents.d/good2.sh"
  cat > "$1/agents.d/trunc.sh" <<'A'
run_trunc() {
  echo "partial finding"
  echo
  echo "_TRUNCATED, grok stopped early (stopReason=MaxTokens); this review is INCOMPLETE, not a clean pass._"
}
A
  # ★ Nothing to salvage, but it PRINTS raw output after the marker, the way
  # agents.d/grok.sh dumps its JSON. Any "is there text before the marker"
  # heuristic reads that dump as a review and files this as a partial. The
  # marker name is the discriminator precisely so this case stays failed.
  cat > "$1/agents.d/dead.sh" <<'A'
run_dead() {
  echo "DID NOT COMPLETE, no text returned (stopReason=Error). Raw:"
  echo '{"error":"upstream","detail":"a wall of raw output that is not a review"}'
}
A
  # Echoes the prompt it was handed, so a test can assert on what the
  # synthesizer was actually TOLD rather than on a stub's invented answer.
  cat > "$1/agents.d/echoer.sh" <<'A'
run_echoer() { printf '%s\n' "$prompt"; }
A
  # ★ Returns NO review, only the CLI's own chrome. Measured with opencode,
  # which prints colour escapes and a banner around the model's text: the file
  # is non-empty, rc is 0, and a reviewer that said nothing scored as a clean
  # pass. Emptiness has to mean empty of content, not of bytes.
  cat > "$1/agents.d/chrome.sh" <<'A'
# ★ [?25h is a PRIVATE-MODE escape (cursor show), and the strip only allowed
# digits and semicolons between [ and the letter, so it survived and made a
# no-review run look non-empty. Kiro emits it on every call.
run_chrome() { printf '\033[0m\n\033[?25h\033[?2004l\n   \n'; }
A
  # Same chrome, but with a real (very short) review inside it. Must stay ok:
  # "findings=0" is a valid review and a length floor used to throw those away.
  cat > "$1/agents.d/terse.sh" <<'A'
run_terse() { printf '\033[0m\nfindings=0\n\033[0m\n'; }
A
  # ★ A SHORT partial review that happens to TALK about rate limiting, then the
  # truncation marker. rate_limited() is a keyword match over files under 2KB,
  # so this shape matched it and was binned `failed` -- findings discarded --
  # while the adapter was explicitly reporting a partial. Reviewing cadre itself
  # produces exactly this, since cadre handles 429s and a reviewer quotes them.
  cat > "$1/agents.d/ratepart.sh" <<'A'
run_ratepart() {
  printf 'blocking: the 429 too many requests path retries forever.\n'
  printf '_TRUNCATED, stopped early.\n'
}
A
  # A GENUINE rate limit, no review at all: the case the retry loop is for.
  cat > "$1/agents.d/ratelim.sh" <<'A'
run_ratelim() { printf 'Error: 429 too many requests.\n'; }
A
  # ★ A COMPLETE synthesis that ends by QUOTING a reviewer's truncation marker,
  # which the synthesis prompt explicitly asks it to report. Exits 0, because
  # nothing went wrong. Must survive: this is a good merge.
  cat > "$1/agents.d/synthquote.sh" <<'A'
run_synthquote() {
  printf 'Merged. One reviewer was cut off; it ended with:\n'
  printf '_TRUNCATED, stopped early._\n'
}
A
  # ★ A healthy, SHORT synthesis that discusses rate limiting -- which is what
  # merging reviews of this repo produces. Exits 0. Must survive: the keyword
  # scan is not evidence the provider refused anything.
  cat > "$1/agents.d/synthrate.sh" <<'A'
run_synthrate() {
  echo "Panel: 2 reviewers, 2 complete, 0 stopped early."
  echo "Agreed: the retry path for 429 too many requests never gives up. [2/2]"
  printf 'padding %s\n' $(seq 1 60)
}
A
  # The same text from a synthesizer that really DID stop early. Identical bytes,
  # nonzero exit. Must fail closed -- a partial merge is worthless while the
  # reviews it was merging are complete on disk.
  cat > "$1/agents.d/synthtrunc.sh" <<'A'
run_synthtrunc() {
  printf 'Merged. One reviewer was cut off; it ended with:\n'
  printf '_TRUNCATED, stopped early._\n'
  return 1
}
A
}

# A fresh repo on branch `feature`, forked from `main`.
new_repo() {
  local d="$1"
  git init -q "$d"
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name t
  echo orig > "$d/app.js"; echo '*.log' > "$d/.gitignore"
  echo 'TEMPLATE=' > "$d/.env.example"
  git -C "$d" add -A; git -C "$d" commit -qm base; git -C "$d" branch -M main
}

case_dir() {
  # Separate statements: bash expands every word of a `local` line BEFORE any
  # of its assignments take effect, so `local a="$1" b="$SANDBOX/$a"` leaves b
  # pointing at /src.
  local name="$1"
  local d="$SANDBOX/$name"
  mkdir -p "$d"
  setup_agents "$d"
  new_repo "$d/src"
  echo "$d"
}

run_cadre() {  # run_cadre <case-dir> <args...>
  local d="$1"; shift
  CADRE_HOME="$d/state" CADRE_WORK="$d/work" CADRE_AGENTS_D="$d/agents.d" \
  PATH="$d/bin:$PATH" "$ROOT/bin/cadre" "$@" 2>&1
}

echo "== normal branch review =="
D=$(case_dir normal); S="$D/src"
git -C "$S" checkout -qb feature
echo committed >> "$S/app.js"; git -C "$S" commit -qam feat
echo uncommitted >> "$S/app.js"
mkdir -p "$S/src"; echo new > "$S/src/newfeature.js"      # untracked
echo 'SECRET=1' > "$S/.env.local"; echo '.env.local' >> "$S/.gitignore"
echo noise > "$S/debug.log"                                # ignored
BEFORE="$(git -C "$S" status --porcelain | md5sum)$(git -C "$S" rev-parse HEAD)"
OUT=$(run_cadre "$D" review --roster good,trunc,dead,ghost --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
G=$(ls "$R"/good-*.md 2>/dev/null | head -1)
check "source repo untouched"        "[ \"\$BEFORE\" = \"\$(git -C '$S' status --porcelain | md5sum)\$(git -C '$S' rev-parse HEAD)\" ]"
check "no refs/cadre left behind"    "[ -z \"\$(git -C '$S' for-each-ref refs/cadre)\" ]"
check "work dir cleaned"             "[ -z \"\$(ls -A '$D/work')\" ]"
check "untracked file in the DIFF"   "grep -q 'src/newfeature.js' '$R'/report.md"
check "gitignored secret excluded"   "! grep -q 'env.local' '$G'"
check "ignored log excluded"         "! grep -q 'debug.log' '$G'"
check ".env.example did not refuse"  "[ -n '$G' ]"
check "missing agent -> FAILED"      "grep -q 'NOT INSTALLED' '$R'/ghost-*.failed"
check "all 4 roster rows in report"  "[ \$(grep -c '^- \`' '$R/report.md') -eq 4 ]"

# ---- three-state reviewer health ---------------------------------------------
# ★ The truncated case used to assert .md.failed. That was the overcorrection for
# a partial grok review scoring as COMPLETE: it stopped the overstatement by
# throwing the findings away. Both halves are wrong, so it is its own state now.
check "truncated -> .partial not .failed" "ls '$R'/trunc-*.md.partial >/dev/null 2>&1"
check "truncated is NOT a clean review"   "! ls '$R'/trunc-*.md >/dev/null 2>&1"
check "partial findings kept, not binned" "grep -q 'partial finding' '$R'/trunc-*.md.partial"
check "DEGRADED row in the report"        "grep -q 'DEGRADED' '$R/report.md'"
check "report says silence is not clean"  "grep -q 'silence is not' '$R/report.md'"
check "partial review body in report"     "grep -q 'partial finding' '$R/report.md'"
check "counts name all three states"      "grep -qE '1 ok, 1 degraded, 2 failed' <<<\"\$OUT\""
# ★ Marker name decides, not content. This stub prints a raw dump AFTER its
# marker; a "text before the marker" heuristic would file it as a partial.
check "DID NOT COMPLETE + raw -> FAILED"  "ls '$R'/dead-*.md.failed >/dev/null 2>&1"
check "dead reviewer has no .partial"     "! ls '$R'/dead-*.md.partial >/dev/null 2>&1"
# ★ The checkout is synthetic, so its shas die with it. The manifest has to name
# commits that still resolve in the user's repo or it is not provenance.
MB=$(grep '^base:' "$R/manifest.txt" | awk '{print $2}')
MS=$(grep '^snapshot:' "$R/manifest.txt" | awk '{print $2}')
check "manifest base resolves in repo"     "git -C '$S' cat-file -e '$MB^{commit}' 2>/dev/null"
check "manifest snapshot resolves in repo" "git -C '$S' cat-file -e '$MS^{commit}' 2>/dev/null"

echo "== ★ untracked-only change on the default branch =="
# stash create does not consider a new file a change, so SNAP == BASE == HEAD.
# This used to exit "nothing to review" while sitting on the whole feature.
D=$(case_dir untracked_only); S="$D/src"
echo brand new > "$S/feature.js"
OUT=$(run_cadre "$D" review --roster good --base HEAD "$S")
check "reviews an untracked-only change" "grep -q '1 ok' <<<\"\$OUT\""
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "the new file reached the diff"    "grep -q 'feature.js' '$R'/report.md"

echo "== ★ broken index must abort, not silently review HEAD =="
D=$(case_dir bad_index); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
echo dirty >> "$S/app.js"
OUT=$(GIT_INDEX_FILE=/dev/null run_cadre "$D" review --roster good --base main "$S")
check "aborts on stash-create failure"   "grep -qi 'stash create failed' <<<\"\$OUT\""
check "no review dir was created"        "[ ! -d '$D/state/reviews' ] || [ -z \"\$(ls -A '$D/state/reviews')\" ]"

echo "== ★ unsignable commit must abort, not claim 'carried' =="
D=$(case_dir gpgsign); S="$D/src"
echo brand new > "$S/feature.js"
git -C "$S" config commit.gpgsign true
git -C "$S" config user.signingkey NO_SUCH_KEY
OUT=$(run_cadre "$D" review --roster good --base HEAD "$S")
check "carries new files despite gpgsign" "grep -q 'carried 1 untracked' <<<\"\$OUT\""
check "and does not fail the run"         "grep -q '1 ok' <<<\"\$OUT\""

echo "== roster parsing =="
D=$(case_dir roster); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
mkdir -p "$D/state"
printf '# staffed\ngood\ngood2' > "$D/state/roster"          # NO trailing newline
OUT=$(run_cadre "$D" review --base main "$S")
check "last roster line not dropped"  "grep -q '2 reviewer(s)' <<<\"\$OUT\""
OUT=$(run_cadre "$D" review --roster good,good --base main "$S")
check "duplicate spec refused"        "grep -q 'listed twice' <<<\"\$OUT\""
printf '# good\n' > "$D/state/roster"
OUT=$(run_cadre "$D" review --base main "$S")
check "all-commented roster refused"  "grep -q 'commented out' <<<\"\$OUT\""
OUT=$(run_cadre "$D" review --roster good --label reuse --base main "$S")
OUT=$(run_cadre "$D" review --roster good --label reuse --base main "$S")
check "label is single-use"           "grep -q 'already exists' <<<\"\$OUT\""

echo "== parallel =="
D=$(case_dir parallel); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good,good2,trunc --jobs 3 --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "all 3 accounted for in parallel" "[ \$(grep -c '^- \`' '$R/report.md') -eq 3 ]"
check "parallel work dir cleaned"       "[ -z \"\$(ls -A '$D/work')\" ]"

# ★ jobs < roster size. With --jobs 3 and three reviewers the slot loop never
# runs, so the one branch that can deadlock or miscount stayed untested.
OUT=$(run_cadre "$D" review --roster good,good2,trunc --jobs 2 --label throttle --base main "$S")
R2="$D/state/reviews/throttle"
check "throttled queue runs everyone"   "[ \$(grep -c '^- \`' '$R2/report.md') -eq 3 ]"
check "throttled work dir cleaned"      "[ -z \"\$(ls -A '$D/work')\" ]"

echo "== ★ deleted credentials must not reach reviewers =="
# A full clone carries history the preflight cannot scan: a .env committed once
# and deleted still answers `git log -p`. The checkout is built as a synthetic
# two-commit repo so there is no earlier history to mine.
D=$(case_dir history_leak); S="$D/src"
echo 'API_TOKEN=history-only-secret' > "$S/.env"
git -C "$S" add -A; git -C "$S" commit -qm "oops"
git -C "$S" rm -q "$S/.env" 2>/dev/null || git -C "$S" rm -q .env
git -C "$S" commit -qm "remove it"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
echo dirty >> "$S/app.js"
cat > "$D/agents.d/good.sh" <<'A'
run_good() {
  echo "REVIEW by good"
  ( cd "$dir" && echo "--history--" && git log -p --all 2>/dev/null | head -200 )
}
A
OUT=$(run_cadre "$D" review --roster good --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
G=$(ls "$R"/good-*.md 2>/dev/null | head -1)
check "deleted secret NOT reachable"  "! grep -q 'history-only-secret' '$G'"
check "history is only the two commits" "[ \$(grep -c '^commit ' '$G') -le 2 ]"
check "the run still succeeded"       "grep -q '1 ok' <<<\"\$OUT\""

echo "== ★ a key whose item lost its heading must not register =="
# Measured: a still-running make-pass held its redirect open and clobbered a key
# mid-write. K1's heading was destroyed. The old checks were file-global ("a K
# appears somewhere, a severity word appears somewhere") and both passed, because
# the Scoring rules section still mentions K1 in prose. doctor said "ok, 2 key
# items" and three graded runs scored a BLOCKING item with no severity at all,
# so the slot verdict came off the wrong denominator.
D=$(case_dir key_validate)
mkdir -p "$D/state/keys" "$D/state/passes.d"
cat > "$D/state/keys/broken.md" <<'K'
# Answer key for deadbeef (a thing)

## The key

### K2 - SHOULD-FIX - this heading survived

body text

## Scoring rules

- K1 is a HIT only if the review claims the thing.
K
printf 'broken|deadbeef|%s|HEAD~1|keys/broken.md\n' "$D/src" > "$D/state/passes.d/broken.meta"
OUT=$(run_cadre "$D" add-pass broken)
check "add-pass refuses the mangled key"  "grep -q 'not gradeable' <<<\"\$OUT\""
check "it names the orphaned item"        "grep -q 'K1 is referenced' <<<\"\$OUT\""
check "nothing was registered"            "! grep -q '^broken|' '$D/state/passes.conf' 2>/dev/null"

cat > "$D/state/keys/broken.md" <<'K'
# Answer key for deadbeef (a thing)

## The key

### K1 - the heading lost its severity word

body text
K
OUT=$(run_cadre "$D" add-pass broken)
check "a severity-less heading is refused" "grep -q 'no BLOCKING/SHOULD-FIX/NIT' <<<\"\$OUT\""

echo "== ★ a judge that did not read the review must not be scored =="
# Measured on a private pass: a reviewer stated SEVEN findings, its own first
# heading reading "1. blocking - autosave shows Saved without a successful
# save", and the judge returned verdict "no defects found" with extras []. Its
# two key items really were misses, so the run scored plausibly while `extras`
# -- the only record of a reviewer finding a real defect the key never asked
# about -- was silently zeroed. Over the 45 runs graded before this existed it
# fires exactly once, and never on a run that credited a key item.
CADRE_ROOT="$ROOT" CADRE_HOME="$SANDBOX/home" . "$ROOT/lib/common.sh"
CADRE_ROOT="$ROOT" . "$ROOT/lib/grade.sh"
J=$(mktemp -d -p "$SANDBOX")
# The two shapes reviewers actually emit, one per file.
cat > "$J/grok.md" <<'R'
### 1. blocking - autosave shows Saved without a successful save
### 2. should-fix - status changes ignore current state
### 3. nit - badge keys on the wrong string
R
cat > "$J/codex.md" <<'R'
1. **blocking** - [wizard.tsx:179](x): the UI reports a save that failed.
2. **should-fix** - [repo.ts:449](x): versions collide after a delete.
R
cat > "$J/one.md" <<'R'
### 1. blocking - the only thing this review says
R
mkjson() { printf '%s' "$1" > "$J/g.json"; }

mkjson '{"items":{"K1":"MISS","K2":"MISS"},"extras":[],"unusable":false}'
check "silent zeroing is caught"        "judge_incoherent '$J/g.json' '$J/grok.md'"
check "and in the other review shape"   "judge_incoherent '$J/g.json' '$J/codex.md'"
# The check must also NOT fire, or it is a blanket ban on empty extras. Every
# other empty-extras run in the corpus looked like one of these three.
check "one stated finding is not enough" "! judge_incoherent '$J/g.json' '$J/one.md'"
mkjson '{"items":{"K1":"HIT","K2":"MISS"},"extras":[],"unusable":false}'
check "a credited key item clears it"   "! judge_incoherent '$J/g.json' '$J/grok.md'"
mkjson '{"items":{"K1":"DEFER","K2":"MISS"},"extras":[],"unusable":false}'
check "a DEFER means it read the review" "! judge_incoherent '$J/g.json' '$J/grok.md'"
mkjson '{"items":{"K1":"MISS","K2":"MISS"},"extras":["something else"],"unusable":false}'
check "a listed extra clears it"        "! judge_incoherent '$J/g.json' '$J/grok.md'"
# A review with no findings and a judge that found none agree. That is a clean
# no-defects run, not an incoherent one.
: > "$J/empty.md"; echo "Nothing to flag." >> "$J/empty.md"
mkjson '{"items":{"K1":"MISS"},"extras":[],"unusable":false}'
check "an honest no-defects run passes" "! judge_incoherent '$J/g.json' '$J/empty.md'"
check "counts numbered-bold findings"   "[ \$(review_findings '$J/codex.md') -ge 2 ]"

echo "== ★ the open track counts findings, and never derives one ratio =="
# The keyed score measures agreement with the one fix an author happened to ship.
# Measured on a real 1,842-line commit: a reviewer scored 0/2 on the key while
# stating five real defects, one of which the author later shipped a repair for.
# So the key is a FLOOR and this track measures the rest of the review.
. "$ROOT/lib/adjudicate.sh"
A=$(mktemp -d -p "$SANDBOX")
mkadj() { printf '%s' "$1" > "$A/a.json"; }
cnt() { jq -r "[.findings[]? | select($1)] | length" "$A/a.json"; }

mkadj '{"findings":[
 {"claim":"drops a write","verdict":"REAL","scope":"change","severity":"blocking"},
 {"claim":"stale badge","verdict":"REAL","scope":"change","severity":"nit"},
 {"claim":"repo has no tests","verdict":"REAL","scope":"repo","severity":"should-fix"},
 {"claim":"guard is missing","verdict":"FALSE","scope":null,"severity":null},
 {"claim":"could be cleaner","verdict":"UNFALSIFIABLE","scope":null,"severity":null}],
 "unusable":false}'
check "real-and-specific counted"    "[ \$(cnt '.verdict==\"REAL\" and .scope==\"change\"') -eq 2 ]"
# ★ A repo-wide finding must NOT land in the headline count. "there are no tests"
# is true, and every candidate can say it without reading the diff, so counting it
# as value inflates every agent equally and compresses the metric -- the same way
# a ceiling pass does.
check "repo-wide split out"          "[ \$(cnt '.verdict==\"REAL\" and .scope!=\"change\"') -eq 1 ]"
check "false counted"                "[ \$(cnt '.verdict==\"FALSE\"') -eq 1 ]"
check "unfalsifiable counted"        "[ \$(cnt '.verdict==\"UNFALSIFIABLE\"') -eq 1 ]"

# A malformed adjudicator reply must be UNUSABLE, not a silent zero. Three separate
# judge failure modes were measured in one day; a fourth model call gets the same
# distrust. Silence and "found nothing" are different facts.
printf 'I think the first one looks fine, honestly.' > "$A/prose.txt"
extract_json < "$A/prose.txt" > "$A/b.json" 2>/dev/null
check "unparseable reply is not JSON" "! jq -e '.findings' '$A/b.json' >/dev/null 2>&1"
mkadj "$ADJ_UNUSABLE"
check "the UNUSABLE shape parses"     "[ \$(jq -r '.unusable' '$A/a.json') = true ]"
check "and carries no findings"       "[ \$(cnt 'true') -eq 0 ]"

# A review with zero findings is a real result, not an error: nothing to adjudicate
# and nothing wrong with the run.
mkadj '{"findings":[],"unusable":false}'
check "no findings is not unusable"   "[ \$(jq -r '.unusable' '$A/a.json') = false ]"

# ★ A verdict nobody can re-check is worth nothing. Measured the hard way: the first
# real adjudication returned 23 real / 0 false and there was NO field to audit it
# with, because the prompt asked for citations and the schema had nowhere to put
# them. Counting evidence-less verdicts silently would have made an unauditable
# number look as solid as an audited one.
mkadj '{"findings":[
 {"claim":"a","verdict":"REAL","scope":"change","severity":"nit","evidence":"src/x.ts:12 does the thing"},
 {"claim":"b","verdict":"REAL","scope":"change","severity":"nit","evidence":""},
 {"claim":"c","verdict":"FALSE","scope":null,"severity":null}],"unusable":false}'
check "evidence-less verdicts counted" "[ \$(jq -r '[.findings[]?|select((.evidence // \"\")==\"\")]|length' '$A/a.json') -eq 2 ]"
check "evidence survives when given"   "jq -e '.findings[0].evidence' '$A/a.json' >/dev/null"

# ★ Two adjudicators over the same review must not collide. Keyed on the candidate
# alone, the second one finds the first one's file, SKIPS its own call, and reports
# the first one's verdicts under its own name -- model B's judgement filed under
# model A. It also silently blocks the only workflow that validates this track:
# run two adjudicators and compare. The adjudicator slug goes in the filename.
check "adj path carries the adjudicator" "grep -q 'by-\$asl.adj.json' '$ROOT/lib/adjudicate.sh'"
check "and still carries the candidate"  "grep -q '\$csl-run\$n.by-' '$ROOT/lib/adjudicate.sh'"

# ★ The SAME bug lived in the grade path and was worse there: `cadre grade` runs
# with rescore=1, which `rm -f`s the grade file before writing. So a second judge
# did not merely collide with the first one's grades -- it DELETED them, destroying
# the control group of the one experiment that can validate the keyed track. The
# report file had it too, so the second judge silently overwrote the first's report.
check "grade path carries the judge"   "grep -q 'by-\$jsl.grade.json' '$ROOT/lib/grade.sh'"
check "report carries the judge"       "grep -q 'report-\$sl-by-\$jsl.md' '$ROOT/lib/grade.sh'"
check "and still carries the candidate" "grep -q '\$sl-run\$n.by-' '$ROOT/lib/grade.sh'"
# Slug the FULL spec: `opencode:ollama/qwen3-judge` and `opencode:ollama/qwen3:14b`
# are both `opencode`, so two local judges would collide under one name.
check "judge slug is the full spec"    "grep -q 'jsl=\$(slug \"\$CADRE_JUDGE\")' '$ROOT/lib/grade.sh'"

# ★ An EXHAUSTED judge reported as "its reply did not parse" is a false statement
# about WHY, and it costs real time: measured, copilot returned a quota notice on
# all nine runs of a second-grader comparison and the report blamed its JSON, which
# sent the reader hunting for a wrapper bug in a working adapter. These are the
# VERBATIM provider strings observed on 2026-07-27, pinned so the scan cannot
# silently stop matching them.
QRAW="$SANDBOX/quota-raw"
printf 'You have exceeded your monthly quota (Request ID: A7C0:222700:5AC15B7)\n' > "$QRAW"
RL="bash -c \"source '$ROOT/lib/common.sh'; rate_limited '$QRAW'\""
check "copilot quota notice reads as limited" "$RL"
printf 'error: failed to run prompt: provider.rate_limit: 429 Your account org-f0b is suspended due to insufficient balance, please recharge your account\n' > "$QRAW"
check "kimi suspension reads as limited"      "$RL"
printf '{"items":{"K1":"HIT"},"extras":[]}\n' > "$QRAW"
check "a real grade does NOT read as limited" "! $RL"
check "grade reports outage, not bad JSON"    "grep -q 'RATE-LIMITED or OUT OF QUOTA' '$ROOT/lib/grade.sh'"

# ★ A grade with no traceability can only be arbitrated by a human re-reading the
# review, which is how this grading loop stopped being self-correcting. Measured:
# two graders split on one item in three over the same nine reviews, and the stored
# grades could not say whether they credited DIFFERENT sentences or read the SAME
# one two ways. The adjudicator prompt required evidence from `79b56ee`; the judge
# did not, and that gap is the root cause rather than judge quality.
check "judge prompt demands quotes"    "grep -q 'quotes' '$ROOT/lib/prompts/judge.md'"

# ★ The other half of the same lesson. A quote makes a split VISIBLE; a rule that
# names its mechanism stops the split happening. Two graders split on one item in
# three and every split turned on one unwritten question -- whether arguing a write
# is ungated by citing a guard ELSEWHERE earns credit. A grader swap cannot fix
# that: an underspecified rule produces a defensible split at any judge quality.
# ★ A rescore deleted the old grade and THEN made a call that can take minutes, so
# an interruption anywhere in that window destroyed a grade and produced nothing.
# Measured: an outer timeout killed a nine-run re-grade and three grades were simply
# gone. Grade to a side file and swap; a review can be re-graded but a baseline
# nobody kept cannot be recovered.
check "rescore grades to a side file"  "grep -q 'grade_one \"\$keyfile\" \"\$rf\" \"\$gf.new\"' '$ROOT/lib/grade.sh'"
check "and swaps only on success"      "grep -q 'mv -f \"\$gf.new\" \"\$gf\"' '$ROOT/lib/grade.sh'"
check "and no longer deletes upfront"  "! grep -q 'rm -f \"\$gf\" \"\$gf.judge-raw\"' '$ROOT/lib/grade.sh'"

# ★ agy is a GRADER, never a reviewer or adjudicator. Its two limits -- it refuses
# security-flavoured analysis, and headless it auto-denies its own tool permissions
# -- both bite jobs that read a checkout. Judging reads no checkout and asks for no
# vulnerability hunt, so it is exempt from both. That distinction only protects
# anyone if the adapter says so, because the failure is a REFUSAL filed as a result.
# ★★ ro must DENY, not merely pre-approve. `--allowedTools` allowlists without
# denying anything else, so the claude adapter's "read-only" mode was decorative:
# a candidate held `advisor` (a second, stronger model), `Agent`, and Bash/Edit/
# Write, used the advisor, and said so in its review. That voided every claude
# number in the corpus. grok had the same hole -- --always-approve in every mode.
# codex was the only adapter with a real sandbox. Pinned so ro cannot go hollow again.
check "claude ro denies by name"     "grep -q 'disallowedTools' '$ROOT/agents.d/claude.sh'"
check "claude ro drops operator MCP" "grep -q 'strict-mcp-config' '$ROOT/agents.d/claude.sh'"
# The advisor is NOT in the CLI's tool registry, so --disallowedTools cannot reach
# it; only blanking `advisorModel` does. Verified by probe: null still yields YES.
check "claude ro kills the advisor"  "grep -q 'advisorModel' '$ROOT/agents.d/claude.sh'"
check "claude denies the Agent tool" \
  "awk '/^CLAUDE_DENY=/{f=1} f{print; if(!/\\\\$/) exit}' '$ROOT/agents.d/claude.sh' | grep -qw Agent"
# ...and the deny list must NOT name the advisor. The CLI does not know the name,
# so it warns on STDERR, which run_claude merges into the review. That warning
# landed as line 1 of every claude review in a corpus run -- a contaminant no
# other candidate carried. Denying an unknown name is not defence in depth.
check "deny list omits the advisor" \
  "! awk '/^CLAUDE_DENY=/{f=1} f{print; if(!/\\\\\$/) exit}' '$ROOT/agents.d/claude.sh' \
     | grep -qw advisor"
# Scope to the INVOCATION. Two ways to get this wrong, both hit on the way here:
# `--disallowedTools` contains the substring `allowedTools`, and the adapter's
# notes quote `--allowedTools` by name to explain why it is unsafe. The question
# is only ever whether the flag is passed to the CLI.
check "claude no longer allowlists" \
  "! sed -n '/^run_claude/,/^}/p' '$ROOT/agents.d/claude.sh' | grep -q -- '--allowedTools'"
# ★ The regime is EXECUTION-ALLOWED, SECOND-MODELS-DENIED. The review prompt
# sanctions running targeted tests on every pass, and codex has always executed
# under its read-only sandbox, so denying bash to the other two would invert
# parity rather than restore it. What every candidate must lack is a second
# model: claude's advisor + Workflow, grok's subagents. codex exposes neither.
check "grok ro denies writes only"   "grep -q \"disallowed-tools 'edit,write'\" '$ROOT/agents.d/grok.sh'"
check "grok ro still allows bash" \
  "! grep -q \"disallowed-tools 'edit,write,bash'\" '$ROOT/agents.d/grok.sh'"
check "grok ro kills subagents"      "grep -q -- '--no-subagents' '$ROOT/agents.d/grok.sh'"
# grok runs the OPERATOR's Claude hooks (settings.json + settings.local.json)
# via its compat path. Measured: a PostToolUse hook fired 28 times inside a
# review. CLAUDE_CONFIG_DIR does not stop it; a HOME without .claude does.
check "grok isolates operator HOME"  "grep -q 'grok_sandbox_home' '$ROOT/agents.d/grok.sh'"
check "and keeps grok auth by link"  "grep -q 'ln -sfn \"\$HOME/.grok\"' '$ROOT/agents.d/grok.sh'"
check "and applies it to both calls" \
  "[ \"\$(grep -c 'HOME=\"\$sbh\"' '$ROOT/agents.d/grok.sh')\" -ge 2 ]"
check "claude ro kills Workflow" \
  "awk '/^CLAUDE_DENY=/{f=1} f{print; if(!/\\\\$/) exit}' '$ROOT/agents.d/claude.sh' | grep -qw Workflow"
check "claude ro still allows Bash" \
  "! awk '/^CLAUDE_DENY=/{f=1} f{print; if(!/\\\\$/) exit}' '$ROOT/agents.d/claude.sh' | grep -qw Bash"
check "grok ro is actually passed"   "[ \"\$(grep -c '\\\${ro\\[@\\]}' '$ROOT/agents.d/grok.sh')\" -ge 2 ]"

check "agy adapter exists"           "[ -f '$ROOT/agents.d/agy.sh' ]"
check "and defines its run function" "grep -q 'run_agy()' '$ROOT/agents.d/agy.sh'"
check "and refuses a model suffix"   "grep -q 'nomodel_agy()' '$ROOT/agents.d/agy.sh'"
check "and says GRADING ONLY"        "grep -q 'GRADING ONLY' '$ROOT/agents.d/agy.sh'"
check "and names the refusal limit"  "grep -qi 'refuses security' '$ROOT/agents.d/agy.sh'"

check "keygen demands a named mechanism"  "grep -q 'NAME the specific mechanism' '$ROOT/lib/prompts/keygen.md'"
check "and rules on the other-guard case" "grep -q 'DIFFERENT mechanism earns credit' '$ROOT/lib/prompts/keygen.md'"
check "and prefers artifacts to ideas"    "grep -q 'names an ARTIFACT' '$ROOT/lib/prompts/keygen.md'"
check "and says a MISS needs no quote" "grep -q 'for a MISS' '$ROOT/lib/prompts/judge.md'"
check "and refuses paraphrase"         "grep -q 'paraphrase' '$ROOT/lib/prompts/judge.md'"
check "and says no sentence means MISS" "grep -q 'cannot find a sentence' '$ROOT/lib/prompts/judge.md'"
check "grade prints the quote"         "grep -q 'q=\$(jq -r --arg k' '$ROOT/lib/grade.sh'"
check "and marks an unquoted HIT"      "grep -q 'credited with NO quote' '$ROOT/lib/grade.sh'"
# The extraction must survive a real payload, a missing quote, and the multi-line
# strings judges actually emit -- a raw newline in the report breaks the run's line.
QJ="$SANDBOX/q.json"
printf '%s' '{"items":{"K1":"HIT"},"quotes":{"K1":"the route\n  honors  neither guard"}}' > "$QJ"
check "quote is whitespace-collapsed" \
  "[ \"\$(jq -r '(.quotes.K1 // \"\") | gsub(\"\\\\s+\"; \" \")' '$QJ')\" = 'the route honors neither guard' ]"
printf '%s' '{"items":{"K1":"HIT"}}' > "$QJ"
check "a missing quotes block is empty, not null" \
  "[ -z \"\$(jq -r '(.quotes.K1 // \"\") | gsub(\"\\\\s+\"; \" \")' '$QJ')\" ]"
check "and says it is not about the candidate" "grep -q 'NOT a fact about the candidate' '$ROOT/lib/grade.sh'"

# The command must refuse rather than quietly reuse the judge. The judge only ever
# sees review text and a key; ruling on whether code contains a defect needs the repo.
OUT=$(CADRE_HOME="$SANDBOX/adjhome" CADRE_JUDGE=good CADRE_ADJUDICATOR= \
      "$ROOT/bin/cadre" adjudicate somecandidate 2>&1 || true)
check "refuses without an adjudicator" "grep -q 'CADRE_ADJUDICATOR' <<<\"\$OUT\""
check "and says why it is not the judge" "grep -q 'never sees\|never the repository' <<<\"\$OUT\""

echo "== ★ an empty shortlist must say WHICH filter emptied it =="
# Measured on a 1004-commit repo: all 200 fix-shaped commits died on the
# test-change filter, and `cadre setup` printed a bare header followed by
# "Pick a row where...". There were no rows. The tally goes to stderr so the
# TSV on stdout stays parseable.
mk_fix_repo() {  # mk_fix_repo <src-dir> <with-test 0|1>
  local s="$1" t="$2"
  printf 'function a(){return 1}\n' > "$s/lib.js"
  git -C "$s" add -A; git -C "$s" commit -qm "feat: add a"
  printf 'function a(){return 2}\n' > "$s/lib.js"
  if [ "$t" = 1 ]; then mkdir -p "$s/test"; printf 'a()\n' > "$s/test/lib.test.js"; fi
  git -C "$s" add -A; git -C "$s" commit -qm "fix: a returned the wrong value"
}

D=$(case_dir miner_notest); S="$D/src"
mk_fix_repo "$S" 0
OUT=$(run_cadre "$D" setup "$S" 20)
check "the tally names the test filter"   "grep -q 'the fix changed no test file' <<<\"\$OUT\""
check "it says nothing survived"          "grep -q 'NOTHING SURVIVED' <<<\"\$OUT\""
check "it points at make-pass instead"    "grep -q 'cadre make-pass <label> <repo-dir>' <<<\"\$OUT\""
check "it does NOT say to pick a row"     "! grep -qi 'pick a row' <<<\"\$OUT\""

D=$(case_dir miner_withtest); S="$D/src"
mk_fix_repo "$S" 1
OUT=$(run_cadre "$D" setup "$S" 20)
check "a qualifying pair is kept"         "grep -q 'kept 1 of' <<<\"\$OUT\""
check "and the next step is offered"      "grep -q 'Pick a row' <<<\"\$OUT\""
check "the tally stays OUT of the tsv"    "! grep -q 'Dropped:' '$D/state/shortlist-src.tsv'"
check "the tsv has a header and one row"  "[ \$(wc -l < '$D/state/shortlist-src.tsv') -eq 2 ]"

echo "== ★ the preflight must not refuse a repo over a folder name or a config file =="
# Both of these were live and both refused a whole real repo on its first run.
# `-name 'credentials'` with no -type f matched the Next.js route DIRECTORY
# src/app/.../credentials/, and `.npmrc` was matched on filename alone -- so
# `package-lock=false`, the most common .npmrc there is, failed every Node repo.
P=$(mktemp -d)
mkdir -p "$P/src/app/integrations/credentials"
echo 'export default 1' > "$P/src/app/integrations/credentials/page.tsx"
echo 'package-lock=false' > "$P/.npmrc"
OUT=$(bash -c "source '$ROOT/lib/common.sh'; secrets_preflight '$P'" 2>&1); RC=$?
check "benign .npmrc + credentials/ dir accepted" "[ $RC -eq 0 ]"
check "and it says nothing at all"                "[ -z \"\$OUT\" ]"

printf '//registry.npmjs.org/:_authToken=abc123\n' > "$P/.npmrc"
OUT=$(bash -c "source '$ROOT/lib/common.sh'; secrets_preflight '$P'" 2>&1); RC=$?
check "an .npmrc carrying a token IS refused"     "[ $RC -eq 3 ]"
check "and it names the file"                     "grep -q '.npmrc' <<<\"\$OUT\""

P2=$(mktemp -d); echo 'API_TOKEN=x' > "$P2/.env"
OUT=$(bash -c "source '$ROOT/lib/common.sh'; secrets_preflight '$P2'" 2>&1); RC=$?
check "a .env is still refused on the name alone" "[ $RC -eq 3 ]"
rm -rf "$P" "$P2"

echo "== ★ CADRE_HOME inside or EQUAL TO the reviewed repo is refused =="
D=$(case_dir nested_home); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
mkdir -p "$S/.cadre/keys"; echo "K1 the answer" > "$S/.cadre/keys/secret.md"
OUT=$(CADRE_HOME="$S/.cadre" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      PATH="$D/bin:$PATH" "$ROOT/bin/cadre" review --roster good --base main "$S" 2>&1)
check "nested CADRE_HOME refused"     "grep -q 'sits inside it' <<<\"\$OUT\""
# ★ is_inside returns false for identical paths, so exact equality needs its own
# test: CADRE_HOME="$repo" used to sail through and copy state into the checkout.
OUT=$(CADRE_HOME="$S" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      PATH="$D/bin:$PATH" "$ROOT/bin/cadre" review --roster good --base main "$S" 2>&1)
check "CADRE_HOME == repo refused"    "grep -q 'sits inside it' <<<\"\$OUT\""
OUT=$(CADRE_HOME="$D/state" CADRE_WORK="$S" CADRE_AGENTS_D="$D/agents.d" \
      PATH="$D/bin:$PATH" "$ROOT/bin/cadre" review --roster good --base main "$S" 2>&1)
check "CADRE_WORK == repo refused"    "grep -q 'sits inside it' <<<\"\$OUT\""

echo "== ★ sha256 source repo =="
if git init -q --object-format=sha256 "$SANDBOX/fmtprobe" 2>/dev/null; then
  D=$(case_dir sha256); rm -rf "$D/src"
  git init -q --object-format=sha256 "$D/src"; S="$D/src"
  git -C "$S" config user.email t@example.com; git -C "$S" config user.name t
  echo orig > "$S/app.js"; git -C "$S" add -A; git -C "$S" commit -qm base
  git -C "$S" branch -M main; git -C "$S" checkout -qb feature
  echo x >> "$S/app.js"; git -C "$S" commit -qam f; echo dirty >> "$S/app.js"
  OUT=$(run_cadre "$D" review --roster good --base main "$S")
  check "sha256 repo reviews cleanly" "grep -q '1 ok' <<<\"\$OUT\""
else
  echo "  skip sha256 (this git does not support it)"
fi

echo "== ★ manifest survives a source gc =="
D=$(case_dir gc_manifest); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
echo dirty >> "$S/app.js"; echo new > "$S/extra.js"
OUT=$(run_cadre "$D" review --roster good --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
BT=$(grep '^base-tree:' "$R/manifest.txt" | awk '{print $2}')
RT=$(grep '^reviewed-tree:' "$R/manifest.txt" | awk '{print $2}')
check "manifest records both trees"  "[ -n '$BT' ] && [ -n '$RT' ] && [ '$RT' != unknown ]"
check "base tree survives a gc"      "git -C '$S' reflog expire --expire=now --all >/dev/null 2>&1; git -C '$S' gc --prune=now -q >/dev/null 2>&1; git -C '$S' cat-file -e '$BT^{tree}' 2>/dev/null"

echo "== default base resolution =="
# Every other case passes --base. This is the path a real user hits first.
D=$(case_dir defaultbase); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good "$S")
check "falls back to main with no origin" "grep -q 'base: main' <<<\"\$OUT\""
check "and completes the run"             "grep -q '1 ok' <<<\"\$OUT\""

echo "== ★ deterministic pre-pass (--prerun) =="
# No --prerun: the placeholder must not survive into a reviewer's brief.
D=$(case_dir prerun_off); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "no leftover placeholder"      "! grep -q 'TEST_RESULT' '$R/prompt.txt'"
check "no prerun line in manifest"   "! grep -q '^prerun:' '$R/manifest.txt'"

# Passing command: the transcript reaches the prompt and the manifest.
D=$(case_dir prerun_pass); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main --prerun 'echo all green' "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "prerun transcript written"    "[ -s '$R/prerun.md' ]"
check "exit 0 in the brief"          "grep -q 'exit 0' '$R/prompt.txt'"
check "output in the brief"          "grep -q 'all green' '$R/prompt.txt'"
check "manifest records the command" "grep -q '^prerun: *exit 0 | echo all green' '$R/manifest.txt'"

# ★ Failing command: reviewers must be told the suite is RED. The whole point
# of the pre-pass is the case where the deterministic signal disagrees with a
# panel that would otherwise call the change clean.
D=$(case_dir prerun_fail); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main --prerun 'echo boom; exit 3' "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "non-zero exit in the brief"   "grep -q 'exit 3' '$R/prompt.txt'"
check "failure output carried"       "grep -q 'boom' '$R/prompt.txt'"
check "run still completed"          "grep -q '1 ok' <<<\"\$OUT\""
check "warned on the console"        "grep -q 'pre-pass exit 3' <<<\"\$OUT\""

# ★ An & in test output. awk's gsub reads & in the replacement as "the matched
# text", so splicing this with gsub would silently corrupt the transcript.
D=$(case_dir prerun_amp); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main --prerun 'echo "a && b"' "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "ampersand output intact"      "grep -qF 'a && b' '$R/prompt.txt'"

# ★ The pre-pass is arbitrary code next to the answer keys. It gets the same
# environment scrub the reviewers get, or a build script that dumps its env
# writes CADRE_HOME into a transcript handed to the whole panel.
D=$(case_dir prerun_env); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main \
        --prerun 'echo "HOME_IS:[${CADRE_HOME:-unset}] WORK_IS:[${CADRE_WORK:-unset}]"' "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "CADRE_HOME scrubbed from prerun" "grep -q 'HOME_IS:\[unset\]' '$R/prompt.txt'"
check "CADRE_WORK scrubbed from prerun" "grep -q 'WORK_IS:\[unset\]' '$R/prompt.txt'"

# A multi-line command must not split the manifest into bogus rows.
D=$(case_dir prerun_multiline); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main --prerun 'echo one
echo two' "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "manifest stays one line per field" "[ \$(wc -l < '$R/manifest.txt') -eq \$(grep -c ':' '$R/manifest.txt') ]"

# ★ A command that cannot run is a refusal, not a finding. Feeding the panel
# "exit 127" as though it were a test result is worse than not measuring.
D=$(case_dir prerun_bad); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main --prerun 'no-such-command-xyz' "$S")
check "unrunnable prerun refuses"    "grep -q 'could not be executed' <<<\"\$OUT\""
check "and produced no review"       "[ -z \"\$(ls -A '$D/state/reviews' 2>/dev/null)\" ]"

# ★ The pre-pass runs in a THROWAWAY copy. Artifacts it drops must not reach a
# reviewer, or every panel diffs a tree that has been built in.
D=$(case_dir prerun_clean); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main --prerun 'echo art > build-artifact.txt' "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
G=$(ls "$R"/good-*.md 2>/dev/null | head -1)
check "artifact not in the checkout" "! grep -q 'build-artifact' '$G'"
check "artifact not in source repo"  "[ ! -e '$S/build-artifact.txt' ]"
check "work dir still cleaned"       "[ -z \"\$(ls -A '$D/work')\" ]"

echo "== ★ install-aware adapter listing =="
# An adapter ships for every CLI cadre knows about. Unmarked, the list reads as
# a wall of caveats about tools you do not have.
D=$(case_dir installed)
printf 'run_phantom() { echo x; }\n' > "$D/agents.d/phantom.sh"   # adapter, no binary
LIST=$(CADRE_HOME="$D/state" CADRE_AGENTS_D="$D/agents.d" PATH="$D/bin:$PATH" "$ROOT/bin/agentcall" --list)
INST=$(CADRE_HOME="$D/state" CADRE_AGENTS_D="$D/agents.d" PATH="$D/bin:$PATH" "$ROOT/bin/agentcall" --installed)
check "installed adapter marked"   "grep -q '^✓ good ' <<<\"\$LIST\""
check "absent adapter marked"      "grep -q '^· phantom' <<<\"\$LIST\""
check "--installed lists good"     "grep -qx good <<<\"\$INST\""
check "--installed omits phantom"  "! grep -qx phantom <<<\"\$INST\""
# The mark is its own field: printf pads by BYTES and ✓ is three of them, so
# folding it into the name column shifts installed rows against the rule.
check "columns still line up"      "[ \$(grep -c '^. [a-z0-9]* *(no notes)' <<<\"\$LIST\") -ge 1 ]"

echo "== ★ a judge may be an adapter that is not named after its binary =="
# cursor's adapter runs `agent`, kiro's runs `kiro-cli`. need_judge tested the
# ADAPTER name with command -v, so CADRE_JUDGE=cursor died as "not installed"
# while `agent` sat on the user's PATH -- a failure that names a tool they can
# see. Found by cursor:composer-2.5 reviewing the commit that fixed the same
# bug at two OTHER call sites. There is one copy of the check now.
printf 'bin_renamed() { echo good; }\nrun_renamed() { echo x; }\n' > "$D/agents.d/renamed.sh"
INST=$(CADRE_HOME="$D/state" CADRE_AGENTS_D="$D/agents.d" PATH="$D/bin:$PATH" "$ROOT/bin/agentcall" --installed)
check "--installed follows bin_ override" "grep -qx renamed <<<\"\$INST\""
jrun() {
  CADRE_HOME="$D/state" CADRE_AGENTS_D="$D/agents.d" PATH="$D/bin:$PATH" \
    CADRE_JUDGE="$1" "$ROOT/bin/cadre" grade nosuchagent 2>&1
}
OUT=$(jrun renamed);       check "renamed judge accepted"   "! grep -q 'not installed' <<<\"\$OUT\""
OUT=$(jrun renamed:a/b);   check "and with a model attached" "! grep -q 'not installed' <<<\"\$OUT\""
# The check still has to REJECT, or it is not a check.
OUT=$(jrun phantom);       check "adapter with no binary rejected" "grep -q \"'phantom' is not installed\" <<<\"\$OUT\""
OUT=$(jrun nosuchjudge);   check "unknown judge rejected"    "grep -q 'not installed' <<<\"\$OUT\""

echo "== ★ no roster names what you actually have =="
# 'cadre panel --save' needs graded passes. Sending a first-time user there is
# sending them down the one path that is closed to them.
D=$(case_dir noroster); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --base main "$S" || true)
check "suggests a runnable command" "grep -q 'cadre review --roster' <<<\"\$OUT\""
check "names an installed adapter"  "grep -q 'good' <<<\"\$OUT\""
check "still mentions panel --save" "grep -q 'panel --save' <<<\"\$OUT\""

# With nothing installed there is nothing to suggest, so say that instead.
D=$(case_dir noagents); S="$D/src"
rm -f "$D"/bin/*
OUT=$(CADRE_HOME="$D/state" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      PATH="$D/bin:/usr/bin:/bin" "$ROOT/bin/cadre" review --base main "$S" 2>&1 || true)
check "empty box says so"           "grep -q 'none of cadre.s adapters' <<<\"\$OUT\""

echo "== ★ one-reviewer nudge (data, not a warning) =="
D=$(case_dir nudge)
# Everything except `good`, by exclusion rather than by name: this listed the
# stubs to delete, so adding a stub anywhere else in this file silently gave the
# case two reviewers and the nudge stopped firing.
find "$D/bin" -type f ! -name good -delete
find "$D/agents.d" -type f ! -name good.sh -delete
OUT=$(env -i PATH="$D/bin:/usr/bin:/bin" CADRE_HOME="$D/state" CADRE_WORK="$D/work" \
        CADRE_AGENTS_D="$D/agents.d" "$ROOT/bin/cadre" doctor 2>&1); RC=$?
check "nudge shown at one reviewer" "grep -q 'one reviewer installed' <<<\"\$OUT\""
check "nudge carries the numbers"   "grep -q '47% at one' <<<\"\$OUT\""
check "doctor still exits 0"        "[ $RC -eq 0 ]"
# Two installed reviewers is a panel; do not nag.
D=$(case_dir nonudge)
rm -f "$D/bin/trunc" "$D/agents.d/trunc.sh"
OUT=$(env -i PATH="$D/bin:/usr/bin:/bin" CADRE_HOME="$D/state" CADRE_WORK="$D/work" \
        CADRE_AGENTS_D="$D/agents.d" "$ROOT/bin/cadre" doctor 2>&1)
check "no nudge at two reviewers"   "! grep -q 'one reviewer installed' <<<\"\$OUT\""

echo "== ★ onboard prints, and never handles a key =="
D=$(case_dir onboard)
ON=$(CADRE_HOME="$D/state" CADRE_AGENTS_D="$D/agents.d" PATH="$D/bin:/usr/bin:/bin" \
       "$ROOT/bin/cadre" onboard 2>&1)
BR=$(CADRE_HOME="$D/state" CADRE_AGENTS_D="$D/agents.d" PATH="$D/bin:/usr/bin:/bin" \
       "$ROOT/bin/cadre" onboard --brief 2>&1)
check "onboard names what you have"  "grep -q 'You have installed: .*good' <<<\"\$ON\""
check "onboard points at the doc"    "grep -q 'FREE-PANEL.md' <<<\"\$ON\""
# opencode is absent from this PATH, and two of the three routes need it.
check "warns opencode is missing"    "grep -q 'opencode is not installed' <<<\"\$ON\""
# ★ The brief must tell the agent to use a PLACEHOLDER. An onboarding flow that
# has an agent handle the real key is a credential path wearing a helper's coat.
check "brief demands a placeholder"  "grep -qF '{env:PROVIDER_API_KEY}' <<<\"\$BR\""
check "brief forbids asking for it"  "grep -q 'Do NOT ask me for the key' <<<\"\$BR\""
check "brief warns off repo .env"    "grep -q \"repo's .env\" <<<\"\$BR\""
check "onboard rejects bad options"  "! CADRE_HOME='$D/state' '$ROOT/bin/cadre' onboard --nope >/dev/null 2>&1"
# It prints and exits. Writing config or touching a key is the one thing it
# must never do, so no run of it may create anything under the user's config.
check "onboard wrote nothing"        "[ ! -e '$D/state/reviews' ]"

echo "== ★ a CLI's own chrome is not a review =="
# Measured with opencode, the free route the README sends people to first: it
# wraps the model's text in colour escapes and a banner, so a run that returned
# NOTHING still leaves a non-empty file and scored as a reviewer that looked and
# found no defects. Emptiness has to mean empty of content, not of bytes.
D=$(case_dir chrome_only); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster chrome,terse --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "chrome-only run -> FAILED"      "ls '$R'/chrome-*.md.failed >/dev/null 2>&1"
check "chrome-only is not a review"    "! ls '$R'/chrome-*.md >/dev/null 2>&1"
# ★ The other half. A length floor would catch the banner AND this, and the
# repo already threw away valid "findings=0" reviews that way once.
check "a terse review still counts"    "ls '$R'/terse-*.md >/dev/null 2>&1"
check "counts split them correctly"    "grep -q '1 ok, 0 degraded, 1 failed' <<<\"\$OUT\""

echo "== ★ chrome-stripping must not eat the review itself =="
# Found by a codex-led panel on cadre's own diff: `/^> build /d` was written to
# drop opencode's banner and also deleted a reviewer's markdown blockquote that
# happened to start with the word build. Silent loss of review content is worse
# than the chrome it was removing.
ESC=$(printf '\033')
STRIP="sed -e 's/${ESC}\[[0-9;?]*[a-zA-Z]//g' -e '1,5{' -e '/^> build · /d' -e '}'"
BQ='> build the release pipeline silently fails'
check "a '> build ...' quote survives" "[ \"\$(printf '%s\n' '$BQ' | $STRIP)\" = '$BQ' ]"
check "the real banner still goes"     "[ -z \"\$(printf '> build · m\n' | $STRIP | tr -d '[:space:]')\" ]"
# ★ Anchored to the first lines too: the banner cannot appear deep in a review,
# but a quoted example of one can.
check "a late banner-lookalike stays"  "[ -n \"\$(printf 'a\nb\nc\nd\ne\nf\n> build · m\n' | $STRIP | grep '^> build')\" ]"

echo "== ★ no GNU-only sed escapes =="
# Found by a panel reviewer: `\x1b` is a GNU sed extension. BSD sed (macOS)
# reads it as a literal `x1b`, matches nothing, and every strip built on it
# silently no-ops -- so the chrome-only run above is filed as a clean review
# again, on a whole platform, with no error raised. A silent no-op is the worst
# available failure, so this bans the construct rather than trusting a comment.
# Comment lines are exempt: the comments explaining this ban say `\x1b`, and the
# first version of this check failed on them.
check "no \\x1b in shipped code" \
  "! grep -rn 'x1b' $ROOT/bin $ROOT/lib $ROOT/agents.d | grep -qvE ':[[:space:]]*#'"

echo "== ★ the prompt must name the delimiters the harness actually emits =="
# A remediation commit renamed the partial delimiter in bin/cadre and left
# lib/prompts/synthesize.md teaching the old string, so the static rule no
# longer bound to anything in the body. The suite asserted the emitted string
# and the prompt's text separately, and neither noticed they had stopped
# matching. Assert the SAME literal against both, so a rename must touch both.
P_PARTIAL='===== REVIEWER (PARTIAL, THIS REVIEWER STOPPED EARLY):'
P_CAPPED='===== REVIEWER (COMPLETE, BUT CADRE SENT ONLY ITS FIRST'
check "harness emits the partial delimiter" "grep -qF '$P_PARTIAL' $ROOT/bin/cadre"
check "prompt teaches the partial delimiter" "grep -qF '$P_PARTIAL' $ROOT/lib/prompts/synthesize.md"
check "harness emits the capped delimiter"  "grep -qF '$P_CAPPED' $ROOT/bin/cadre"
check "prompt teaches the capped delimiter" "grep -qF '$P_CAPPED' $ROOT/lib/prompts/synthesize.md"

echo "== ★ a retry must not destroy the partial it is retrying =="
# Also from the codex panel, and a regression introduced the same day: the
# benchmark path deleted the previous .partial BEFORE the replacement attempt,
# so a retry that produced nothing took the only copy of real findings with it.
#
# ⚠ STRUCTURAL, not behavioural. Reaching this at runtime needs a registered
# pass with a corrected answer key, which is a model-built fixture and does not
# belong in a suite that runs in seconds. So this asserts the shape of the code
# instead, which is weaker than a real run: it would not catch a third place
# that deletes the file. It exists to stop this exact line coming back.
PRE=$(sed -n '/^    rm -f "\$f/p' "$ROOT/lib/run-pass.sh")
check "pre-attempt rm spares .partial" "! grep -q 'f.partial' <<<\"\$PRE\""
check "pre-attempt rm still clears .failed" "grep -q 'f.failed' <<<\"\$PRE\""
check "success clears the stale .partial" \
  "grep -A3 '^      ok)' '$ROOT/lib/run-pass.sh' | grep -q 'rm -f \"\$f.partial\"'"

echo "== ★ a partial reviewer must not corrupt the agreement math =="
# The synthesizer is told the counts. If a partial review arrives under the same
# delimiter as a complete one, tagging a finding [1/3] reads as two dissents when
# really it is one reviewer and two absences. `echoer` replays the prompt it was
# handed, so these assert on what the synthesizer was TOLD, not on a stub's answer.
D=$(case_dir synth_partial); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good,good2,trunc,dead --synth echoer --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
P="$R/synthesis.md"
check "synthesis ran with a partial"   "[ -s '$P' ]"
check "partial gets its OWN delimiter" "grep -q 'PARTIAL, THIS REVIEWER STOPPED EARLY): trunc' '$P'"
check "complete reviews stay plain"    "grep -qE '^===== REVIEWER: good =====' '$P'"
check "partial text still delivered"   "grep -q 'partial finding' '$P'"
check "unraised = neither side"          "grep -q 'counts in NEITHER' '$P'"
check "and never a Disagreement"         "grep -q 'under Disagreements' '$P'"
check "dead reviewer still declared"   "grep -q 'FAILED, NO REVIEW: dead' '$P'"
check "panel size stated for dead"     "grep -q 'panel was 4 reviewers' '$P'"
check "dead kept OUT of the tags"      "grep -q 'out of every agreement tag' '$P'"
check "raised-by-partial counts BOTH"  "grep -q 'numerator and the' '$P'"
check "one counting rule, no conflict" "! grep -q 'not out of' '$P'"
check "run line counts the partial"    "grep -q '3 review(s) (2 full, 1 partial)' <<<\"\$OUT\""

# ★ Over the byte cap, `head -c` MAKES a review partial: it goes silent about
# everything past the cut for the same reason a truncated one does. Re-labelled,
# or the rule above skips the very reviews this code truncated.
OUT=$(CADRE_SYNTH_MAX=100 run_cadre "$D" review --roster good,good2 --synth echoer \
        --base main --label capped "$S")
P="$D/state/reviews/capped/synthesis.md"
check "cap truncation is announced"    "grep -q 'over CADRE_SYNTH_MAX' <<<\"\$OUT\""
check "a cut review says CADRE cut it"  "grep -q 'BUT CADRE SENT ONLY ITS FIRST' '$P'"
check "and is NOT called stopped-early" "! grep -q 'STOPPED EARLY): good' '$P'"
check "and the silence rule travels"   "grep -q 'counts in NEITHER' '$P'"
# ★ Every survivor capped is the case that exposed the two meanings of $n: the
# console counted only reviews sent whole, so it announced "synthesizing 0
# review(s)" and then synthesized two. Found by a grok-led panel.
check "never announces 0 while merging" "! grep -q 'synthesizing 0 review' <<<\"\$OUT\""
check "capped counted in the run line"  "grep -q '2 review(s) (0 full, 2 sent short)' <<<\"\$OUT\""

# ★ The same count in prose, where it is handed to the MODEL rather than the
# reader: a capped reviewer did return a complete review, cadre just sent part
# of it. Needs a dead reviewer present, since that is the block carrying the
# sentence, and a capped one, since $n and the completed count only diverge
# when something was cut.
OUT=$(CADRE_SYNTH_MAX=100 run_cadre "$D" review --roster good,good2,dead --synth echoer \
        --base main --label capdead "$S")
P="$D/state/reviews/capdead/synthesis.md"
check "capped counted as completed"    "grep -q 'of whom 2' '$P'"
check "and the dead one is not"        "grep -q 'panel was 3 reviewers' '$P'"

# ★ The adapter's own verdict outranks anything cadre infers from the text. A
# short partial that merely DISCUSSES rate limiting matched rate_limited() and
# was binned `failed`, findings and all, because that keyword check ran before
# the truncation marker. Found by a grok-led panel, on a diff where reviewing
# cadre's own 429 handling is what produces the shape.
OUT=$(run_cadre "$D" review --roster ratepart,good --synth none \
        --base main --label ratepart "$S")
R="$D/state/reviews/ratepart"
check "rate-limit TALK is not a failure" "! ls '$R'/ratepart-*.md.failed >/dev/null 2>&1"
check "it is degraded, findings kept"    "grep -q 'retries forever' '$R'/ratepart-*.md.partial"

# ★ A REAL rate limit must still give up loudly -- and say so in the documented
# contract shape at the TOP of the file, not appended under whatever the adapter
# printed. The note used to go at the end, which is exactly where it displaced a
# tail-anchored marker.
OUT=$(CADRE_RETRIES=1 run_cadre "$D" review --roster ratelim,good --synth none \
        --base main --label ratelim "$S")
R="$D/state/reviews/ratelim"
check "a real rate limit still fails"   "ls '$R'/ratelim-*.md.failed >/dev/null 2>&1"
check "give-up note leads the file"     "head -1 '$R'/ratelim-*.md.failed | grep -q '^DID NOT COMPLETE, rate limited'"
check "and the error text is kept"      "grep -q '429 too many requests' '$R'/ratelim-*.md.failed"

echo "== ★ a synthesis QUOTING a marker is not a truncated synthesis =="
# The synthesis prompt asks the model to report which reviewers were cut off, so
# a correct merge can legitimately END by quoting a _TRUNCATED line -- the exact
# window a tail-anchored text check inspects. No window fixes that: the check
# must both catch a real truncated merge and ignore a quoted one, and the bytes
# are identical. So the marker is not read here at all; the EXIT STATUS is.
# These two stubs print the SAME text and differ only in what they return.
OUT=$(run_cadre "$D" review --roster good,good2 --synth synthquote \
        --base main --label sq "$S")
check "quoted marker survives"        "[ -s '$D/state/reviews/sq/synthesis.md' ]"
check "and is not filed as failed"    "[ ! -e '$D/state/reviews/sq/synthesis.md.failed' ]"
# ★ A healthy SHORT merge that discusses rate limiting. Two of the three retry
# loops were taught to stop trusting the keyword scan; this one was left, so a
# merge like this burned three retries of the synthesizer's quota and was then
# filed failed with a healthy panel underneath it. Merging reviews of THIS repo
# is what produces the text.
OUT=$(run_cadre "$D" review --roster good,good2 --synth synthrate \
        --base main --label sr "$S")
check "rate-limit TALK in a merge is ok" "[ -s '$D/state/reviews/sr/synthesis.md' ]"
check "and burns no retries"             "! grep -q 'synthesis rate limited' <<<\"\$OUT\""
OUT=$(run_cadre "$D" review --roster good,good2 --synth synthtrunc \
        --base main --label st "$S")
check "same text, nonzero -> failed"  "[ -s '$D/state/reviews/st/synthesis.md.failed' ]"
check "and no synthesis was saved"    "[ ! -e '$D/state/reviews/st/synthesis.md' ]"
check "the reviews survive it"        "ls '$D/state/reviews/st'/good-*.md >/dev/null 2>&1"
# ★ PINNING a deliberate choice, not describing an accident. Under 500 bytes the
# keyword scan IS believed even at exit 0, because some CLIs answer a refusal on
# stdout and still exit clean -- that is the whole reason rate_limited() exists
# on the review path, and kiro has since been caught reporting a quota failure as
# an unrelated tool-approval error, so "the CLI told the truth about why it
# stopped" is not a safe assumption. The floor is where the two risks cross: a
# real merge clears 500 bytes without trying (synthrate needs 60 padding lines to
# do it), while a refusal is one sentence. Fail closed, and loudly -- the reviews
# are still on disk. Change the number here and you are choosing which way a
# refusal-shaped merge goes; do not "clean this up".
cat > "$D/agents.d/synthtiny.sh" <<'A'
run_synthtiny() { echo "429 too many requests"; }
A
OUT=$(run_cadre "$D" review --roster good,good2 --synth synthtiny \
        --base main --label sy "$S")
check "sub-500 refusal shape -> failed" "[ -s '$D/state/reviews/sy/synthesis.md.failed' ]"
check "no synthesis saved for it"       "[ ! -e '$D/state/reviews/sy/synthesis.md' ]"
check "the reviews still survive"       "ls '$D/state/reviews/sy'/good-*.md >/dev/null 2>&1"

echo "== ★ kiro's parting error blames the wrong thing =="
# Measured live, both seats of a 4-reviewer panel. Kiro died for two DIFFERENT
# real reasons and signed off with the same wrong one, as the final line of a
# 50KB transcript -- so the last thing a human reads is an accusation that the
# adapter forgot a flag it demonstrably passes. Not hypothetical: it cost a
# diagnosis. The annotation has to keep the real cause and kill the false one.
K=$(case_dir kiroerr)
mkdir -p "$K/bin"
cat > "$K/bin/kiro-cli" <<'A'
#!/bin/sh
printf '\033[?25hAll tools are now trusted (--trust-all-tools)\n'
printf 'Findings: nothing blocking in the diff.\n'
printf ' \342\226\270 Credits: 3 Time: 4s\n'
printf '\n \342\232\240\357\270\217  Kiro rate limit reached:\n    Request quota exceeded.\n'
printf 'error: Tool approval required but --no-interactive was specified. Use --trust-all-tools to automatically approve tools.\n'
exit 1
A
chmod +x "$K/bin/kiro-cli"
OUT=$(PATH="$K/bin:$PATH" "$ROOT/bin/agentcall" kiro -d /tmp -m ro 'review' 2>&1)
check "the false cause is gone"      "! grep -q '^error: Tool approval required' <<<\"\$OUT\""
check "and is replaced, not dropped" "grep -q 'never the cause' <<<\"\$OUT\""
check "the REAL cause survives"      "grep -q 'Request quota exceeded' <<<\"\$OUT\""
check "the review text survives"     "grep -q 'nothing blocking in the diff' <<<\"\$OUT\""
check "trust banner still stripped"  "! grep -q 'All tools are now trusted' <<<\"\$OUT\""
check "credits footer still stripped" "! grep -q 'Credits:' <<<\"\$OUT\""
check "private-mode escape stripped" "! grep -q '25h' <<<\"\$OUT\""

echo "== ★ pi: silent success is the worst failure =="
# Measured on a real panel seat: openai/gpt-oss-120b ended its turn with a
# `thinking` part and no `text` part, so pi printed nothing and exited 0 -- and
# the seat landed as a 0-byte .failed with no cause written in it. classify_run
# caught the emptiness, but a human opening that file learns nothing. The
# adapter has to name what happened. Nonzero too: returning 0 with no output is
# indistinguishable from a reviewer that looked and found no defects.
PD=$(case_dir pisilent)
printf '#!/bin/sh\nexit 0\n' > "$PD/bin/pi"; chmod +x "$PD/bin/pi"
cp "$ROOT/agents.d/pi.sh" "$PD/agents.d/"
OUT=$(CADRE_AGENTS_D="$PD/agents.d" PATH="$PD/bin:$PATH" \
      "$ROOT/bin/agentcall" pi -d /tmp -m ro -M openrouter/openai/gpt-oss-120b 'review' 2>&1); RC=$?
check "silent pi is not a clean pass" "[ $RC -ne 0 ]"
check "and says it did not complete"  "grep -q '^DID NOT COMPLETE' <<<\"\$OUT\""
check "it names the reasoning cause"  "grep -q 'reasoning and no text part' <<<\"\$OUT\""
check "and names the model"           "grep -q 'openrouter/openai/gpt-oss-120b' <<<\"\$OUT\""
# A model that DOES emit text must pass through untouched, exit code included.
printf '#!/bin/sh\necho "REVIEW: one finding."\nexit 0\n' > "$PD/bin/pi"
OUT=$(CADRE_AGENTS_D="$PD/agents.d" PATH="$PD/bin:$PATH" \
      "$ROOT/bin/agentcall" pi -d /tmp -m ro 'review' 2>&1); RC=$?
check "a talking pi passes through"   "grep -q 'REVIEW: one finding' <<<\"\$OUT\""
check "and keeps its exit code"       "[ $RC -eq 0 ]"
# A REAL failure keeps its nonzero status rather than being masked as empty.
printf '#!/bin/sh\necho "400: model not found"\nexit 1\n' > "$PD/bin/pi"
OUT=$(CADRE_AGENTS_D="$PD/agents.d" PATH="$PD/bin:$PATH" \
      "$ROOT/bin/agentcall" pi -d /tmp -m ro 'review' 2>&1); RC=$?
check "a real error stays nonzero"    "[ $RC -ne 0 ]"
check "and keeps the provider text"   "grep -q '400: model not found' <<<\"\$OUT\""

echo "== ★ the run dataset =="
# ★ The record has to be written BEFORE the scratch files it is built from are
# deleted. It was not, for fourteen panels: status and timing lived only in
# .status-*/.log-*, both removed when the panel finished, so the moment a run
# ended the only surviving record of which reviewer failed and how long each
# took was the terminal scrollback. Those timings are gone and cannot be
# recovered -- the artifacts carry neither.
D=$(case_dir dataset); S="$D/src"
git -C "$S" checkout -qb feature
echo committed >> "$S/app.js"; git -C "$S" commit -qam feat
OUT=$(run_cadre "$D" review --roster good,dead --synth none \
        --base main --label ds1 "$S")
R="$D/state/reviews/ds1"
check "slots.tsv is written"        "[ -s '$R/slots.tsv' ]"
check "it survives the cleanup"     "[ ! -e '$R/.status-good' ]"
check "one row per roster seat"     "[ \$(wc -l < '$R/slots.tsv') -eq 2 ]"
check "a good seat is ok"           "grep -qP '\tgood\t.*\tok\t' '$R/slots.tsv'"
check "a dead seat is failed"       "grep -qP '\tdead\t.*\tfailed\t' '$R/slots.tsv'"
check "timing is captured live"     "grep -qP '\tok\t[0-9]+\t[0-9]+\$' '$R/slots.tsv'"
# ★ A seat that produced NO artifact must still appear. Deriving rows from
# filenames instead of the roster would silently drop exactly the failure worth
# counting -- the panel would report three seats and the dataset two.
check "no seat vanishes"            "[ \$(cut -f2 '$R/slots.tsv' | sort -u | wc -l) -eq 2 ]"

# The aggregator reads both shapes: rows recorded live, and older panels
# rebuilt from artifacts. A reconstructed row has no timing, and that field
# must stay EMPTY -- a zero would average like a real measurement.
rm -f "$R/slots.tsv"
OUT=$(run_cadre "$D" dataset "$D/dataset" 2>&1)
check "aggregate walks the reviews" "[ -s '$D/dataset/slots.tsv' ]"
check "it reconstructs the panel"   "grep -q reconstructed '$D/dataset/slots.tsv'"
check "and leaves secs empty"       "grep -qP '\t\treconstructed\$' '$D/dataset/slots.tsv'"
# ★ Explicitly: NOT a zero. A reconstructed row has no timing, and writing 0
# would average like a real measurement and drag every mean toward the floor.
check "never a fabricated zero"     "! grep -qP '\t0\treconstructed\$' '$D/dataset/slots.tsv'"
check "panels.tsv carries a diff_id" "grep -qP 'ds1\t[0-9a-f]{8}\.\.[0-9a-f]{8}' '$D/dataset/panels.tsv'"
check "and counts the seats"        "grep -qP 'ds1\t\S+\t2\t1\t0\t1\t' '$D/dataset/panels.tsv'"

echo "== ★ settled-decisions ledger =="
# ★ The loop-breaker. Cadre reviews once, but anything that WRAPS it re-raises
# findings the human already dismissed, because the reviewers have no memory.
D=$(case_dir settle)
mkdir -p "$D/state"
printf '# notes to self, must not be matched against\nL1 | wontfix | timestamps are strings, callers wrap them\nL2 | accepted | missing retry test, tracked in #412\n' > "$D/state/ledger"
printf 'REVIEW\n\n1. blocking - timestamps are strings\n2. should-fix - unchecked exit code in run.sh\n' > "$D/review.md"
# A judge stub: echoes canned JSON so this tests the plumbing, not a model.
cat > "$D/agents.d/judgestub.sh" <<'A'
run_judgestub() {
  echo '{"findings":[{"summary":"timestamps are strings","status":"SETTLED","ledger_id":"L1"},
                     {"summary":"unchecked exit code in run.sh","status":"NEW","ledger_id":null}]}'
}
A
printf '#!/bin/sh\nexit 0\n' > "$D/bin/judgestub"; chmod +x "$D/bin/judgestub"
OUT=$(run_cadre "$D" settle "$D/review.md" --judge judgestub); RC=$?
check "settle reports the NEW one"    "grep -q 'unchecked exit code' <<<\"\$OUT\""
check "settle marks the settled one"  "grep -q '\[L1\]' <<<\"\$OUT\""
check "non-zero while something new"  "[ $RC -ne 0 ]"
check "review file left alone"        "grep -q 'timestamps are strings' '$D/review.md'"

# ★ Models FENCE their JSON, and the extractor used to take the first { to EOF
# -- carrying the closing ``` with it, which jq rejects. A judge that answered
# perfectly was then reported as one that "failed or stopped early", and the
# correct findings appeared inside the error's own diagnostic lines. Measured
# with qwen judging a real panel. Every stub above returns bare JSON, which is
# exactly why the suite was green while live settle was broken: judge stubs are
# tidier than judges.
for shape in fenced tagged prose_after leading_prose; do
  case $shape in
    fenced)        pre='```';     post='```' ;;
    tagged)        pre='```json'; post='```' ;;
    prose_after)   pre='```json'; post='```
Let me know if you want more detail.' ;;
    leading_prose) pre='Here is the match:
```json'; post='```' ;;
  esac
  cat > "$D/agents.d/judgestub.sh" <<A
run_judgestub() {
  cat <<'J'
$pre
{"findings":[{"summary":"timestamps are strings","status":"SETTLED","ledger_id":"L1"},
             {"summary":"unchecked exit code in run.sh","status":"NEW","ledger_id":null}]}
$post
J
}
A
  OUT=$(run_cadre "$D" settle "$D/review.md" --judge judgestub 2>&1); RC=$?
  check "$shape JSON parses"          "! grep -q 'nothing was matched' <<<\"\$OUT\""
  check "$shape finds the NEW one"    "grep -q 'unchecked exit code' <<<\"\$OUT\""
  check "$shape keeps the SETTLED one" "grep -q '\[L1\]' <<<\"\$OUT\""
done
# A brace inside a string must not end the object early -- summaries quote code.
cat > "$D/agents.d/judgestub.sh" <<'A'
run_judgestub() {
  cat <<'J'
```json
{"findings":[{"summary":"the guard { returns early } here","status":"NEW","ledger_id":null}]}
```
J
}
A
OUT=$(run_cadre "$D" settle "$D/review.md" --judge judgestub 2>&1)
check "braces inside strings survive" "grep -q 'returns early' <<<\"\$OUT\""
# Still has to REFUSE a fenced block that is not complete JSON.
cat > "$D/agents.d/judgestub.sh" <<'A'
run_judgestub() {
  cat <<'J'
```json
{"findings":[{"summary":"cut off
```
J
}
A
OUT=$(run_cadre "$D" settle "$D/review.md" --judge judgestub 2>&1); RC=$?
check "fenced but broken still fails" "grep -q 'nothing was matched' <<<\"\$OUT\""
check "and still does not exit 0"     "[ $RC -ne 0 ]"

# ★ Everything settled means a wrapper can stop. That exit status IS the
# stopping rule, so it has to be exact.
cat > "$D/agents.d/judgestub.sh" <<'A'
run_judgestub() {
  echo '{"findings":[{"summary":"timestamps are strings","status":"SETTLED","ledger_id":"L1"}]}'
}
A
cat > "$D/agents.d/judgestub.sh" <<'A'
run_judgestub() {
  echo '{"findings":[{"summary":"timestamps are strings","status":"SETTLED","ledger_id":"L1"}]}'
}
A
OUT=$(run_cadre "$D" settle "$D/review.md" --judge judgestub); RC=$?
check "exits 0 when nothing is new"   "[ $RC -eq 0 ]"

# ★ A judge that returns junk must FAIL, not read as "all settled". Silence and
# "nothing new" are the same output, and one of them hides a live defect.
cat > "$D/agents.d/judgestub.sh" <<'A'
run_judgestub() { echo "Sorry, I could not process that request."; }
A
OUT=$(run_cadre "$D" settle "$D/review.md" --judge judgestub 2>&1); RC=$?
check "unparseable judge fails loudly" "grep -q 'nothing was matched' <<<\"\$OUT\""
check "and does not exit 0"            "[ $RC -ne 0 ]"

# Comment lines are notes to the human, not ledger entries.
printf '# only a comment\n' > "$D/state/ledger"
OUT=$(run_cadre "$D" settle "$D/review.md" --judge judgestub 2>&1)
check "comment-only ledger refused"   "grep -q 'no entries, only comments' <<<\"\$OUT\""
# No ledger at all is a clear message, not a crash.
rm -f "$D/state/ledger"
OUT=$(run_cadre "$D" settle "$D/review.md" --judge judgestub 2>&1)
check "missing ledger explains itself" "grep -q 'nothing settled yet' <<<\"\$OUT\""
OUT=$(run_cadre "$D" ledger show 2>&1)
check "ledger show without a file"    "grep -q 'no ledger at' <<<\"\$OUT\""

echo "== ★ two seats, one lineage =="
# The property the whole tool rests on, and the easiest to lose by accident:
# adding a CLI feels like adding a reviewer, but a harness fronting gpt-5 or
# claude is the same opinion in a different wrapper. Cursor alone can collide
# with the codex, claude and grok adapters. Warn, never refuse -- running one
# family twice on purpose is a real experiment.
D=$(case_dir family); S="$D/src"
git -C "$S" checkout -qb feature
echo committed >> "$S/app.js"; git -C "$S" commit -qam feat
OUT=$(run_cadre "$D" review --roster good:claude-opus-5,good2:sonnet-4-thinking \
        --synth none --base main --label fam1 "$S")
check "same family is called out"     "grep -q 'one lineage in two seats' <<<\"\$OUT\""
check "it names both seats"           "grep -q 'good:claude-opus-5' <<<\"\$OUT\""
check "and says why it matters"       "grep -q 'overstates the panel' <<<\"\$OUT\""
check "warns, does not refuse"        "grep -q '2 ok' <<<\"\$OUT\""
OUT=$(run_cadre "$D" review --roster good:claude-opus-5,good2:qwen3-coder \
        --synth none --base main --label fam2 "$S")
check "different families stay quiet" "! grep -q 'one lineage in two seats' <<<\"\$OUT\""

# ★ A shared QUOTA POOL is a third correlation axis, beside lineage and vendor,
# and it is the one that takes seats out all at once. Measured: a panel ran
# kiro:minimax-m2.5 beside kiro:glm-5 -- two genuinely different lineages, so
# the warning above stayed correctly quiet -- and BOTH died together on kiro's
# account quota. Half a panel, one cause. The check existed and missed it: the
# key was `spec_model | cut -d/ -f1`, which on a slash-less model returns the
# WHOLE model name, so two seats of one CLI hashed apart. Bare-model seats of
# the same agent share a pool by definition; the model belongs in the key only
# when it names a provider.
OUT=$(run_cadre "$D" review --roster good:minimax-m2.5,good:glm-5 --jobs 2 \
        --synth none --base main --label pool1 "$S")
check "same-CLI seats warned"         "grep -q 'draw on the same account' <<<\"\$OUT\""
check "it names the account"          "grep -q '(good)' <<<\"\$OUT\""
check "and says they go dark together" "grep -q 'TOGETHER' <<<\"\$OUT\""
check "different lineages stay quiet"  "! grep -q 'one lineage in two seats' <<<\"\$OUT\""
# A provider prefix is what makes two seats of one CLI actually independent.
OUT=$(run_cadre "$D" review --roster good:openrouter/a-1,good2:together/b-1 --jobs 2 \
        --synth none --base main --label pool2 "$S")
check "different providers stay quiet" "! grep -q 'draw on the same account' <<<\"\$OUT\""
# Same CLI AND same provider prefix is still one pool.
OUT=$(run_cadre "$D" review --roster good:openrouter/a-1,good:openrouter/b-1 --jobs 2 \
        --synth none --base main --label pool3 "$S")
check "same provider prefix warned"   "grep -q 'draw on the same account (good:openrouter)' <<<\"\$OUT\""
# Serial runs do not compete, so saying so would be noise.
OUT=$(run_cadre "$D" review --roster good:minimax-m2.5,good:glm-5 --jobs 1 \
        --synth none --base main --label pool4 "$S")
check "jobs=1 is not warned about"    "! grep -q 'draw on the same account' <<<\"\$OUT\""

echo "== ★ a prompt too big for argv must say so, not die in the shell =="
# Measured live: a 184KB synthesis over a 3-reviewer panel killed an argv-only
# adapter with `timeout: Argument list too long` -- an error naming neither the
# agent nor the cause, landing in the artifact as non-empty text, which is a
# review that found nothing. Linux caps ONE argv entry near 128KB whatever
# ARG_MAX says. Adapters whose CLI has stdin or a prompt file use it instead;
# this guard is for the ones with neither.
D=$(case_dir argvbig)
cat > "$D/agents.d/argvonly.sh" <<'A'
run_argvonly() {
  argv_prompt_ok || return 0
  echo "REVIEW by argvonly"
}
A
printf '#!/bin/sh\nexit 0\n' > "$D/bin/argvonly"; chmod +x "$D/bin/argvonly"
BIG=$(python3 -c "print('x'*120000)" 2>/dev/null || printf 'x%.0s' $(seq 1 120000))
OUT=$(printf '%s' "$BIG" | CADRE_AGENTS_D="$D/agents.d" PATH="$D/bin:$PATH" \
        "$ROOT/bin/agentcall" argvonly -d /tmp -m ro 2>&1)
check "oversize prompt says DID NOT RUN" "grep -q '^DID NOT RUN, prompt is 120000 bytes' <<<\"\$OUT\""
check "it names a way out"               "grep -q 'CADRE_SYNTH_MAX' <<<\"\$OUT\""
check "and it never ran the CLI"         "! grep -q 'REVIEW by argvonly' <<<\"\$OUT\""
OUT=$(printf 'small' | CADRE_AGENTS_D="$D/agents.d" PATH="$D/bin:$PATH" \
        "$ROOT/bin/agentcall" argvonly -d /tmp -m ro 2>&1)
check "a normal prompt is untouched"     "grep -q 'REVIEW by argvonly' <<<\"\$OUT\""

echo "== ★ unset HOME must name the variable, not die in bash =="
# cron, containers and scrubbed CI runners have no HOME. set -u turned that into
# "HOME: unbound variable" pointing into common.sh.
OUT=$(env -i PATH=/usr/bin:/bin "$ROOT/bin/cadre" doctor 2>&1); RC=$?
check "unset HOME names CADRE_HOME"  "grep -q 'HOME is unset' <<<\"\$OUT\""
check "and exits 2, not a bash trap" "[ $RC -eq 2 ]"
check "no raw unbound-variable error" "! grep -q 'unbound variable' <<<\"\$OUT\""
OUT=$(env -i PATH=/usr/bin:/bin "$ROOT/bin/agentcall" --list 2>&1)
check "agentcall guards HOME too"    "grep -q 'HOME is unset' <<<\"\$OUT\""

echo "== ★ the panel matrix must not invent coverage =="
# Three ways the matrix credited a cell it had no right to. All three were found
# by a codex-led audit of this repo and reproduced before they were fixed.
#   - K numbers are LOCAL to one key: every pass starts at K1, so alpha's K1
#     (auth bypass) and beta's K1 (dropped write) shared one cell and a hit on
#     one reported the other as covered.
#   - one candidate graded by two judges wrote into the same cell, so the
#     disagreement that judge-specific filenames exist to preserve vanished.
#   - an INVALID report's surviving HIT rows still closed coverage gaps,
#     contradicting the README, which excludes the whole pass from scoring.
D=$(mktemp -d -p "$SANDBOX"); mkdir -p "$D/home"; : > "$D/home/passes.conf"
printf '# Gauntlet: `stub`\n\n## alpha\n\n- run 1: K1=HIT K2=MISS, v\n\n## beta\n\n- run 1: K1=MISS, v\n' \
  > "$D/home/report-stub-by-judgeA.md"
printf '# Gauntlet: `stub`\n\n## alpha\n\n- run 1: K1=MISS K2=MISS, v\n' \
  > "$D/home/report-stub-by-judgeB.md"
printf '# Gauntlet: `leaky`\n\n## alpha\n\n- run 1: K1=HIT K2=HIT, v\n\n## Verdict: INVALID, answer-key leak suspected\n' \
  > "$D/home/report-leaky-by-judgeA.md"
OUT=$(CADRE_HOME="$D/home" "$ROOT/bin/cadre" panel 2>&1)
check "panel keeps the passes apart"   "grep -q '^pass alpha' <<<\"\$OUT\" && grep -q '^pass beta' <<<\"\$OUT\""
check "beta K1 is not covered by alpha's" "grep -q 'NOTHING in this lineup catches:.*beta/K1' <<<\"\$OUT\""
check "both judges get a row"          "[ \$(grep -c 'judge: judge' <<<\"\$OUT\") -ge 3 ]"
check "and they keep disagreeing"      "grep -q 'judgeA).*HIT' <<<\"\$OUT\" && grep -q 'judgeB).*MISS' <<<\"\$OUT\""
check "the leaked report is excluded"  "grep -q 'EXCLUDED as suspected key leaks.*leaky' <<<\"\$OUT\""
check "its HITs credit nothing"        "grep -q 'NOTHING in this lineup catches:.*alpha/K2' <<<\"\$OUT\""
check "and it gets no row"             "! grep -q '^leaky' <<<\"\$OUT\""
CADRE_HOME="$D/home" "$ROOT/bin/cadre" panel --save >/dev/null 2>&1
check "roster lists the seat once"     "[ \$(grep -c '^# stub\$' '$D/home/roster') -eq 1 ]"
# Every report INVALID is not an empty panel; it must say what happened.
rm -f "$D/home"/report-stub-*.md "$D/home/roster"
OUT=$(CADRE_HOME="$D/home" "$ROOT/bin/cadre" panel 2>&1); RC=$?
check "all-INVALID refuses to rank"    "[ $RC -ne 0 ] && grep -q 'no scorable reports' <<<\"\$OUT\""

echo "== ★ a registered pass that never ran must reach the report =="
# It was printed to the scrollback and dropped from the denominator, so the
# saved report could claim it caught every blocking item in every run while
# half the registered passes were never graded.
check "grade records the skip"       "grep -q 'skipped=\"\$skipped- \$label' '$ROOT/lib/grade.sh'"
check "and the report prints it"     "grep -q 'registered pass(es) NOT GRADED' '$ROOT/lib/grade.sh'"
check "a short denominator cannot slot" "grep -q 'INCOMPLETE, not slottable' '$ROOT/lib/grade.sh'"
check "leak verdict still outranks it"  "grep -A4 'nskipped\" -gt 0' '$ROOT/lib/grade.sh' | grep -q 'SLOT:\*|INCONCLUSIVE'"
# An unquoted DEFER is the judge's claim, not the candidate's behaviour, and
# DEFER on a blocking item is the one non-tunable disqualifier in the tool.
check "unquoted DEFER does not disqualify" "grep -q 'unquoted_defer=\$((unquoted_defer + 1))' '$ROOT/lib/grade.sh'"
check "but it is still surfaced"      "grep -q 'NOT counted as disqualifying' '$ROOT/lib/grade.sh'"

echo "== ★ an absent review is an unusable run, not a quiet zero =="
check "adjudicate counts it" "grep -B2 'no review to adjudicate' '$ROOT/lib/adjudicate.sh' | grep -q UNUSABLE"

echo "== ★ CADRE_WORK inside CADRE_HOME is refused everywhere =="
# ../../../keys from a reviewer's own working directory resolved straight into
# the answer keys. run-pass.sh refused it; the live review path did not, so the
# check moved into common.sh where every entry point pays it.
OUT=$(CADRE_HOME="$SANDBOX/wh" CADRE_WORK="$SANDBOX/wh/checkouts" "$ROOT/bin/cadre" doctor 2>&1); RC=$?
check "containment refused"      "[ $RC -eq 2 ]"
check "it says why"              "grep -q 'where the answer keys' <<<\"\$OUT\""
OUT=$(CADRE_HOME="$SANDBOX/wh" CADRE_WORK="$SANDBOX/wk" "$ROOT/bin/cadre" doctor 2>&1)
check "separate trees are fine"  "! grep -q 'where the answer keys' <<<\"\$OUT\""

echo "== ★ a complete short review of rate-limit code is not a refusal =="
# The README claims the length guard prevents this. In code, being SHORT was
# what enabled the keyword match, and a concise real review has no adapter
# marker to rescue it. A refusal never states a severity-tagged finding.
Q=$(mktemp -p "$SANDBOX"); printf 'blocking: the 429 too many requests path retries forever.\n' > "$Q"
CL="bash -c \"CADRE_HOME='$SANDBOX/ch' source '$ROOT/lib/common.sh'; classify_run '$Q' 0\""
check "short real review stays ok" "[ \"\$(eval $CL)\" = ok ]"
printf 'rate limit reached. 429 too many requests.\n' > "$Q"
check "an actual refusal still fails" "[ \"\$(eval $CL)\" = failed ]"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
