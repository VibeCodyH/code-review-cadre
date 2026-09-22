#!/usr/bin/env bash
# Counts script exit receipts, not assertions or completed loop iterations.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
shopt -s nullglob
test_dir=${CADRE_TEST_DIR:-tests}
tests=("$test_dir"/*.sh)
discovered=${#tests[@]}
scratch=''

finish() {
  local status=$? run=0 passed=0 failed=0 index rc
  trap - EXIT
  for index in "${!tests[@]}"; do
    if [[ -z "$scratch" || ! -f "$scratch/$index.status" ]]; then
      printf 'ERROR: no exit receipt for %s\n' "${tests[$index]}" >&2
      if [[ -n "$scratch" && -s "$scratch/$index.log" ]]; then
        cat "$scratch/$index.log" || status=1
      fi
      continue
    fi
    if ! read -r rc < "$scratch/$index.status" || [[ ! "$rc" =~ ^[0-9]+$ ]]; then
      printf 'ERROR: invalid exit receipt for %s\n' "${tests[$index]}" >&2
      status=1
      continue
    fi
    run=$((run + 1))
    if [[ "$rc" == 0 ]]; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
  done
  printf '\nTests discovered: %d\nTests run: %d\nTests passed: %d\nTests failed: %d\n' \
    "$discovered" "$run" "$passed" "$failed"
  if (( discovered == 0 )); then
    printf 'ERROR: no tests discovered in %s/*.sh\n' "$test_dir" >&2
    status=1
  fi
  if (( discovered != run )); then
    printf 'ERROR: discovered %d tests but ran %d\n' "$discovered" "$run" >&2
    status=1
  fi
  if (( failed > 0 )); then status=1; fi
  if [[ -n "$scratch" ]]; then rm -rf -- "$scratch" || status=1; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
scratch=$(mktemp -d) || exit 1

for index in "${!tests[@]}"; do
  test_file=${tests[$index]}
  if [[ ! -f "$test_file" || ! -r "$test_file" ]]; then
    printf 'ERROR: cannot execute %s (missing, unreadable, or not a regular file)\n' "$test_file" >&2
    continue
  fi
  # Exit-contract lint (#82): the receipt is only as honest as the child's exit
  # status, and a script that fails then ends on `echo` exits 0. Require either
  # errexit near the top or the counter-style `[ "$FAIL" -eq 0 ]` as the last
  # statement; anything else is refused unrun. A proxy, not a proof: see
  # docs/ASSURANCE_CASE.md claim 18 for what it still misses.
  last_line=$(grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$test_file" | tail -n 1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  # One awk, not `head | grep -q`: under pipefail an early-exiting grep can hand
  # back head's SIGPIPE as the status (the #83 pi adapter bug).
  if ! awk 'NR > 15 { exit } /^[[:space:]]*set[[:space:]]+[^#]*-[A-Za-z]*e[A-Za-z]*/ { found = 1; exit } END { exit !found }' "$test_file" \
     && [[ "$last_line" != '[ "$FAIL" -eq 0 ]' ]]; then
    reason="no set -e in the first 15 lines, and the last line is not [ \"\$FAIL\" -eq 0 ] (got: $last_line)"
    printf 'FAIL %s (no exit contract: %s)\n' "$test_file" "$reason"
    printf '1\n' > "$scratch/$index.status" || exit 1
    printf 'no exit contract: %s\n' "$reason" > "$scratch/$index.log" || exit 1
    continue
  fi
  mkdir "$scratch/$index.home" || exit 1
  exec 3> "$scratch/$index.log" || exit 1
  env -i HOME="$scratch/$index.home" PATH=/usr/bin:/bin LC_ALL=C.UTF-8 CADRE_RETRY_WAIT=0 \
    bash "$test_file" >&3 2>&1
  rc=$?
  exec 3>&-
  # No receipt exists until the child has returned an exit status.
  printf '%s\n' "$rc" > "$scratch/$index.status" || exit 1
  if [[ "$rc" == 0 ]]; then
    printf 'PASS %s\n' "$test_file"
  else
    printf 'FAIL %s (exit %d)\n' "$test_file" "$rc"
    cat "$scratch/$index.log" || exit 1
  fi
done
