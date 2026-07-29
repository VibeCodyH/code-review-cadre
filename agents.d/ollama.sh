# agentcall adapter: ollama  (direct HTTP, no agent loop, no tools)

notes_ollama() {
  cat <<'NOTES'
Talks straight to an Ollama server's /api/generate. No agent loop, no tool
calls, no working directory. Built for the JUDGE seat: grading is text in,
JSON out, and a grader with filesystem access can go read the answer key
instead of grading. One did. See docs/METHOD.md §3.

Spec is  ollama:<host>/<model>  where <host> is a literal host[:port] or an
alias exported as CADRE_OLLAMA_<ALIAS>. Port defaults to 11434. With no host
in the spec, CADRE_OLLAMA_URL is used.

  CADRE_OLLAMA_URL=http://127.0.0.1:11434  CADRE_JUDGE=ollama:qwen3-judge
  CADRE_JUDGE=ollama:10.0.0.77/qwen3-judge
  CADRE_OLLAMA_BOX=http://10.0.0.77:11434  CADRE_JUDGE=ollama:box/qwen3-judge

Counts as installed only once one of those is exported. Its binary is curl,
which is on every machine, so without that gate cadre would report a reviewer
you cannot actually reach on a box with no Ollama anywhere.

CADRE_OLLAMA_NUM_CTX (default 24576) is sent every call. Ollama's own ~4K
default silently truncates a grading rubric before the review starts, and the
grade that comes back looks fine.
NOTES
}

# Every host this adapter could talk to, declared as env. NUM_CTX is tuning,
# not a host, so it does not count as configuration.
_ollama_hosts() {
  local v
  for v in ${!CADRE_OLLAMA_@}; do
    [ "$v" = CADRE_OLLAMA_NUM_CTX ] && continue
    [ -n "${!v}" ] && printf '%s\n' "$v"
  done
}

# Nothing named `ollama` has to be on PATH -- this adapter is curl and jq. But
# curl exists everywhere, so an unconditional `echo curl` would mark the seat
# installed on every machine and inflate the roster with a reviewer that cannot
# answer. Installed means A HOST IS KNOWABLE: declared as env, or carried by the
# spec being run. Otherwise it reports a binary that deliberately does not exist,
# so the name explains itself when it shows up as missing.
bin_ollama() {
  local ok=""
  [ -n "$(_ollama_hosts)" ] && ok=1
  # $model carries a host on a direct call. Do NOT reach for CADRE_JUDGE here to
  # cover the roster probe: agentcall unsets it on purpose (bin/agentcall:59),
  # because a judge spec sitting in an agent's environment is a hint about the
  # harness. Declaring the host as env is the supported way, and it is why the
  # alias form exists.
  case "${model:-}" in */*) ok=1 ;; esac
  [ -n "$ok" ] && { echo curl; return; }
  echo cadre-ollama-no-host-configured
}

run_ollama() {
  local host="" name="$model" base url ctx payload out err
  case "$model" in
    */*) host="${model%%/*}"; name="${model#*/}" ;;
  esac
  [ -n "$name" ] || die "ollama: spec has no model name"

  if [ -z "$host" ]; then
    base="${CADRE_OLLAMA_URL:-}"
    [ -n "$base" ] || die "ollama: no host in spec and CADRE_OLLAMA_URL is unset"
  else
    # An alias wins over a literal, so a host can move without touching a spec.
    local alias_var="CADRE_OLLAMA_$(printf '%s' "$host" | tr 'a-z.-' 'A-Z__')"
    base="${!alias_var:-}"
    if [ -z "$base" ]; then
      case "$host" in
        http://*|https://*) base="$host" ;;
        *:[0-9]*)           base="http://$host" ;;
        *)                  base="http://$host:11434" ;;
      esac
    fi
  fi
  url="$base/api/generate"
  ctx="${CADRE_OLLAMA_NUM_CTX:-24576}"

  if [ -n "$DRY" ]; then
    _run curl -sS --max-time "$TIMEOUT" "$url" -d '{"model":"'"$name"'","stream":false}'
    return 0
  fi

  # jq builds the body: a review or a key carries quotes, newlines and braces,
  # and hand-rolled JSON here corrupts the prompt rather than failing loudly.
  payload=$(jq -n --arg m "$name" --arg p "$prompt" --argjson c "$ctx" \
    '{model:$m, prompt:$p, stream:false, keep_alive:"30m",
      options:{temperature:0, num_ctx:$c}}') || die "ollama: could not build request"

  out=$(printf '%s' "$payload" \
    | curl -sS --max-time "$TIMEOUT" -H 'Content-Type: application/json' \
           --data-binary @- "$url" 2>&1) || {
    printf 'ollama: request to %s failed: %s\n' "$url" "$out"; return 1; }

  # A server-side error is a JSON object with .error and no .response. Printing
  # it is the point: an empty reply filed as a clean grade is the failure this
  # whole adapter exists to avoid.
  err=$(printf '%s' "$out" | jq -r '.error // empty' 2>/dev/null)
  [ -n "$err" ] && { printf 'ollama: %s returned: %s\n' "$name" "$err"; return 1; }

  printf '%s' "$out" | jq -er '.response' 2>/dev/null || {
    printf 'ollama: %s gave no .response field: %s\n' "$name" "${out:0:400}"; return 1; }
}
