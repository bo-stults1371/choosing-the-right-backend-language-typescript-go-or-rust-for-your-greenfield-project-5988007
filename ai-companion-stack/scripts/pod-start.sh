#!/usr/bin/env bash
# No-Docker path: runs llama-server + SillyTavern directly on a GPU pod.
# Everything persistent lives under DATA_ROOT. Safe to re-run after a restart.
# Usage: pod-start.sh [start|stop|restart|status]   (POD_FOREGROUND=1 to block)
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STACK_DIR=$(dirname -- "$SCRIPT_DIR")
ENV_FILE=${ENV_FILE:-$STACK_DIR/.env}
INIT_SH=$STACK_DIR/sillytavern/init.sh

log() { printf '[pod-start] %s\n' "$*"; }
die() { printf '[pod-start] ERROR: %s\n' "$*" >&2; exit 1; }

# Reads KEY=VALUE lines without eval; variables already in the environment win.
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

DATA_ROOT=${DATA_ROOT:-/workspace/companion}
[[ $DATA_ROOT == /?* ]] || die "DATA_ROOT must be an absolute path"
DATA_ROOT=${DATA_ROOT%/}
HF_REPO=${HF_REPO:-huihui-ai/Huihui-Qwen3.6-35B-A3B-abliterated-MTP-GGUF}
MODEL_FILE=${MODEL_FILE:-Huihui-Qwen3.6-35B-A3B-abliterated-ggml-model-Q4_K.gguf}
LLAMA_CTX=${LLAMA_CTX:-262144}
LLAMA_NGL=${LLAMA_NGL:-99}
LLAMA_SPEC_DRAFT_N_MAX=${LLAMA_SPEC_DRAFT_N_MAX:-6}
LLAMA_EXTRA_ARGS=${LLAMA_EXTRA_ARGS:-}
LLAMA_HOST=${LLAMA_HOST:-127.0.0.1}
LLAMA_PORT=${LLAMA_PORT:-8080}
LLAMA_CPP_REF=${LLAMA_CPP_REF:-master}
LLAMA_REBUILD=${LLAMA_REBUILD:-0}
LLAMA_WAIT_SECS=${LLAMA_WAIT_SECS:-900}
ST_PORT=${ST_PORT:-8000}
ST_BRANCH=${ST_BRANCH:-release}
ST_UPDATE=${ST_UPDATE:-0}
NODE_MAJOR=${NODE_MAJOR:-22}
export ST_BASIC_AUTH_USER=${ST_BASIC_AUTH_USER:-} ST_BASIC_AUTH_PASSWORD=${ST_BASIC_AUTH_PASSWORD:-}
export ELEVENLABS_API_KEY=${ELEVENLABS_API_KEY:-}
# llama-server reads LLAMA_API_KEY from the environment; an empty value must not reach it.
if [[ -n ${LLAMA_API_KEY:-} ]]; then export LLAMA_API_KEY; else unset LLAMA_API_KEY; fi

MODELS_DIR=$DATA_ROOT/models
BIN_DIR=$DATA_ROOT/bin
LOG_DIR=$DATA_ROOT/logs
RUN_DIR=$DATA_ROOT/run
LLAMA_SRC=$DATA_ROOT/src/llama.cpp
NODE_DIR=$DATA_ROOT/node
ST_ROOT=$DATA_ROOT/sillytavern
ST_APP=$ST_ROOT/app
export ST_CONFIG_DIR=$ST_ROOT/config ST_DATA_DIR=$ST_ROOT/data
export ST_CONFIG_TEMPLATE=$STACK_DIR/sillytavern/config.yaml
LLAMA_BIN=$BIN_DIR/llama-server
MODEL_PATH=$MODELS_DIR/$MODEL_FILE

SUDO=()
[[ $(id -u) -eq 0 ]] || SUDO=(sudo)

pid_of() { cat "$RUN_DIR/$1.pid" 2>/dev/null || true; }
# Pid files survive pod restarts, so a pid only counts if it is still our process.
is_running() {
  local pid cmd
  pid=$(pid_of "$1")
  [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/cmdline ]] || return 1
  cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
  case $1 in
    llama) [[ $cmd == *"$LLAMA_BIN "* ]] ;;
    sillytavern) [[ $cmd == *"server.js "*"--dataRoot $ST_DATA_DIR "* ]] ;;
    *) return 1 ;;
  esac
}

