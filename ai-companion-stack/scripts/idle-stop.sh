#!/usr/bin/env bash
# Stops this pod after IDLE_STOP_MINUTES with no chat activity, so a forgotten
# pod does not keep billing. Activity = llama-server or SillyTavern wrote to its
# log (every request does). Started by pod-start.sh; 0 or unset disables it.
set -uo pipefail

IDLE_STOP_MINUTES=${IDLE_STOP_MINUTES:-0}
LOG_DIR=${LOG_DIR:?LOG_DIR is required}
POD_ID=${RUNPOD_POD_ID:-}
CHECK_SECS=${IDLE_CHECK_SECS:-60}

log() { printf '[idle-stop] %s\n' "$*"; }

[[ $IDLE_STOP_MINUTES =~ ^[0-9]+$ ]] || { log "IDLE_STOP_MINUTES must be a whole number; disabled"; exit 0; }
((IDLE_STOP_MINUTES > 0)) || exit 0
[[ -n $POD_ID ]] || { log "RUNPOD_POD_ID is not set (not a Runpod pod?); disabled"; exit 0; }

signature() { stat -c '%s' "$LOG_DIR/llama.log" "$LOG_DIR/sillytavern.log" 2>/dev/null | tr '\n' ' '; }

stop_pod() {
  if command -v runpodctl >/dev/null 2>&1; then
    runpodctl pod stop "$POD_ID" && return 0
    runpodctl stop pod "$POD_ID" && return 0
  fi
  [[ -n ${RUNPOD_API_KEY:-} ]] || return 1
  curl -fsS -m 30 -X POST "https://api.runpod.io/v2/pods/$POD_ID/action" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" -H 'Content-Type: application/json' \
    -d '{"action":"stop"}' >/dev/null
}

log "will stop pod $POD_ID after $IDLE_STOP_MINUTES min without activity"
last=$(signature)
idle=0
while sleep "$CHECK_SECS"; do
  now=$(signature)
  if [[ $now != "$last" ]]; then
    last=$now
    idle=0
    continue
  fi
  idle=$((idle + CHECK_SECS))
  if ((idle >= IDLE_STOP_MINUTES * 60)); then
    log "idle for $IDLE_STOP_MINUTES min; stopping pod $POD_ID"
    if stop_pod; then exit 0; fi
    log "could not stop the pod (no working runpodctl or API key); will retry in 10 min"
    idle=$((IDLE_STOP_MINUTES * 60 - 600))
    ((idle >= 0)) || idle=0
  fi
done
