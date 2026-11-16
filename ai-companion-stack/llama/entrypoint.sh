#!/usr/bin/env bash
set -euo pipefail

: "${HF_REPO:=huihui-ai/Huihui-Qwen3.6-35B-A3B-abliterated-MTP-GGUF}"
: "${MODEL_FILE:=Huihui-Qwen3.6-35B-A3B-abliterated-ggml-model-Q4_K.gguf}"
: "${MODELS_DIR:=/models}"
: "${LLAMA_CTX:=262144}"
: "${LLAMA_NGL:=99}"
: "${LLAMA_SPEC_DRAFT_N_MAX:=6}"
: "${LLAMA_HOST:=0.0.0.0}"
: "${LLAMA_PORT:=8080}"
: "${LLAMA_EXTRA_ARGS:=}"

log() { printf '[llama] %s\n' "$*" >&2; }

model="${MODELS_DIR}/${MODEL_FILE}"
part="${model}.part"
url="https://huggingface.co/${HF_REPO}/resolve/main/${MODEL_FILE}"

auth=()
[[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${HF_TOKEN}")

fsize() { stat -c %s "$1" 2>/dev/null || echo 0; }

download_model() {
  mkdir -p "$(dirname "$model")"
  # HF answers the resolve URL with a redirect carrying the real size in X-Linked-Size.
  local want
  want="$(curl -fsSI --retry 5 "${auth[@]}" "$url" \
    | tr -d '\r' | awk 'tolower($1)=="x-linked-size:"{print $2; exit}')" || true
  [[ "$want" =~ ^[0-9]+$ ]] || want=""

  if [[ -z "$want" || "$(fsize "$part")" != "$want" ]]; then
    log "downloading ${HF_REPO}/${MODEL_FILE}${want:+ (${want} bytes)} -> ${model}"
    curl -fL -C - --retry 20 --retry-delay 5 --retry-all-errors --connect-timeout 30 \
      "${auth[@]}" -o "$part" "$url"
  fi
  if [[ -n "$want" && "$(fsize "$part")" != "$want" ]]; then
    log "FATAL: size mismatch for ${part}: got $(fsize "$part"), want ${want}. Restart to resume."
    exit 1
  fi
  mv -f "$part" "$model"
  log "model ready: ${model}"
}

if [[ -s "$model" ]]; then
  log "model present: ${model}"
else
  download_model
fi

# llama-server reads LLAMA_API_KEY itself; an empty value must not reach it.
[[ -n "${LLAMA_API_KEY:-}" ]] || unset LLAMA_API_KEY
unset HF_TOKEN

args=(
  -m "$model"
  -ngl "$LLAMA_NGL"
  -c "$LLAMA_CTX"
  -fa on
  -np 1
  --spec-type draft-mtp
  --spec-draft-n-max "$LLAMA_SPEC_DRAFT_N_MAX"
  --host "$LLAMA_HOST"
  --port "$LLAMA_PORT"
)
# shellcheck disable=SC2206  # intentional word splitting of user-supplied flags
extra=(${LLAMA_EXTRA_ARGS})

log "llama.cpp $(cat /etc/llama.cpp.rev 2>/dev/null || echo unknown)"
log "exec llama-server ${args[*]} ${extra[*]}"
exec llama-server "${args[@]}" "${extra[@]}" "$@"