stop_one() {
  local name=${1:?} pid i
  pid=$(pid_of "$name")
  if is_running "$name"; then
    log "stopping $name (pid $pid)"
    kill "$pid" 2>/dev/null || true
    for ((i = 0; i < 30; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
  fi
  rm -f "${RUN_DIR:?}/$name.pid"
}

spawn() {
  local name=$1; shift
  [[ ! -s $LOG_DIR/$name.log ]] || mv -f "$LOG_DIR/$name.log" "$LOG_DIR/$name.log.1"
  rm -f "${RUN_DIR:?}/$name.pid"
  # The child records its own pid: setsid may fork, which would make $! wrong.
  # shellcheck disable=SC2016
  setsid nohup bash -c 'echo $$ >"$0" && exec "$@"' "$RUN_DIR/$name.pid" "$@" \
    >"$LOG_DIR/$name.log" 2>&1 </dev/null &
  local i
  for ((i = 0; i < 50; i++)); do [[ -s $RUN_DIR/$name.pid ]] && break; sleep 0.1; done
  log "started $name (pid $(pid_of "$name")), log: $LOG_DIR/$name.log"
}

wait_http() {
  local name=$1 url=$2 want=$3 secs=$4 code t=0
  while ((t < secs)); do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" || true)
    [[ $code != "$want" ]] || return 0
    if ! is_running "$name"; then
      tail -n 30 "$LOG_DIR/$name.log" >&2 || true
      die "$name exited, see $LOG_DIR/$name.log"
    fi
    sleep 3; t=$((t + 3))
  done
  return 1
}

install_packages() {
  local need=() cmd
  for cmd in git cmake g++ make curl xz setsid; do command -v "$cmd" >/dev/null || need+=("$cmd"); done
  [[ -e /usr/include/openssl/ssl.h ]] || need+=(libssl-dev)
  ((${#need[@]})) || return 0
  command -v apt-get >/dev/null || die "missing tools (${need[*]}) and no apt-get; install them manually"
  log "installing system packages (missing: ${need[*]})"
  "${SUDO[@]}" apt-get update -qq
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    ca-certificates curl git cmake build-essential libssl-dev xz-utils util-linux >/dev/null
}

build_llama() {
  if [[ -x $LLAMA_BIN && $LLAMA_REBUILD != 1 ]]; then
    log "llama-server already built: $LLAMA_BIN (LLAMA_REBUILD=1 to rebuild)"
    return 0
  fi
  if ! command -v nvcc >/dev/null; then
    [[ -x /usr/local/cuda/bin/nvcc ]] || die "CUDA toolkit (nvcc) not found; use a CUDA *-devel pod image"
    export PATH=/usr/local/cuda/bin:$PATH
  fi
  if [[ -d $LLAMA_SRC/.git ]]; then
    git -C "$LLAMA_SRC" fetch -q --depth 1 origin "$LLAMA_CPP_REF"
    git -C "$LLAMA_SRC" checkout -q --detach FETCH_HEAD
  else
    # init+fetch works for a branch, a tag or a commit SHA.
    rm -rf -- "${LLAMA_SRC:?}"
    git init -q "$LLAMA_SRC"
    git -C "$LLAMA_SRC" remote add origin https://github.com/ggml-org/llama.cpp
    git -C "$LLAMA_SRC" fetch -q --depth 1 origin "$LLAMA_CPP_REF"
    git -C "$LLAMA_SRC" checkout -q --detach FETCH_HEAD
  fi
  log "building llama-server with CUDA ($(git -C "$LLAMA_SRC" rev-parse --short HEAD)); this takes a while"
  cmake -S "$LLAMA_SRC" -B "$LLAMA_SRC/build" -DBUILD_SHARED_LIBS=OFF -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release \
    >"$LOG_DIR/llama-build.log" 2>&1 || die "cmake configure failed, see $LOG_DIR/llama-build.log"
  cmake --build "$LLAMA_SRC/build" --config Release -j "$(nproc)" --target llama-server \
    >>"$LOG_DIR/llama-build.log" 2>&1 || die "llama.cpp build failed, see $LOG_DIR/llama-build.log"
  install -m 0755 "$LLAMA_SRC/build/bin/llama-server" "$LLAMA_BIN.new"
  mv -f "$LLAMA_BIN.new" "$LLAMA_BIN"
}

download_model() {
  if [[ -s $MODEL_PATH ]]; then log "model present: $MODEL_PATH"; return 0; fi
  local url="https://huggingface.co/$HF_REPO/resolve/main/$MODEL_FILE" auth=()
  [[ -z ${HF_TOKEN:-} ]] || auth=(-H "Authorization: Bearer $HF_TOKEN")
  log "downloading $HF_REPO/$MODEL_FILE (resumable)"
  curl -fL --retry 10 --retry-delay 5 --retry-all-errors -C - "${auth[@]}" -o "$MODEL_PATH.part" "$url" ||
    die "model download failed (re-run to resume; set HF_TOKEN if the repo is gated)"
  mv -f "$MODEL_PATH.part" "$MODEL_PATH"
}

install_node() {
  export PATH=$NODE_DIR/bin:$PATH
  local have arch base file sum
  have=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  ((have < 20)) || return 0
  case $(uname -m) in
    x86_64) arch=x64 ;;
    aarch64) arch=arm64 ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac
  base=https://nodejs.org/dist/latest-v$NODE_MAJOR.x
  read -r sum file < <(curl -fsSL "$base/SHASUMS256.txt" | grep "linux-$arch.tar.xz\$") ||
    die "cannot resolve the Node.js $NODE_MAJOR release"
  log "installing $file into $NODE_DIR"
  curl -fsSL --retry 5 -o "$RUN_DIR/$file" "$base/$file"
  echo "$sum  $RUN_DIR/$file" | sha256sum -c --quiet - || die "Node.js checksum mismatch"
  mkdir -p "$NODE_DIR"
  tar -xJf "$RUN_DIR/$file" -C "$NODE_DIR" --strip-components=1
  rm -f "${RUN_DIR:?}/${file:?}"
}

# Same layout as the Docker volumes: app subdir -> persistent dir.
link_dir() {
  local link=${1:?} target=${2:?} entry
  mkdir -p "$target"
  if [[ ! -L $link && -d $link ]]; then
    for entry in "$link"/* "$link"/.[!.]*; do
      [[ ! -e $entry || -e $target/${entry##*/} ]] || mv "$entry" "$target/"
    done
    rm -rf -- "${link:?}"
  fi
  ln -sfn "$target" "$link"
}

