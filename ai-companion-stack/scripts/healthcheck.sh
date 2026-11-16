#!/usr/bin/env bash
# Checks llama-server health, SillyTavern basic auth (401 without / 200 with
# credentials) and GPU memory. Exit code = number of failed checks.
# Overrides: LLAMA_URL, ST_URL, ENV_FILE.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STACK_DIR=$(dirname -- "$SCRIPT_DIR")
ENV_FILE=${ENV_FILE:-$STACK_DIR/.env}

load_env() {
  local line key val
  [[ -f $1 ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key=${BASH_REMATCH[2]} val=${BASH_REMATCH[3]}
    if [[ $val =~ ^\"(.*)\"[[:space:]]*$ || $val =~ ^\'(.*)\'[[:space:]]*$ ]]; then
      val=${BASH_REMATCH[1]}
    else
      val=${val%%[[:space:]]#*}
      val=${val%"${val##*[![:space:]]}"}
    fi
    [[ -n ${!key+x} ]] || export "$key=$val"
  done <"$1"
}
load_env "$ENV_FILE"

LLAMA_URL=${LLAMA_URL:-http://127.0.0.1:${LLAMA_PORT:-8080}}
ST_URL=${ST_URL:-http://127.0.0.1:${ST_PORT:-8000}}
FAILS=0

pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
http_code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@" || true; }

code=$(http_code "$LLAMA_URL/health")
case $code in
  200) pass "llama-server $LLAMA_URL/health -> 200" ;;
  503) fail "llama-server $LLAMA_URL/health -> 503 (model still loading, retry shortly)" ;;
  000)
    # Compose may keep 8080 on the internal network only; fall back to the container healthcheck.
    cid=$(cd "$STACK_DIR" && docker compose ps -q llama 2>/dev/null || true)
    state=''
    [[ -z $cid ]] || state=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)
    if [[ $state == healthy ]]; then
      pass "llama-server container is healthy (not reachable from the host at $LLAMA_URL, as intended)"
    else
      fail "llama-server unreachable at $LLAMA_URL${state:+ (container state: $state)}"
    fi
    ;;
  *) fail "llama-server $LLAMA_URL/health -> $code" ;;
esac

code=$(http_code "$ST_URL/")
if [[ $code == 401 ]]; then
  pass "SillyTavern without credentials -> 401"
elif [[ $code == 200 ]]; then
  fail "SillyTavern without credentials -> 200: BASIC AUTH IS NOT ENFORCED, do not expose this port"
else
  fail "SillyTavern without credentials -> $code (expected 401)"
fi

if [[ -z ${ST_BASIC_AUTH_USER:-} || -z ${ST_BASIC_AUTH_PASSWORD:-} ]]; then
  fail "ST_BASIC_AUTH_USER / ST_BASIC_AUTH_PASSWORD not set (env or $ENV_FILE)"
else
  # Credentials go through a curl config on stdin so they never show up in `ps`.
  esc() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }
  code=$(printf 'user = "%s:%s"\n' "$(esc "$ST_BASIC_AUTH_USER")" "$(esc "$ST_BASIC_AUTH_PASSWORD")" |
    http_code -K - "$ST_URL/")
  case $code in
    200) pass "SillyTavern with credentials -> 200" ;;
    401) fail "SillyTavern with credentials -> 401 (running server uses different credentials; restart it after editing .env)" ;;
    429) fail "SillyTavern with credentials -> 429 (rate limited after failed logins; wait a minute)" ;;
    *) fail "SillyTavern with credentials -> $code (expected 200)" ;;
  esac
fi

if ! command -v nvidia-smi >/dev/null; then
  fail "nvidia-smi not found (no GPU visible in this environment)"
elif ! gpus=$(nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader,nounits 2>&1); then
  fail "nvidia-smi failed: $gpus"
else
  while IFS=, read -r idx name used total; do
    used=${used// /} total=${total// /}
    if [[ ! $used =~ ^[0-9]+$ || ! $total =~ ^[0-9]+$ || $total -eq 0 ]]; then
      warn "GPU${idx}:${name}: memory usage not reported"
      continue
    fi
    msg="GPU${idx}:${name}: ${used} / ${total} MiB used ($((used * 100 / total))%)"
    if ((total - used < 512)); then
      warn "$msg - under 512 MiB free; lower LLAMA_CTX or LLAMA_NGL if generation fails"
    elif ((used < 1024)); then
      warn "$msg - model does not appear to be loaded on this GPU"
    else
      pass "$msg"
    fi
  done <<<"$gpus"
fi

if ((FAILS)); then
  printf '%d check(s) failed\n' "$FAILS"
else
  printf 'all checks passed\n'
fi
exit "$FAILS"
