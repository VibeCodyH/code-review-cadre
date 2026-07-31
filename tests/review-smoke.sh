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
           synthquote synthtrunc synthrate synthtiny waffle parrot; do
    printf '#!/bin/sh\nexit 0\n' > "$1/bin/$n"; chmod +x "$1/bin/$n"
  done
  # ★ The trailing verdict is not decoration. review-live.md asks every reviewer
  # to end with one, and classify_run now files a run that states no findings AND
  # no verdict as `inconclusive` rather than `ok`. A stub without it models a
  # model that never reviewed, which is a real case with its own tests below --
  # so a stub standing in for a COMPLETE review has to say what a complete
  # review says. Last line, because the check is edge-anchored.
  cat > "$1/agents.d/good.sh" <<'A'
run_good() {
  echo "REVIEW by good"
  ( cd "$dir" && echo "--ls-files--" && git ls-files \
      && echo "--diff--" && git diff --name-only "$CADRE_PASS_BASE...HEAD" )
  echo "Verdict: ship it"
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
  # ★ Ran fine, said nothing. Exits 0, non-empty, no adapter marker, fluent --
  # and never reviewed. Measured shape: an opencode-routed slot that summarised
  # the diff and signed off with an emoji, and another that asked for
  # clarification. Under the old three states this scored `ok`, went into
  # synthesis as a complete review, and inflated every finding's denominator
  # while its silence cleared every file it never mentioned.
  # ★ Over 20 lines on purpose, with the tell at the END. The real artifacts were
  # 37-50KB, and the report EXCERPTS this state with head -20 rather than
  # printing it whole; a 3-line stub would have been quoted in full and the
  # excerpting test would have passed for the wrong reason.
  cat > "$1/agents.d/waffle.sh" <<'A'
run_waffle() {
  echo "I have looked over the changes you provided."
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22; do
    echo "The patch also touches area $i and adds new behaviour there."
  done
  echo "This makes the system more resilient and user-friendly. 🚀"
}
A
  # ★ The same state reached the other way, and the reason has_verdict is
  # EDGE-anchored. This one PARROTS the diff back, and the diff is of cadre, so
  # the body is thick with cadre's own vocabulary -- "ship it", "no defects
  # found", "verdict". An unanchored scan for those words passed all three
  # measured non-reviews for exactly this reason. Nothing here is a bottom line;
  # it is quoted source. Also the shape an UNMARKED truncation takes, so no
  # `_TRUNCATED` was ever coming from the adapter.
  # ★ The quoted vocabulary sits in the MIDDLE, with more than eight lines after
  # it, because that is the only arrangement that actually exercises the
  # anchoring. The measured artifacts were tens of KB, so their quotes were
  # nowhere near either edge; a short stub would put them inside tail -8 and the
  # test would pass on a plain grep.
  cat > "$1/agents.d/parrot.sh" <<'A'
run_parrot() {
  echo "Here is the change you asked about:"
  echo '+  echo "End with a one-line overall verdict: blocking, should-fix, or ship it."'
  echo '+check "no defects found path" "grep -q ship-it out.txt"'
  echo '+    body="$body===== REVIEWER: $sp ====="'
  local i
  for i in $(seq 16); do
    echo "+  context line $i, still quoted diff and not a conclusion"
  done
}
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
check "counts name all four states"       "grep -qE '1 ok, 1 degraded, 0 inconclusive, 2 failed' <<<\"\$OUT\""
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
  echo "Verdict: ship it"
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
check "grade path carries the judge"   "grep -q 'by-\$js.grade.json' '$ROOT/lib/grade.sh'"
check "report carries the judge"       "grep -q 'report-\$sl-by-\$jsl.md' '$ROOT/lib/grade.sh'"
check "and still carries the candidate" "grep -q '\$sl-run\$n.by-' '$ROOT/lib/grade.sh'"
# Slug the FULL spec: `opencode:ollama/qwen3-judge` and `opencode:ollama/qwen3:14b`
# are both `opencode`, so two local judges would collide under one name.
# ★ And the full LIST, not the first judge: a report reconciles every judge that
# graded, so naming it after one lets a (A,B) grading overwrite an (A,C) one --
# the same collision the judge-in-the-filename fix exists to prevent, one level
# up, reachable the moment a second judge became possible.
check "judge slug is the full spec"    "grep -q 'jsl=\$(slug \"\$(IFS=,; printf' '$ROOT/lib/grade.sh'"

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
# ★ Data, and CADRE'S OWN data. The nudge used to lead with a borrowed
# preprint's coverage percentages, which cadre neither produced nor reproduces --
# citing them is fine, resting the pitch on them is not. Its own scaffolding
# result is a real measurement it owns, and it stays concrete rather than
# becoming a lecture about panels.
check "nudge carries evidence"      "grep -q 'bug the other two missed' <<<\"\$OUT\""
check "nudge owns its sample size"  "grep -q 'not a sample size' <<<\"\$OUT\""
check "borrowed numbers not the pitch" "! grep -q '47% at one' <<<\"\$OUT\" && ! grep -q '56.8' <<<\"\$OUT\""
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
check "counts split them correctly"    "grep -q '1 ok, 0 degraded, 0 inconclusive, 1 failed' <<<\"\$OUT\""

echo "== ★ a clean exit with no review is INCONCLUSIVE, not ok =="
# ★ The fourth state, and the one with the worst consequence when it is missing.
# `ok` meant "has content, no marker, exit 0", which is not "is a review". Three
# artifacts on this machine's 26 review dirs were scored `ok` while being a
# summary, a request for clarification, and a parroted diff -- so cmd_synthesize
# counted three complete reviewers who had reviewed nothing, and their silence
# cleared every file. Narrow test: no findings AND no bottom line. Either one
# alone keeps the run `ok`.
D=$(case_dir inconclusive); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster waffle,parrot,good,terse --synth echoer --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "waffle -> .md.inconclusive"     "ls '$R'/waffle-*.md.inconclusive >/dev/null 2>&1"
check "and NOT a clean review"         "! ls '$R'/waffle-*.md >/dev/null 2>&1"
# ★ Kept apart from failed on purpose. Both are excluded and neither is scored,
# but the report has to send the reader to the ROSTER, not to the adapter.
check "and NOT filed as failed"        "! ls '$R'/waffle-*.md.failed >/dev/null 2>&1"
# ★ The edge-anchoring, which is the whole reason has_verdict is not a plain
# grep: parrot's body quotes cadre's own "ship it" / "no defects found" text.
check "quoted verdict is not a verdict" "ls '$R'/parrot-*.md.inconclusive >/dev/null 2>&1"
# Neither half of the rule fires alone.
check "terse findings=0 stays ok"      "ls '$R'/terse-*.md >/dev/null 2>&1"
check "a real review stays ok"         "ls '$R'/good-*.md >/dev/null 2>&1"
check "counts name it separately"      "grep -q '2 ok, 0 degraded, 2 inconclusive, 0 failed' <<<\"\$OUT\""
check "report says INCONCLUSIVE"       "grep -q 'INCONCLUSIVE' '$R/report.md'"
check "report says not a review"       "grep -q 'is not a review' '$R/report.md'"
# ★ The reader's tempting misread, spelled out where the counts are: these
# artifacts are LONG. Length is not coverage.
check "warns length is not coverage"   "grep -q 'Length is not coverage' '$R/report.md'"
check "and that it clears nothing"     "grep -q 'clears nothing' '$R/report.md'"
# ★ Excerpted like a failure, NOT printed whole like a partial. A partial is a
# review; this is chrome, and pasting it whole buries the reviews that are real.
check "body is excerpted, not inlined" "! grep -q 'more resilient and user-friendly' '$R/report.md'"
# ★ THE POINT. cmd_synthesize picks up .md and .md.partial and drops the rest
# into dead[], which is already told to keep those members out of every
# agreement tag -- so the false green closes with no prompt change at all.
# echoer echoes the prompt back, so synthesis.md IS what the synthesizer was
# told -- the same idiom the partial-delimiter tests below use.
P="$R/synthesis.md"
check "excluded from the synthesis"    "! grep -qE '^===== REVIEWER: (waffle|parrot) =====' '$P'"
check "declared unusable instead"      "grep -q 'NO USABLE REVIEW' '$P'"
check "both named as unusable"         "grep -E 'NO USABLE REVIEW' '$P' | grep -q waffle && grep -E 'NO USABLE REVIEW' '$P' | grep -q parrot"
check "panel size still stated"        "grep -q 'panel was 4 reviewers' '$P'"
check "and only 2 completed"           "grep -q 'of whom 2\$' '$P'"
# ★ ctx=synth is exempt. A synthesis of a clean panel names no findings and
# gives no verdict of its own -- it reports each reviewer's -- so applying the
# rule there would bin good merges.
# ★★ These two assertions were VACUOUS in the first version of this test and a
# mutation run is what showed it: the synth was `echoer`, whose output is the
# echoed prompt, and the prompt itself carries finding-shaped lines -- so they
# passed with the `ctx = run` guard deleted. A test for an exemption has to use
# input the rule would otherwise CATCH. `waffle` is that input, by construction:
# it is the stub built above to have no findings and no verdict. Delete the
# `ctx = run` guard in classify_run and the next two checks must fail.
DS=$(case_dir synth_exempt); SS="$DS/src"
git -C "$SS" checkout -qb feature; echo x >> "$SS/app.js"; git -C "$SS" commit -qam f
run_cadre "$DS" review --roster good,terse --synth waffle --base main "$SS" >/dev/null
RS="$DS/state/reviews/$(ls "$DS/state/reviews" | head -1)"
check "a no-verdict synth survives"    "[ -s '$RS/synthesis.md' ]"
check "and is not binned as unusable"  "[ ! -e '$RS/synthesis.md.failed' ]"
# The per-run record has to carry the state too: it is the benchmark row a
# roster decision gets made on.
check "slots.tsv records the state"    "grep -qP '\tinconclusive\t' '$R/slots.tsv'"

echo "== ★ coderabbit's bracket severities are findings =="
# ★ Measured across three real panels: coderabbit reviews declaring findings=3,
# findings=13 and findings=3 all counted ZERO here, because review_findings only
# allowed asterisks before the severity and coderabbit emits `- [major] file`.
# judge_incoherent() needs >= 2 to fire, so that check -- the one that catches a
# judge crediting nothing against a review full of findings -- was switched off
# for an entire reviewer family.
CRF=$(mktemp)
printf 'findings=3\n- [major] a.ts\n  do the thing\n- [major] b.ts\n  and the other\n- [minor] c.ts\n  style\n' > "$CRF"
check "bracket severities counted"     "[ \$(review_findings '$CRF') -ge 2 ]"
# The shapes that already worked must keep working: loosening this regex is only
# safe in one direction.
CRO=$(mktemp)
printf '1. **blocking** - [a.ts:4](x)\n### 2. should-fix - b.ts\n' > "$CRO"
check "and the old shapes still count" "[ \$(review_findings '$CRO') -ge 2 ]"
rm -f "$CRO"
# findings=N is coderabbit's bottom line: it takes no prompt, so it never gets
# asked for the prose verdict every other reviewer ends with.
check "findings=N is a verdict"        "has_verdict '$CRF'"
CRZ=$(mktemp); printf 'findings=0\n' > "$CRZ"
check "so a clean coderabbit run is ok" "has_verdict '$CRZ'"
# ★ Chrome on the SAME line as the bottom line, both edges. The escape-stripping
# in has_verdict is not decoration: without it these anchored patterns never see
# past the escape bytes, and a valid review is filed as a non-review. opencode
# emits exactly this shape, and the last time this function read raw bytes the
# bug was platform-specific and silent.
CRE=$(mktemp); printf '\033[0mfindings=0\033[0m\n' > "$CRE"
check "escaped findings= still counts"  "has_verdict '$CRE'"
CRV=$(mktemp); printf 'a\nb\n\033[0m**Verdict: ship it**\033[0m\n' > "$CRV"
check "escaped prose verdict counts"    "has_verdict '$CRV'"
# ★ A reviewer that LEADS with its verdict instead of ending with one. The brief
# asks for it last and every measured clean review complies, but binning this
# would be destroying a real review, which is the expensive direction.
CRL=$(mktemp)
printf 'Verdict: ship it\n\nNothing to flag. The diff only touches comments.\nNo behaviour changes.\n' > "$CRL"
check "a LEADING verdict counts too"    "has_verdict '$CRL'"
# ...and the reason only the line-anchored pattern is allowed at the head: this
# opens by quoting a diff that contains the words, and must NOT count.
CRQ=$(mktemp)
{ echo 'Here is the change you asked about:'
  echo '+  echo "End with a one-line overall verdict: blocking, or ship it."'
  echo '+check "no defects found" "grep -q x y"'
  for i in $(seq 16); do echo "+  context line $i"; done; } > "$CRQ"
check "quoted diff at the head is not"  "! has_verdict '$CRQ'"
# ★ Portability, from a cross-model review of this commit: `\b` is a GNU grep
# extension and BSD grep (macOS) reads `verdict\b` as literal `verdictb`, so a
# `\b` here would silently stop matching every prose verdict on one whole
# platform. This is the assertion that fails if someone reintroduces it.
check "verdict matched without \\b"     "has_verdict '$CRV'"
check "no \\b in the verdict patterns"  "! grep -q 'verdict.b)' '$ROOT/lib/common.sh'"
# ★ A sign-off block appended after the verdict must not push it out of the
# window. A wrapper adding a footer is exactly the shape ADDING-AN-AGENT.md warns
# adapters against, and a tight tail would have missed it.
CRS=$(mktemp)
{ echo "No defects worth filing."; echo "Verdict: ship it"; echo
  for i in $(seq 9); do echo "  generated by some-cli v1.2, see docs line $i"; done; } > "$CRS"
check "a verdict behind a footer counts" "has_verdict '$CRS'"
rm -f "$CRF" "$CRZ" "$CRE" "$CRV" "$CRL" "$CRQ" "$CRS"

echo "== ★ the EXPENSIVE direction: real clean reviews must stay ok =="
# ★★ This block is the one that matters most, and it did not exist until two
# cross-model reviews pointed out that the suite locked the three non-reviews and
# the coderabbit edges while leaving the destructive side to a stub that had been
# edited to say "Verdict: ship it". `inconclusive` means no findings AND no
# verdict, so every closer missing from has_verdict is a REAL review dropped from
# the synthesis. These are ordinary sign-offs, not exotic ones.
CD=$(mktemp -d -p "$SANDBOX")
i=0
while IFS= read -r closer; do
  i=$((i + 1))
  printf 'I read the whole diff. It only renames a local and adds a comment.\n\n%s\n' "$closer" > "$CD/c$i"
  check "clean closer stays ok: $closer" "has_verdict '$CD/c$i'"
done <<'CLOSERS'
No issues found.
No issues found
LGTM
LGTM, nice cleanup.
Looks good to me.
Approved.
Nothing to flag.
Nothing to report.
All good.
All clear.
Safe to merge.
Ready to merge.
I recommend merging this.
No defects found.
No problems here.
No concerns.
**Verdict:** ship it
## Verdict
- **Verdict:** should-fix
Overall verdict: blocking
Conclusion: do not merge.
Recommendation: hold this one.
CLOSERS
# ★ Top-heavy layout: the bottom line leads and the analysis follows for pages.
# tail alone would never see it, which is why the head window exists and why it
# is six lines rather than three.
TH=$(mktemp)
{ echo "# Review of the change"; echo; echo "## Verdict"; echo; echo "Ship it."; echo
  for i in $(seq 40); do echo "Then a paragraph of analysis, line $i, no severities."; done; } > "$TH"
check "top-heavy verdict stays ok"      "has_verdict '$TH'"
# ★ Loose declaration forms. Only the flush-left `findings=N` was tested before.
DF=$(mktemp)
for form in 'findings=0' '**findings=0**' 'Findings: 0' 'findings = 12' '`findings=3`'; do
  printf '%s\nsome body text\n' "$form" > "$DF"
  check "declaration form: $form"       "has_verdict '$DF'"
done
rm -f "$TH" "$DF"
# ★ pipefail regression. Two independent reviews claimed `grep -q` SIGPIPEs the
# upstream `sed` and poisons the pipeline under `set -o pipefail`, filing real
# reviews as non-reviews. It does not, because head/tail bound the stream to a
# dozen short lines -- but the claim is reasonable enough to keep a test for, so
# that if someone removes the bound the failure is loud instead of intermittent.
BIG=$(mktemp)
{ echo "Verdict: ship it"; for i in $(seq 5000); do echo "filler line $i"; done
  echo "No issues found."; } > "$BIG"
check "big artifact, match at edge"     "has_verdict '$BIG'"
rm -f "$BIG"

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
check "dead reviewer still declared"   "grep -q 'NO USABLE REVIEW: dead' '$P'"
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
check "and counts the seats"        "grep -qP 'ds1\t\S+\t2\t1\t0\t0\t1\t' '$D/dataset/panels.tsv'"

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

echo "== ★ adapter parity: operator config must not reach a review =="
# claude.sh drops the OPERATOR's MCP servers in ro mode. codex.sh was still
# loading $CODEX_HOME/config.toml -- mcp_servers and model overrides included --
# so a benchmark comparing them compared one model without your MCP servers
# against another with them, which is a property of the machine and not of
# either model.
OUT=$(echo hi | CADRE_AGENTS_D="$ROOT/agents.d" "$ROOT/bin/agentcall" --print-command codex -d /tmp -m ro 2>&1)
check "codex ro drops user config"  "grep -q -- '--ignore-user-config' <<<\"\$OUT\" || ! codex exec --help 2>&1 | grep -q -- '--ignore-user-config'"
OUT=$(echo hi | CADRE_AGENTS_D="$ROOT/agents.d" "$ROOT/bin/agentcall" --print-command codex -d /tmp -m rw 2>&1)
check "and rw is left alone"        "! grep -q -- '--ignore-user-config' <<<\"\$OUT\""
check "claude ro still drops MCP"   "grep -q -- '--strict-mcp-config' '$ROOT/agents.d/claude.sh'"
# ★ The gap that is NOT closed must stay written down. Probed 2026-07-28: under
# -s read-only codex still holds collaboration.spawn_agent and web.run, and the
# obvious feature flags do not remove them. An unrecorded asymmetry is what
# makes a comparison wrong while it still looks right -- the advisor hole voided
# a whole round exactly that way.
check "codex records the open hole" "grep -q 'collaboration.spawn_agent' '$ROOT/agents.d/codex.sh'"
# ★ CLI-REFERENCE documented `claude -p --allowedTools Read,Grep,...` long after
# the adapter abandoned it -- and the adapter's own notes say that approach
# voided a benchmark round, because --allowedTools only PRE-APPROVES and denies
# nothing. Someone reading the doc would have reimplemented the hole. The doc is
# generated from --print-command, so drift is silent unless something checks.
check "docs drop the voided flag"   "! grep -q -- '--allowedTools' '$ROOT/docs/CLI-REFERENCE.md'"
check "docs show what claude denies" "grep -q -- '--disallowedTools' '$ROOT/docs/CLI-REFERENCE.md' && grep -q -- '--strict-mcp-config' '$ROOT/docs/CLI-REFERENCE.md'"
check "docs show codex isolation"   "grep -q -- '--ignore-user-config' '$ROOT/docs/CLI-REFERENCE.md'"
check "docs say the adapter wins"   "grep -q 'the adapter is right and this block is stale' '$ROOT/docs/CLI-REFERENCE.md'"
# The credential check reads CONTENT for four config files, so "filenames, not
# contents" stopped being true. The narrowness it was there to convey is real
# and has to survive the correction: a key in a source file still passes.
check "preflight claim corrected"   "! grep -q 'reads filenames, not contents' '$ROOT/README.md'"
check "but still says what it misses" "grep -q 'A key in a source file passes' '$ROOT/README.md'"
check "and says the sandbox misses it" "grep -q 'governs model-generated SHELL' '$ROOT/agents.d/codex.sh'"
check "and names the failed flags"  "grep -q 'all three no-ops here' '$ROOT/agents.d/codex.sh'"

echo "== ★ coverage from a cell the candidate's own runs disagreed on =="
# The matrix takes the BEST grade across runs, which is right for staffing -- a
# reviewer that finds the bug half the time still finds it -- but collapsing to
# best-ever hid the difference between "caught it twice" and "caught it once and
# missed it once" on the same checkout and prompt. At two runs a flipping cell is
# indistinguishable from a lineage that genuinely covers what the others miss,
# which is the single weakest claim this tool makes.
D=$(mktemp -d -p "$SANDBOX"); mkdir -p "$D/home"; : > "$D/home/passes.conf"
printf '# Gauntlet: `flaky`\n\n## alpha\n\n- run 1: K1=HIT K2=MISS, v\n- run 2: K1=MISS K2=MISS, v\n' \
  > "$D/home/report-flaky-by-j.md"
printf '# Gauntlet: `solid`\n\n## alpha\n\n- run 1: K1=MISS K2=HIT, v\n- run 2: K1=MISS K2=HIT, v\n' \
  > "$D/home/report-solid-by-j.md"
OUT=$(CADRE_HOME="$D/home" "$ROOT/bin/cadre" panel 2>&1)
check "flip: the cell is marked"       "grep -qE 'flaky.*HIT\*' <<<\"\$OUT\""
check "flip: a stable HIT is not"      "grep -qE 'solid.*HIT( |\$)' <<<\"\$OUT\" && ! grep -qE 'solid.*HIT\*' <<<\"\$OUT\""
check "flip: coin-flip coverage named" "grep -q 'OWN runs disagreed: alpha/K1' <<<\"\$OUT\""
check "flip: and only that item"       "! grep -q 'disagreed:.*K2' <<<\"\$OUT\""
check "flip: it still counts as caught" "grep -q 'Every key item is caught' <<<\"\$OUT\""
# With no flips anywhere the warning must stay silent, or it becomes wallpaper.
D=$(mktemp -d -p "$SANDBOX"); mkdir -p "$D/home"; : > "$D/home/passes.conf"
printf '# Gauntlet: `solid`\n\n## alpha\n\n- run 1: K1=HIT, v\n- run 2: K1=HIT, v\n' \
  > "$D/home/report-solid-by-j.md"
OUT=$(CADRE_HOME="$D/home" "$ROOT/bin/cadre" panel 2>&1)
check "flip: silent when stable"       "! grep -q 'OWN runs disagreed' <<<\"\$OUT\" && ! grep -q 'HIT\*' <<<\"\$OUT\""

echo "== ★ a registered pass that never ran must reach the report =="
# It was printed to the scrollback and dropped from the denominator, so the
# saved report could claim it caught every blocking item in every run while
# half the registered passes were never graded.
check "grade records the skip"       "grep -q 'skipped=\"\$skipped- \$label' '$ROOT/lib/grade.sh'"
check "and the report prints it"     "grep -q 'registered pass(es) NOT GRADED' '$ROOT/lib/grade.sh'"
check "a short denominator cannot slot" "grep -q 'INCOMPLETE, not slottable' '$ROOT/lib/grade.sh'"
# -A12, not -A4: this asserts the SHAPE of the source rather than behaviour, so a
# comment added inside the block breaks it while the guard still works. Widened
# once already for exactly that reason. The claim is narrow -- the rewrite matches
# only SEAT:*|INCONCLUSIVE, so a leak or a DEFER keeps its disqualifying verdict.
check "leak verdict still outranks it"  "grep -A12 'nskipped\" -gt 0' '$ROOT/lib/grade.sh' | grep -q 'SEAT:\*|INCONCLUSIVE'"
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

echo "== ★ --full reviews content as it stands, not as a diff =="
# Asked for directly: "it should be scoped for any review I want", not diffs only.
D=$(case_dir target_full); S="$D/src"
OUT=$(run_cadre "$D" review --full --roster good "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
G=$(ls "$R"/good-*.md 2>/dev/null | head -1)
check "full: a review was produced"    "[ -n \"$G\" ] && [ -s \"$G\" ]"
check "full: the whole tree is there"  "grep -q 'app.js' '$G'"
check "full: the diff shows all of it" "sed -n '/--diff--/,\$p' '$G' | grep -q 'app.js'"
check "full: label is not review--1"   "! grep -q '^review--' <<<\"\$(ls '$D/state/reviews')\""
check "full: manifest names the mode"  "grep -q '^mode:      target' '$R/manifest.txt'"
check "full: no empty base field"      "! grep -qE '^(base|snapshot): *\$' '$R/manifest.txt'"
check "full: banner says as they stand" "grep -q 'as they stand' <<<\"\$OUT\""
check "full: report header too"        "grep -q 'as it stands' '$R/report.md'"
# ★ Provenance. The work dir is a mktemp that is deleted at exit, so without this
# nothing on disk says which files a reviewer actually read.
check "full: the file list is saved"   "[ -s '$R/files.txt' ] && grep -q 'app.js' '$R/files.txt'"
check "full: manifest points at it"    "grep -q 'files: *.*files.txt' '$R/manifest.txt'"
# The brief has to be the target one: a reviewer handed a whole tree under the
# diff brief treats every file as new work and scales its findings to the volume.
check "full: target brief used"        "grep -q 'as it stands' '$R/prompt.txt'"
check "full: no diff framing left"     "! grep -q 'against {{BASE}}' '$R/prompt.txt' && ! grep -q 'git diff' '$R/prompt.txt'"
check "full: no unrendered placeholder" "! grep -q '{{' '$R/prompt.txt'"
check "full: --base is refused"        "grep -q 'opposites' <<<\"\$(run_cadre '$D' review --full --base main '$S')\""
check "full: a missing target is named" "grep -q 'nothing to review' <<<\"\$(run_cadre '$D' review --full '$D/nope')\""
# The diff path must be untouched by all of this.
git -C "$S" checkout -qb feature; echo more >> "$S/app.js"; git -C "$S" commit -qam feat
OUT=$(run_cadre "$D" review --roster good --base main --label difftoo "$S")
check "diff: manifest still says diff" "grep -q '^mode:      diff' '$D/state/reviews/difftoo/manifest.txt'"
check "diff: base still recorded"      "grep -qE '^base: *[0-9a-f]{7}' '$D/state/reviews/difftoo/manifest.txt'"
check "diff: no stray files.txt"       "[ ! -e '$D/state/reviews/difftoo/files.txt' ]"

echo "== ★ --full on a subdirectory of a repo takes only that subdirectory =="
# README promises `cadre review --full ./src/billing`. ls-files run from a
# subdirectory is path-limited to it, which is the whole mechanism.
D=$(case_dir target_sub); S="$D/src"
mkdir -p "$S/billing"; echo 'charge()' > "$S/billing/charge.js"
echo 'unrelated' > "$S/elsewhere.js"
git -C "$S" add -A; git -C "$S" commit -qm sub
OUT=$(run_cadre "$D" review --full --roster good "$S/billing")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "sub: the subdir is reviewed"    "grep -q 'charge.js' '$R/files.txt'"
check "sub: the rest of the repo is NOT" "! grep -q 'elsewhere.js' '$R/files.txt' && ! grep -q 'app.js' '$R/files.txt'"
check "sub: git listing was used"      "grep -q '^source:    git' '$R/manifest.txt'"
# Synthesis has to work here too: it reads the reviews, never the base.
OUT=$(run_cadre "$D" review --full --roster good,good2 --synth echoer --label sy "$S/billing")
check "sub: synthesis ran"             "[ -s '$D/state/reviews/sy/synthesis.md' ]"

echo "== ★ --full on a plain directory, and .gitignore still applies =="
# The dangerous half of target mode: the reviewers see the whole tree, so a
# gitignored .env must not merely be kept out of the index -- it must not be
# in the directory they run in, because secrets_preflight skips ignored files.
D=$(case_dir target_plain)
mkdir -p "$D/plain"; echo 'a doc worth reviewing' > "$D/plain/notes.md"
printf 'secrets.txt\n' > "$D/plain/.gitignore"; echo 'AWS_SECRET_ACCESS_KEY=abc' > "$D/plain/secrets.txt"
OUT=$(run_cadre "$D" review --full --roster good "$D/plain")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
G=$(ls "$R"/good-*.md 2>/dev/null | head -1)
check "plain: non-repo dir reviewed"    "grep -q 'notes.md' '$G'"
check "plain: it says it is not a repo" "grep -q '^source:    plain' '$R/manifest.txt'"
check "plain: ignored file NOT in tree" "! grep -q 'secrets.txt' '$G'"
check "plain: nor in the file list"     "! grep -q 'secrets.txt' '$R/files.txt'"
check "plain: the exclusion is stated"  "grep -q 'excluded by .gitignore' <<<\"\$OUT\""
# A credential NOT covered by .gitignore must still stop the run outright.
D=$(case_dir target_plain2)
mkdir -p "$D/plain"; echo doc > "$D/plain/notes.md"; echo 'API_TOKEN=x' > "$D/plain/.env"
OUT=$(run_cadre "$D" review --full --roster good "$D/plain"); RC=$?
# ★ On the EXIT CODE and the exact path. "$OUT contains .env" also matches
# .env.example and any chatter, and "no review directory" is equally what an
# unrelated early failure looks like -- so the loose version of this check
# passed whether or not the credential check ran at all. 3 is preflight's own
# code, which is the only discriminating signal. Same rule as the diff path.
check "plain: a .env still refuses"     "[ $RC -eq 3 ]"
check "plain: and it names that file"   "grep -qE '^  \./?\.env\$' <<<\"\$OUT\""
check "plain: no reviewer ever ran"     "! grep -q 'REVIEW by good' <<<\"\$OUT\""
# ★ And the same end to end on the DIFF path, which was never asserted either:
# cmd_review collapsed every run-review.sh failure to exit 1, so a refusal was
# indistinguishable from a flaky run to anything wrapping cadre -- and a retry is
# the wrong response to a credential refusal. The preflight's own code is 3.
D=$(case_dir target_rc); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
echo 'API_TOKEN=x' > "$S/.env"; git -C "$S" add -A; git -C "$S" commit -qm env
OUT=$(run_cadre "$D" review --roster good --base main "$S"); RC=$?
check "diff: a refusal exits 3, not 1"  "[ $RC -eq 3 ]"
# A fresh case: the .env above is committed, so reusing that tree would refuse
# again and the assertion would pass for the wrong reason.
D=$(case_dir target_rc2); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster ghost --base main "$S"); RC=$?
check "diff: a failed run still exits 1" "[ $RC -eq 1 ]"
check "diff: and it says every one failed" "grep -q 'every reviewer failed' <<<\"\$OUT\""

echo "== ★ --full on a single file =="
D=$(case_dir target_file)
echo 'lone document content' > "$D/lone.md"
OUT=$(run_cadre "$D" review --full --roster good "$D/lone.md")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
G=$(ls "$R"/good-*.md 2>/dev/null | head -1)
check "file: a lone file reviewed"    "grep -q 'lone.md' '$G'"
check "file: and only that file"      "[ \$(grep -c . '$R/files.txt') -eq 1 ]"
check "file: label names the file"    "ls '$D/state/reviews' | grep -q 'lone'"

echo "== ★ --full refuses a target too big to hand four models =="
# secrets_preflight catches credentials. Nothing caught pointing this at a tree
# with node_modules in it: every reviewer reads all of it, so it is a bill too.
D=$(case_dir target_big)
mkdir -p "$D/big/vendor"; for i in $(seq 1 30); do echo x > "$D/big/vendor/f$i.js"; done
echo one > "$D/big/main.js"
OUT=$(CADRE_TARGET_MAX_FILES=10 run_cadre "$D" review --full --roster good "$D/big")
check "big: refused"                  "grep -q 'too big to review whole' <<<\"\$OUT\""
check "big: names the file count"     "grep -q '31 file' <<<\"\$OUT\""
check "big: names the worst dir"      "grep -q 'vendor (30 files)' <<<\"\$OUT\""
check "big: names the way out"        "grep -q 'CADRE_TARGET_MAX_FILES' <<<\"\$OUT\""
check "big: no reviewer ever ran"     "! grep -q 'REVIEW by good' <<<\"\$OUT\""
OUT=$(CADRE_TARGET_MAX_FILES=100 run_cadre "$D" review --full --roster good "$D/big")
check "big: raising the cap works"    "! grep -q 'too big' <<<\"\$OUT\""
OUT=$(CADRE_TARGET_MAX_FILES=abc run_cadre "$D" review --full --roster good "$D/big")
check "big: a bad cap is refused"     "grep -q 'must be numbers' <<<\"\$OUT\""

echo "== ★ --full still refuses CADRE_HOME under the target =="
# Stricter here than in diff mode, not looser: --full copies the WHOLE tree, so
# the keys reach the reviewers even when nothing has changed.
D=$(case_dir target_home)
mkdir -p "$D/tree/.cadre/keys"; echo 'K1 the answer' > "$D/tree/.cadre/keys/k.md"
echo doc > "$D/tree/notes.md"
OUT=$(CADRE_HOME="$D/tree/.cadre" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      PATH="$D/bin:$PATH" "$ROOT/bin/cadre" review --full --roster good "$D/tree" 2>&1)
check "full: nested CADRE_HOME refused" "grep -q 'sits inside it' <<<\"\$OUT\""
OUT=$(CADRE_HOME="$D/tree" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      PATH="$D/bin:$PATH" "$ROOT/bin/cadre" review --full --roster good "$D/tree" 2>&1)
check "full: equality refused too"      "grep -q 'sits inside it' <<<\"\$OUT\""

echo "== ★ the dual-grader gate: agreement is the grade, a split scores NOTHING =="
# The rule was decided 2026-07-27 and lived only in the prompts and the notes:
# two graders agree -> that is the grade; they split -> UNRESOLVED, scores
# nothing, report a range; and a split is evidence the KEY is underspecified, not
# a tie to break. Two graders here split on about ONE ITEM IN THREE, and three
# readers scored one candidate 2/6, 4/6 and 6/6 ordered by nothing but leniency.
# Fixtures, not live judges: pre-written grade files are reused when rescore=0,
# so these exercise the reconciliation itself with no model in the loop.
gauntlet_case() {  # gauntlet_case <dir> <spec> <judgeA-verdicts> <judgeB-verdicts>
  local d="$1" spec="$2" va="$3" vb="$4" sl ja jb sha
  mkdir -p "$d/home/p1"
  setup_agents "$d"
  new_repo "$d/checkout"
  sha=$(git -C "$d/checkout" rev-parse HEAD)
  printf '#### K1 blocking - the write is dropped\ntext\n\n#### K2 blocking - the token leaks\ntext\n' \
    > "$d/home/k.md"
  printf 'p1|%s|%s|%s|%s\n' "$sha" "$d/checkout" "$sha" "$d/home/k.md" > "$d/home/passes.conf"
  sl=$(slug "$spec")
  printf 'blocking - the write is dropped\nblocking - the token leaks\n' > "$d/home/p1/$sl-run1.md"
  ja=$(slug good); jb=$(slug good2)
  printf '%s\n' "$va" > "$d/home/p1/$sl-run1.by-$ja.grade.json"
  printf '%s\n' "$vb" > "$d/home/p1/$sl-run1.by-$jb.grade.json"
}
run_gaunt() {  # run_gaunt <dir> <judge-spec> <candidate>
  local d="$1" j="$2" c="$3"
  CADRE_HOME="$d/home" CADRE_WORK="$d/work" CADRE_AGENTS_D="$d/agents.d" \
  CADRE_JUDGE="$j" PATH="$d/bin:$PATH" "$ROOT/bin/cadre" run "$c" 1 p1 2>&1
}
HITBOTH='{"items":{"K1":"HIT","K2":"HIT"},"quotes":{"K1":"the write is dropped","K2":"the token leaks"},"verdict":"found","extras":[]}'
SPLITK2='{"items":{"K1":"HIT","K2":"MISS"},"quotes":{"K1":"the write is dropped"},"verdict":"found","extras":[]}'

# Both judges agree on both items: that IS the grade, no range, seated alone.
D=$(mktemp -d -p "$SANDBOX"); gauntlet_case "$D" terse "$HITBOTH" "$HITBOTH"
OUT=$(run_gaunt "$D" good,good2 terse)
R=$(ls "$D/home"/report-*.md | head -1)
check "gate: agreement scores"        "grep -q 'blocking items hit: \*\*2 / 2\*\*' '$R'"
check "gate: and seats the candidate" "grep -q 'Verdict: SEAT: can review alone' '$R'"
# Not the word anywhere -- the header explains the rule and should say it. No
# ITEM may be unresolved, and no range may be reported.
check "gate: no item is UNRESOLVED"   "! grep -q '=UNRESOLVED' '$R' && ! grep -q ' to .* / ' '$R'"
check "gate: report names both judges" "grep -q 'Judges: .*good.*good2' '$R'"
check "gate: both quotes are shown"   "[ \$(grep -c 'K1 (good' '$R') -ge 1 ]"

# One item split: it scores NEITHER way, and the range straddles "can review
# alone" and "needs a second reader", so there is no seat to recommend.
D=$(mktemp -d -p "$SANDBOX"); gauntlet_case "$D" terse "$HITBOTH" "$SPLITK2"
OUT=$(run_gaunt "$D" good,good2 terse)
R=$(ls "$D/home"/report-*.md | head -1)
check "split: reported as a RANGE"     "grep -q 'blocking items hit: \*\*1 to 2 / 2\*\* (1 UNRESOLVED)' '$R'"
check "split: the item is UNRESOLVED"  "grep -q 'K2=UNRESOLVED' '$R'"
check "split: refuses to slot"         "grep -q 'Verdict: UNRESOLVED, not slottable' '$R'"
check "split: names the two bands"     "grep -q \"straddles the line\" '$R'"
check "split: blames the KEY"          "grep -q 'bug in the KEY' '$R' && grep -q 'another judge swap' '$R'"
check "split: prints BOTH readings"    "grep -q 'good: HIT' '$R' && grep -q 'good2: MISS' '$R'"
check "split: K1 still scored"         "grep -q 'K1=HIT' '$R'"
# ★ The agreed item still counts. A gate that threw away the whole run on one
# split would make the second judge a downgrade rather than a measurement.
check "split: agreed item in the total" "grep -qE 'all items hit: 1 / 2' '$R'"

# ★ A run needs EVERY judge. One judge's reading reconciled against a missing one
# is a single-judge score wearing a two-judge label.
D=$(mktemp -d -p "$SANDBOX"); gauntlet_case "$D" terse "$HITBOTH" '{"unusable":true}'
OUT=$(run_gaunt "$D" good,good2 terse)
R=$(ls "$D/home"/report-*.md | head -1)
check "outage: the run is UNUSABLE"    "grep -q 'run 1: \*\*UNUSABLE\*\*' '$R'"
check "outage: it names which judge"   "grep -q 'good2:' '$R'"
# ★ A pass whose every run was UNUSABLE now says NOTHING MEASURED, not 0/0. It
# used to report "INCONCLUSIVE, no blocking items were graded" and point at the
# registry -- and this assertion accepted that, which is how the shape survived
# to the overnight sweep where 11 of 12 passes produced nothing and the artifact
# still read like a result. 0/0 out of a pass that ran is not a score, so the
# verdict has to be about the measurement failing, and the exit code has to
# agree: a driver piping stdout to /dev/null sees only that.
check "outage: not a 0/0 score"        "! grep -q 'blocking items hit' '$R'"
# ★ NOTHING GRADED, not NOTHING MEASURED, and the difference is the whole point:
# the review is on disk. A driver told "4" stops the sweep, which for a judge
# outage means abandoning hours of review production to save one cheap re-grade.
check "outage: NOTHING GRADED"         "grep -q 'Verdict: NOTHING GRADED' '$R'"
check "outage: says reviews exist"     "grep -q 'The reviews exist' '$R'"
check "outage: says do not re-review"  "grep -q 'Do not re-review' '$R'"
check "outage: names the pass"         "grep -q 'p1: 1 review(s) exist but none was gradeable' '$R'"
RCO=0
D3=$(mktemp -d -p "$SANDBOX"); gauntlet_case "$D3" terse "$HITBOTH" '{"unusable":true}'
run_gaunt "$D3" good,good2 terse >/dev/null 2>&1 || RCO=$?
check "outage: exit 5, not 4"          "[ '$RCO' -eq 5 ]"
check "outage: the good grade is kept" "[ -s \"\$(ls '$D/home/p1'/*by-\$(slug good).grade.json)\" ]"
check "outage: and says so"            "grep -q 'was NOT discarded' '$R'"

# A single judge still works, and says out loud that it is not a measurement.
D=$(mktemp -d -p "$SANDBOX"); gauntlet_case "$D" terse "$HITBOTH" "$HITBOTH"
OUT=$(run_gaunt "$D" good terse)
R=$(ls "$D/home"/report-*.md | head -1)
check "solo: still grades"             "grep -q 'blocking items hit: \*\*2 / 2\*\*' '$R'"
check "solo: warns it is one reading"  "grep -q 'ONE judge graded this' '$R'"
check "solo: quotes the real split rate" "grep -q 'one item in three' '$R'"
check "solo: hands over the command"   "grep -q \"CADRE_JUDGE='good,<other-agent>'\" '$R'"
# ★ Two judges must not overwrite a (A,B) report with an (A,C) one: the report
# reconciles every judge that graded, so its name carries the whole list.
D=$(mktemp -d -p "$SANDBOX"); gauntlet_case "$D" terse "$HITBOTH" "$HITBOTH"
cp "$D/home/p1/$(slug terse)-run1.by-$(slug good2).grade.json" \
   "$D/home/p1/$(slug terse)-run1.by-$(slug trunc).grade.json"
run_gaunt "$D" good,good2 terse >/dev/null 2>&1
run_gaunt "$D" good,trunc  terse >/dev/null 2>&1
check "pairs: two reports, not one"    "[ \$(ls '$D/home'/report-*.md | grep -c .) -eq 2 ]"

# ★ A split DEFER is the most consequential split there is: a deferred blocking
# item is the one finding this tool treats as worse than a miss, so "the gate
# declined to decide" must not read as "the candidate is clear".
DEFERK2='{"items":{"K1":"HIT","K2":"DEFER"},"quotes":{"K1":"the write is dropped","K2":"argued it was fine"},"verdict":"found","extras":[]}'
D=$(mktemp -d -p "$SANDBOX"); gauntlet_case "$D" terse "$DEFERK2" "$SPLITK2"
OUT=$(run_gaunt "$D" good,good2 terse)
R=$(ls "$D/home"/report-*.md | head -1)
check "split DEFER: not disqualifying" "! grep -q 'Verdict: DO NOT SLOT' '$R'"
check "split DEFER: but called out"    "grep -q 'did NOT disqualify' '$R'"
check "split DEFER: says it is undecided" "grep -q 'declined to decide, it did not clear it' '$R'"
# Both judges agreeing on DEFER still disqualifies outright. That rule is the
# one thing in this tool with no tuning knob and the gate must not soften it.
D=$(mktemp -d -p "$SANDBOX"); gauntlet_case "$D" terse "$DEFERK2" "$DEFERK2"
OUT=$(run_gaunt "$D" good,good2 terse)
R=$(ls "$D/home"/report-*.md | head -1)
check "agreed DEFER disqualifies"      "grep -q 'Verdict: DO NOT SLOT' '$R'"

# ★ Per judge, not against the whole CADRE_JUDGE string: with two judges
# spec_agent returns "a,b" and the self-grading warning silently stopped firing.
D=$(mktemp -d -p "$SANDBOX"); gauntlet_case "$D" good "$HITBOTH" "$HITBOTH"
OUT=$(run_gaunt "$D" good,good2 good)
check "self-grading warned per judge"  "grep -q \"judge 'good' are the same CLI\" <<<\"\$OUT\""
check "and the call budget doubles"    "grep -q '2 judge calls' <<<\"\$OUT\""

echo "== ★ more than two judges is a vote, and this does not vote =="
D=$(mktemp -d -p "$SANDBOX"); gauntlet_case "$D" terse "$HITBOTH" "$HITBOTH"
OUT=$(run_gaunt "$D" good,good2,trunc terse)
check "three judges refused"           "grep -q 'Two is the most this scores' <<<\"\$OUT\""
check "and it says why"                "grep -q 'becomes a vote' <<<\"\$OUT\""
# Two graders of one lineage are one grader in two seats: warn, never refuse.
OUT=$(run_gaunt "$D" 'opencode:openai/gpt-5,opencode:openai/gpt-5-mini' terse)
check "same-lineage judges warned"     "grep -q 'are both .* models' <<<\"\$OUT\""
check "warned, not refused"            "! grep -q 'Two is the most' <<<\"\$OUT\""
# A duplicate is not a second opinion; it collapses to one judge.
OUT=$(run_gaunt "$D" good,good terse)
R=$(ls "$D/home"/report-*.md | head -1)
check "a repeated judge is deduped"    "grep -q 'ONE judge graded this' '$R'"

echo "== ★ a budget refusal is not a rate limit, and the sweep must not grind on =="
# The overnight sweep this section exists for: claude answered "You've hit your
# monthly spend limit" in about a second, and the harness attempted eleven more
# passes over fifty minutes writing 102-byte .failed files. Then run-pass.sh
# exited 0 (it always did), run_gauntlet's `|| return 1` therefore never fired,
# and the driver wrote COMPLETED over a sweep with 3 of 30 reviews. Every link in
# that chain gets a test.
QB="$SANDBOX/budget.txt"
QE="bash -c \"source '$ROOT/lib/common.sh'; quota_exhausted '$QB'\""
printf "You've hit your monthly spend limit · raise it at claude.ai/settings/usage\n" > "$QB"
check "budget: spend limit caught"    "$QE"
check "budget: and it is NOT a rate limit" "! bash -c \"source '$ROOT/lib/common.sh'; rate_limited '$QB'\""
printf '429 Your account org-abc <ak-1> is suspended due to insufficient balance, please recharge your account\n' > "$QB"
check "budget: empty account caught"  "$QE"
# ★ This one matches BOTH. It is the kimi failure, and it burned three backoff
# retries against an account with no balance. Budget has to be asked FIRST.
check "budget: outranks the 429"      "bash -c \"source '$ROOT/lib/common.sh'; rate_limited '$QB'\""
printf 'Error: 429 too many requests, retry-after 30\n' > "$QB"
check "budget: a real 429 is not one" "! $QE"
# ★ A PERIODIC quota, caught on a live probe of copilot while the sweep this
# section was written for was running. It matched rate_limited() -- both via
# `quota (exceeded|exhausted)` and `exceeded your [a-z ]{0,20}quota` -- and so
# earned three backoff retries against a MONTHLY cap, the same kimi failure
# quota_exhausted exists to end, on a second provider. Worse, lib/grade.sh
# already recorded this exact sentence from an earlier session: the matcher was
# written without grepping the repo for the refusals it had already measured.
printf 'You have exceeded your monthly quota (Request ID: AF6C:DC7FE:A333A6)\n' > "$QB"
check "budget: monthly quota caught"  "$QE"
printf 'Request quota exceeded for this billing period.\n' > "$QB"
check "budget: billing period caught" "$QE"
# ★★ THE ONE THAT KEEPS THE TWO FUNCTIONS SEPARATE. agents.d/kiro.sh records
# "Kiro rate limit reached: Request quota exceeded" -- a THROUGHPUT refusal that a
# backoff really does clear. The discriminator is the PERIOD word, not the word
# "quota", so a bare "quota exceeded" must stay on the retry path. Widening the
# budget matcher to catch copilot must not steal this one.
printf 'Kiro rate limit reached: Request quota exceeded\n' > "$QB"
check "budget: bare quota stays a 429" "! $QE"
check "budget: and still retries"      "bash -c \"source '$ROOT/lib/common.sh'; rate_limited '$QB'\""
printf 'blocking: the billing details page leaks a token when payment required.\n' > "$QB"
check "budget: a finding about billing" "$QE"   # matches, but see below
# ...which is exactly why callers ask only about a run classify_run already
# called `failed`. A review is not a failed run, so the words never get asked
# about. Same guard rate_limited has carried since it shipped, same reason.
head -c 2100 /dev/zero | tr '\0' 'x' > "$QB"; printf 'spend limit\n' >> "$QB"
check "budget: too big to be a refusal" "! $QE"

# ★★ A USAGE WINDOW: the third refusal, and the two above prescribed the wrong
# action for it. Found by enumerating what this tool has ACTUALLY been handed
# (`cat ~/.local/state/cadre/*/*.failed | sort | uniq -c`) after a sweep died at
# 26 of 30 reviews -- four minutes before the window it was waiting on reopened.
# Both strings below are verbatim from that corpus, and NEITHER matched either
# existing classifier, so the run failed in two seconds with zero retries.
WC="bash -c \"source '$ROOT/lib/common.sh'; provider_window_closed '$QB'\""
RL="bash -c \"source '$ROOT/lib/common.sh'; rate_limited '$QB'\""
printf "You've hit your session limit · resets 7:10pm (America/New_York)\n" > "$QB"
check "window: session limit caught"   "$WC"
check "window: was NOT a rate limit"   "! $RL"
check "window: was NOT a budget"       "! $QE"
printf "You've hit your weekly limit · resets 5am (America/New_York)\n" > "$QB"
check "window: weekly limit caught"    "$WC"
check "window: weekly is not a budget" "! $QE"
# ★ THE ONE THAT KEEPS THIS FUNCTION HONEST, and the discriminator is not the
# period word this time -- "monthly spend limit" is a longer period than
# "weekly limit" and yet the opposite kind of refusal. It states WHERE TO PAY, not
# WHEN IT LIFTS, because only money lifts it. A stated reset is the whole test.
printf "You've hit your monthly spend limit · raise it at claude.ai/settings/usage\n" > "$QB"
check "window: a spend cap is NOT one" "! $WC"
check "window: it stays a budget"      "$QE"
# ★ And a THROUGHPUT ceiling with a short reset must stay on the retry path,
# where 60/120/240 backoff already clears it. Aborting a sweep over a
# one-minute wait would be the same overcorrection in the other direction.
printf 'Error: 429 rate limit exceeded, resets in 60s\n' > "$QB"
check "window: a 60s reset is not one" "! $WC"
check "window: it still retries"       "$RL"
printf 'Kiro rate limit reached: Request quota exceeded\n' > "$QB"
check "window: kiro stays a rate limit" "! $WC"
# ★★ THE SHADOWING TEST. quota_exhausted's pattern list contains `usage limit`,
# which is a WINDOW phrasing sitting in the BUDGET matcher, added speculatively in
# 96b9697 rather than from any observed string. Both functions claim this one, so
# the ORDER decides, and the wrong order gives it the treatment this whole section
# disproves: agent dropped for the sweep, exit 4, "fix the cause". Pinned here so
# the order stays deliberate instead of incidental.
printf "You've hit your usage limit · resets 3pm (America/New_York)\n" > "$QB"
check "window: claims 'usage limit'"   "$WC"
check "window: budget also claims it"  "$QE"
check "window: ...so window is asked FIRST" \
  "grep -n 'provider_window_closed\|quota_exhausted' '$ROOT/lib/run-pass.sh' | grep -m1 -q 'provider_window_closed'"
# And with no reset stated it stays a budget, which is the case that pattern was
# speculatively added for -- narrowing the shadowing must not delete it.
printf "You've hit your usage limit, upgrade your plan to continue\n" > "$QB"
check "window: bare usage limit is not" "! $WC"
check "window: bare one stays a budget" "$QE"
# Same length guard, same reason: a review OF a session-limiter says all of this.
head -c 2100 /dev/zero | tr '\0' 'x' > "$QB"
printf "hit your session limit, resets at midnight\n" >> "$QB"
check "window: too big to be a refusal" "! $WC"

# A candidate that is out of budget: refuses, and counts how often it was asked.
budget_case() {  # budget_case <dir>
  local d="$1" sha
  mkdir -p "$d/home/p1" "$d/home/p2"
  setup_agents "$d"
  new_repo "$d/checkout"
  sha=$(git -C "$d/checkout" rev-parse HEAD)
  printf '#### K1 blocking - the write is dropped\ntext\n' > "$d/home/k.md"
  { printf 'p1|%s|%s|%s|%s\n' "$sha" "$d/checkout" "$sha" "$d/home/k.md"
    printf 'p2|%s|%s|%s|%s\n' "$sha" "$d/checkout" "$sha" "$d/home/k.md"
  } > "$d/home/passes.conf"
  printf '#!/bin/sh\nexit 0\n' > "$d/bin/broke"; chmod +x "$d/bin/broke"
  cat > "$d/agents.d/broke.sh" <<A
run_broke() {
  echo call >> "$d/calls"
  echo "You've hit your monthly spend limit · raise it at claude.ai/settings/usage"
  return 1
}
A
}
D=$(mktemp -d -p "$SANDBOX"); budget_case "$D"
OUT=$(CADRE_HOME="$D/home" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      CADRE_JUDGE=good PATH="$D/bin:$PATH" "$ROOT/bin/cadre" run broke 2 2>&1); RC=$?
check "budget: asked exactly ONCE"    "[ \$(wc -l < '$D/calls') -eq 1 ]"
check "budget: says out of budget"    "grep -q 'OUT OF BUDGET, not a rate limit' <<<\"\$OUT\""
check "budget: aborts the sweep"      "grep -q 'ABORTING the sweep here' <<<\"\$OUT\""
check "budget: names the pass it quit on" "grep -q \"aborted on 'p1'\" <<<\"\$OUT\""
check "budget: p2 marked NOT ATTEMPTED"   "grep -q 'p2: NOT ATTEMPTED' <<<\"\$OUT\""
check "budget: verdict NOTHING MEASURED"  "grep -q 'Verdict: NOTHING MEASURED' <<<\"\$OUT\""
# ★ And here the reviews genuinely do NOT exist, so it is 4 and the sweep should
# stop. The pair of assertions is the point: same "nothing scored", opposite
# correct response, and only the exit code carries it to a driver.
check "budget: no review was produced"   "grep -q 'p1: no usable review, run-pass.sh exited 4' <<<\"\$OUT\""
# ★ THE ONE THAT WOULD HAVE CAUGHT IT. Everything above prints to stdout, and
# the driver that recorded COMPLETED sent stdout to /dev/null. Only the exit code
# reaches a shell loop that is not reading.
check "budget: exit 4, not 0"         "[ '$RC' -eq 4 ]"

# ★ The same sweep-level machinery for a closed WINDOW, which must reach a driver
# as a DIFFERENT code. 4 tells a driver the cause is a defect to go fix; 6 tells
# it to wait out the reset and re-invoke, at which point every review already on
# disk is reused. On 2026-07-28 that difference was 4 reviews versus 30.
D=$(mktemp -d -p "$SANDBOX"); budget_case "$D"
cat > "$D/agents.d/broke.sh" <<A
run_broke() {
  echo call >> "$D/calls"
  echo "You've hit your session limit · resets 7:10pm (America/New_York)"
  return 1
}
A
OUT=$(CADRE_HOME="$D/home" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      CADRE_JUDGE=good PATH="$D/bin:$PATH" "$ROOT/bin/cadre" run broke 2 2>&1); RC=$?
check "window: asked exactly ONCE"    "[ \$(wc -l < '$D/calls') -eq 1 ]"
check "window: says window CLOSED"    "grep -q 'usage window is CLOSED' <<<\"\$OUT\""
check "window: not called a budget"   "! grep -q 'OUT OF BUDGET' <<<\"\$OUT\""
check "window: aborts the sweep"      "grep -q 'ABORTING the sweep here' <<<\"\$OUT\""
check "window: p2 marked NOT ATTEMPTED" "grep -q 'p2: NOT ATTEMPTED' <<<\"\$OUT\""
# ★ The verdict must not read "failed measurement / fix the cause": there is
# nothing to fix, and by the time an operator read that message on 2026-07-28 the
# cause had already cleared itself.
check "window: verdict names the window" "grep -q 'Verdict: NOT MEASURED -- PROVIDER WINDOW CLOSED' <<<\"\$OUT\""
check "window: NOT 'NOTHING MEASURED'"   "! grep -q 'Verdict: NOTHING MEASURED' <<<\"\$OUT\""
check "window: does not say fix it"      "! grep -q 'Fix the cause and re-run' <<<\"\$OUT\""
check "window: says resume after reset"  "grep -q 'Resume after the reset time above' <<<\"\$OUT\""
# The reset time is the one fact a driver needs to schedule its own resumption,
# so it is quoted verbatim rather than parsed into a sleep in lib/.
check "window: quotes the reset time"    "grep -q 'resets 7:10pm' <<<\"\$OUT\""
# ★ THE ONE THAT REACHES A DRIVER THAT IS NOT READING STDOUT.
check "window: exit 6, not 4"            "[ '$RC' -eq 6 ]"

# ★★ THE PATH THE REAL INCIDENT TOOK, and the one above does NOT cover it. Above,
# the window closes on the FIRST pass, so graded_passes is 0 and the run lands in
# the nothing-was-graded block. On 2026-07-28 eight passes had already graded when
# the window closed, so the code falls straight past that block into the SLOT
# RECOMMENDATION -- and a seat computed from the passes that survived would be a
# report named after more than it measured, twice in one day.
D=$(mktemp -d -p "$SANDBOX"); budget_case "$D"
cat > "$D/agents.d/broke.sh" <<A
run_broke() {
  echo "You've hit your session limit · resets 7:10pm (America/New_York)"
  return 1
}
A
# p1 graded and PERFECT, so the slot logic would happily reach "SEAT:" off it.
SLB=$(slug broke)
printf 'blocking - the write is dropped\n' > "$D/home/p1/$SLB-run1.md"
printf '%s\n' "$HITBOTH" > "$D/home/p1/$SLB-run1.by-$(slug good).grade.json"
OUT=$(CADRE_HOME="$D/home" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      CADRE_JUDGE=good PATH="$D/bin:$PATH" "$ROOT/bin/cadre" run broke 1 2>&1); RC=$?
check "partial window: p1 still scored"  "grep -q 'K1=HIT' <<<\"\$OUT\""
check "partial window: NO seat off it"   "! grep -q 'Verdict: SEAT' <<<\"\$OUT\""
check "partial window: says INCOMPLETE"  "grep -q 'Verdict: INCOMPLETE, not slottable' <<<\"\$OUT\""
# ★ Right verdict, wrong instruction is the same defect as the wrong verdict:
# "restore the missing keys or checkouts" sends the operator hunting a broken
# registry when a clock stopped the sweep and there is nothing to restore.
check "partial window: not 'restore keys'" "! grep -q 'Restore the missing keys' <<<\"\$OUT\""
check "partial window: says wait + resume" "grep -q 'wait for the reset named above' <<<\"\$OUT\""
check "partial window: exit 6"           "[ '$RC' -eq 6 ]"

# A PARTIAL failure must NOT abort. 1 of 2 runs is still a review worth grading,
# and aborting there would throw away real output over a flake -- the opposite
# overcorrection, and just as wrong.
D=$(mktemp -d -p "$SANDBOX"); budget_case "$D"
SLB=$(slug broke)
printf 'blocking - the write is dropped\n' > "$D/home/p1/$SLB-run1.md"
printf '%s\n' "$HITBOTH" > "$D/home/p1/$SLB-run1.by-$(slug good).grade.json"
OUT=$(CADRE_HOME="$D/home" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      CADRE_JUDGE=good PATH="$D/bin:$PATH" "$ROOT/bin/cadre" run broke 2 p1 2>&1); RC=$?
check "partial: run1 still scored"    "grep -q 'K1=HIT' <<<\"\$OUT\""
check "partial: run2 is UNUSABLE"     "grep -q 'run 2: \*\*UNUSABLE\*\*' <<<\"\$OUT\""
check "partial: did NOT abort"        "! grep -q 'ABORTING' <<<\"\$OUT\""
check "partial: exit 0"               "[ '$RC' -eq 0 ]"

echo "== ★ inconclusive on the BENCHMARK path =="
# ★ Every other test of the fourth state drives `cadre review`. These two drive
# `cadre run`, which is the half a roster decision is actually made on, and the
# `inconclusive)` arm in run-pass.sh plus the reason line in grade.sh had no
# coverage at all until a review pointed that out.
D=$(mktemp -d -p "$SANDBOX"); budget_case "$D"
SLB=$(slug broke)
# Exits 0 with fluent prose, no findings, no verdict: the measured shape.
cat > "$D/agents.d/broke.sh" <<A
run_broke() {
  echo "I have looked over the changes you provided and they seem reasonable."
  echo "Several files are touched and the behaviour is extended throughout."
  return 0
}
A
# ★ run1 is pre-seeded as a real graded review so the pass has something usable
# and grading actually proceeds. With every run inconclusive there are zero usable
# reviews and the sweep bails before it writes any per-run reason line -- correct
# behaviour, and it makes run2 the only place to assert the reason. Same reason
# the partial test above seeds run1.
printf 'blocking - the write is dropped\n' > "$D/home/p1/$SLB-run1.md"
printf '%s\n' "$HITBOTH" > "$D/home/p1/$SLB-run1.by-$(slug good).grade.json"
OUT=$(CADRE_HOME="$D/home" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      CADRE_JUDGE=good PATH="$D/bin:$PATH" "$ROOT/bin/cadre" run broke 2 p1 2>&1); RC=$?
check "run: filed .md.inconclusive"   "ls '$D/home/p1'/$SLB-run2.md.inconclusive >/dev/null 2>&1"
check "run: NOT a scorable review"    "! ls '$D/home/p1'/$SLB-run2.md >/dev/null 2>&1"
check "run: NOT filed as failed"      "! ls '$D/home/p1'/$SLB-run2.md.failed >/dev/null 2>&1"
check "run: says INCONCLUSIVE"        "grep -q 'INCONCLUSIVE after' <<<\"\$OUT\""
check "run: says not scored"          "grep -q 'not scored' <<<\"\$OUT\""
check "run: run1 still scored"        "grep -q 'K1=HIT' <<<\"\$OUT\""
check "run: did NOT abort"            "! grep -q 'ABORTING' <<<\"\$OUT\""
# ★ The reason line must name the ROSTER problem, not the adapter. "the adapter
# failed" sends the reader to agents.d for a model that will not hold the brief.
check "grade: UNUSABLE names no review" "grep -q 'ran but returned no review' <<<\"\$OUT\""
check "grade: does NOT blame adapter"   "! grep -q 'the adapter failed' <<<\"\$OUT\""
# ★ .partial is deliberately kept across attempts while .inconclusive is cleared,
# so an earlier attempt's partial -- which HAS findings in it -- can still be on
# disk. Reporting only "no review" buries it, the same way the .failed path was
# already careful not to.
printf 'blocking - a real finding from the earlier attempt\n_TRUNCATED, stopped early.\n' \
  > "$D/home/p1/$SLB-run2.md.partial"
OUT=$(CADRE_HOME="$D/home" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      CADRE_JUDGE=good PATH="$D/bin:$PATH" "$ROOT/bin/cadre" grade broke 2 p1 2>&1)
check "grade: names surviving partial" "grep -q 'an earlier attempt stopped early' <<<\"\$OUT\""
check "grade: still says no review"    "grep -q 'ran but returned no review' <<<\"\$OUT\""

echo "== ★ a scoped run is one pass, and must not overwrite the gauntlet report =="
# THIRD instance of one bug: a report named after less than what identifies it.
# The judge went into the name, then the whole judge list -- and the pass scope
# was still missing, so a driver sweeping twelve passes one at a time wrote all
# twelve to the same path and each truncated the last. The artifact that survived
# the overnight run was 933 bytes describing the final pass.
check "scoped: its own report file"   "ls '$D/home'/report-*-only-p1-*.md >/dev/null 2>&1"
R=$(ls "$D/home"/report-*-only-p1-*.md | head -1)
check "scoped: says it is one pass"   "grep -q 'Scoped with a pass argument' '$R'"
# ★ Scoping to the ONLY registered pass excluded nothing, so warning "this is
# not the benchmark" there would be a false alarm on the smallest real setup.
# The guard asks what was left out, not whether an argument was passed.
D2=$(mktemp -d -p "$SANDBOX"); gauntlet_case "$D2" terse "$HITBOTH" "$HITBOTH"
OUT=$(run_gaunt "$D2" good,good2 terse)
R2=$(ls "$D2/home"/report-*.md | head -1)
check "scoped: one-pass registry seats" "grep -q 'Verdict: SEAT: can review alone' '$R2'"
check "scoped: no false scope warning"  "! grep -q 'SCOPED to one pass' '$R2'"

echo "== ★ <runs> is positional, so a flag in that slot is a silent zero =="
# This tool's own report printed `cadre grade <spec> --rescore`. seq 1 --rescore
# emits nothing, so zero runs were graded and the verdict read 0/0 about a
# candidate whose reviews were all on disk.
OUT=$(CADRE_HOME="$D2/home" CADRE_WORK="$D2/work" CADRE_AGENTS_D="$D2/agents.d" \
      CADRE_JUDGE=good PATH="$D2/bin:$PATH" "$ROOT/bin/cadre" grade terse --rescore 2>&1); RC=$?
check "runs: a flag is refused"       "grep -q 'runs must be a whole number' <<<\"\$OUT\""
check "runs: says there is no flag"   "grep -q 'no --rescore flag' <<<\"\$OUT\""
check "runs: exits nonzero"           "[ '$RC' -ne 0 ]"
OUT=$(CADRE_HOME="$D2/home" CADRE_WORK="$D2/work" CADRE_AGENTS_D="$D2/agents.d" \
      CADRE_JUDGE=good PATH="$D2/bin:$PATH" "$ROOT/bin/cadre" grade terse 0 2>&1)
check "runs: zero is refused too"     "grep -q 'at least 1' <<<\"\$OUT\""
# The report must not hand over a command it just refused.
check "runs: report hint is runnable" "! grep -q 'cadre grade .* --rescore' '$R2'"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