install_sillytavern() {
  local fresh=0 lock
  if [[ ! -d $ST_APP/.git ]]; then
    [[ ! -e $ST_APP ]] || die "$ST_APP exists but is not a git checkout; move it away and re-run"
    log "cloning SillyTavern ($ST_BRANCH)"
    git clone -q --depth 1 --branch "$ST_BRANCH" https://github.com/SillyTavern/SillyTavern "$ST_APP"
    fresh=1
  elif [[ $ST_UPDATE == 1 ]]; then
    log "updating SillyTavern ($ST_BRANCH)"
    git -C "$ST_APP" fetch -q --depth 1 origin "$ST_BRANCH"
    git -C "$ST_APP" reset -q --hard FETCH_HEAD
    fresh=1
  fi
  lock=$(sha256sum "$ST_APP/package-lock.json" | cut -d' ' -f1)
  if [[ $fresh == 1 || ! -d $ST_APP/node_modules || $(cat "$ST_APP/.deps-installed" 2>/dev/null) != "$lock" ]]; then
    log "installing SillyTavern npm packages"
    (cd "$ST_APP" && NODE_ENV=production npm ci --no-audit --no-fund --loglevel=error --omit=dev --ignore-scripts)
    echo "$lock" >"$ST_APP/.deps-installed"
  fi
  link_dir "$ST_APP/plugins" "$ST_ROOT/plugins"
  link_dir "$ST_APP/public/scripts/extensions/third-party" "$ST_ROOT/extensions"
  ln -sfn "$ST_CONFIG_DIR/config.yaml" "$ST_APP/config.yaml"
  # Extension installs/updates run git inside the persistent extensions dir.
  git config --global --get-all safe.directory 2>/dev/null | grep -qxF '*' ||
    git config --global --add safe.directory '*'
}

start_llama() {
  if is_running llama; then log "llama-server already running (pid $(pid_of llama))"; return 0; fi
  local args=(-m "$MODEL_PATH" -ngl "$LLAMA_NGL" -c "$LLAMA_CTX" -fa on -np 1
    --spec-type draft-mtp --spec-draft-n-max "$LLAMA_SPEC_DRAFT_N_MAX"
    --host "$LLAMA_HOST" --port "$LLAMA_PORT")
  # shellcheck disable=SC2086
  spawn llama "$LLAMA_BIN" "${args[@]}" $LLAMA_EXTRA_ARGS
}

start_sillytavern() {
  if is_running sillytavern; then
    log "SillyTavern already running (pid $(pid_of sillytavern)); use 'restart' to apply config changes"
    return 0
  fi
  cd "$ST_APP"
  node src/server-init.js >"$LOG_DIR/sillytavern-init.log" 2>&1 || true
  # SILLYTAVERN_<KEY> overrides config.yaml, so a stale config cannot switch auth off.
  NODE_ENV=production SILLYTAVERN_LISTEN=true SILLYTAVERN_WHITELISTMODE=false \
    SILLYTAVERN_BASICAUTHMODE=true SILLYTAVERN_BROWSERLAUNCH_ENABLED=false \
    SILLYTAVERN_BASICAUTHUSER_USERNAME=$ST_BASIC_AUTH_USER \
    SILLYTAVERN_BASICAUTHUSER_PASSWORD=$ST_BASIC_AUTH_PASSWORD \
    spawn sillytavern node server.js --listen --port "$ST_PORT" --dataRoot "$ST_DATA_DIR"
  cd - >/dev/null
}

do_start() {
  # Reject bad credentials before any long build or download.
  ST_INIT_CHECK_ONLY=1 sh "$INIT_SH" || die "fix ST_BASIC_AUTH_USER / ST_BASIC_AUTH_PASSWORD in $ENV_FILE"
  mkdir -p "$MODELS_DIR" "$BIN_DIR" "$LOG_DIR" "$RUN_DIR" \
    "$ST_CONFIG_DIR" "$ST_DATA_DIR" "$ST_ROOT/plugins" "$ST_ROOT/extensions"
  install_packages
  install_node
  build_llama
  download_model
  install_sillytavern
  sh "$INIT_SH"
  start_llama
  start_sillytavern

  if ! wait_http sillytavern "http://127.0.0.1:$ST_PORT/" 401 180; then
    stop_one sillytavern
    die "SillyTavern did not answer 401 to an unauthenticated request; stopped it, see $LOG_DIR/sillytavern.log"
  fi
  log "SillyTavern up on :$ST_PORT (basic auth enforced)"
  log "waiting for llama-server to load the model (up to ${LLAMA_WAIT_SECS}s)"
  wait_http llama "http://127.0.0.1:$LLAMA_PORT/health" 200 "$LLAMA_WAIT_SECS" ||
    die "llama-server not healthy after ${LLAMA_WAIT_SECS}s, see $LOG_DIR/llama.log"
  log "llama-server healthy on $LLAMA_HOST:$LLAMA_PORT"
  log "ready: expose port $ST_PORT; in SillyTavern: Text Completion -> llama.cpp -> http://127.0.0.1:$LLAMA_PORT"
}

do_status() {
  local name rc=0
  for name in llama sillytavern; do
    if is_running "$name"; then log "$name: running (pid $(pid_of "$name"))"; else log "$name: stopped"; rc=1; fi
  done
  return "$rc"
}

case ${1:-start} in
  start) do_start ;;
  stop) stop_one sillytavern; stop_one llama; exit 0 ;;
  restart) stop_one sillytavern; stop_one llama; do_start ;;
  status) do_status; exit ;;
  *) die "usage: $0 [start|stop|restart|status]" ;;
esac

if [[ ${POD_FOREGROUND:-0} == 1 ]]; then
  exec tail -n 0 -F "$LOG_DIR/llama.log" "$LOG_DIR/sillytavern.log"
fi
