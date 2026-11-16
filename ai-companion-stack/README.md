# AI companion stack

SillyTavern + llama.cpp `llama-server` + ElevenLabs TTS for a rented Linux GPU pod (RTX 4090 / 24 GB class), usable from phone and desktop browsers. Infrastructure and wiring only.

## Architecture

```
 phone / desktop browser
        |  HTTPS (pod proxy or tunnel), HTTP Basic Auth
        v
 +--------------------------+        +-------------------------------+
 | sillytavern  :8000       | -----> | llama  :8080 (not public)     |
 | ghcr.io/sillytavern/     |  HTTP  | llama-server, CUDA, draft-mtp |
 |   sillytavern:latest     |        | Qwen3.6-35B-A3B Q4_K GGUF     |
 +------------+-------------+        +---------------+---------------+
              |  HTTPS (server side)                 |
              v                                      |
      api.elevenlabs.io                              |
              |                                      |
              +---------- DATA_ROOT (persistent volume) ----------+
                models/  sillytavern/{config,data,plugins,extensions}
```

Only port 8000 is published. `llama-server` is reachable from SillyTavern (`http://llama:8080` in compose, `http://127.0.0.1:8080` in the no-Docker path) and from the pod's loopback, never from the internet.

| File | Purpose |
|---|---|
| `docker-compose.yml`, `.env.example` | Compose stack and its settings |
| `llama/Dockerfile`, `llama/entrypoint.sh` | Builds `llama-server` with CUDA, downloads the model, starts the server |
| `sillytavern/config.yaml`, `sillytavern/init.sh` | Remote-access config; installs it and seeds secrets before SillyTavern starts |
| `scripts/pod-start.sh` | Whole stack without Docker |
| `scripts/healthcheck.sh` | Checks both services |

## Prerequisites

- Pod with an NVIDIA GPU (24 GB VRAM), a recent driver (`nvidia-smi` works) and a persistent volume, assumed at `/workspace`. At least 40 GB free on it: the model is 21.7 GB, plus builds and data.
- Port 8000 exposed by the pod provider (HTTP proxy or TCP port mapping).
- Docker path: Docker Engine, the Compose plugin and the NVIDIA Container Toolkit (`docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi` works). Most rented pods are containers themselves and cannot run Docker; use the script path there.
- Script path: Ubuntu-style image with the CUDA toolkit (`nvcc`; a `-devel` image), root or sudo, outbound internet.
- An ElevenLabs API key for TTS (optional at deploy time).

## Deployment

### Common first steps

```bash
cd ai-companion-stack
cp .env.example .env
chmod 600 .env
openssl rand -base64 24        # use the output as ST_BASIC_AUTH_PASSWORD
nano .env
```

Values containing `$`, `#` or spaces must be wrapped in single quotes (`'...'`): that is literal in both Docker Compose and the scripts. Double quotes are not enough, because Compose still expands `$NAME` inside them and the password silently changes. Do not `source` the file from a shell. The `openssl` output above needs no quoting.

Set at least:

| Variable | Notes |
|---|---|
| `ST_BASIC_AUTH_USER` | Required. No `:` in it. |
| `ST_BASIC_AUTH_PASSWORD` | Required. Startup fails if it is empty, shorter than 12 characters, equal to the username, or a known default (`password`, `changeme`, ...). |
| `ELEVENLABS_API_KEY` | Optional. If set, seeded into SillyTavern's secrets as `api_key_elevenlabs`; otherwise paste it in the UI. |
| `DATA_ROOT` | Persistent volume path, default `/workspace/companion`. |
| `HF_REPO`, `MODEL_FILE` | Default `huihui-ai/Huihui-Qwen3.6-35B-A3B-abliterated-MTP-GGUF` / `Huihui-Qwen3.6-35B-A3B-abliterated-ggml-model-Q4_K.gguf`. |
| `LLAMA_CTX`, `LLAMA_NGL`, `LLAMA_SPEC_DRAFT_N_MAX` | Defaults `262144`, `99`, `6`. Read [VRAM](#vram-read-this-before-the-first-start) first. |
| `LLAMA_EXTRA_ARGS` | Extra `llama-server` flags, appended verbatim. |
| `HF_TOKEN`, `LLAMA_API_KEY` | Optional. |

The resulting command line is:

```
llama-server -m <model> -ngl 99 -c 262144 -fa on -np 1 \
  --spec-type draft-mtp --spec-draft-n-max 6 --host 0.0.0.0 --port 8080
```

In compose `0.0.0.0` is the container's own interface and the port is published on the host's loopback only. The no-Docker path passes `--host 127.0.0.1` instead (override with `LLAMA_HOST`), because there `0.0.0.0` would be the pod's real interface.

### Path 1: Docker Compose

```bash
# 1. Build llama-server (CUDA) and pull SillyTavern. The build takes 10-20 minutes.
docker compose build llama
docker compose pull sillytavern

# 2. Start. First start downloads the 21.7 GB model into $DATA_ROOT/models (resumable).
docker compose up -d

# 3. Watch the download and model load until the log shows
#    "listening on http://0.0.0.0:8080" and /health returns 200.
docker compose logs -f llama

# 4. Verify.
docker compose ps
curl -fsS http://127.0.0.1:8080/health                                   # {"status":"ok"}
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/          # 401
bash scripts/healthcheck.sh    # also checks 200 with the credentials from .env, and GPU memory
```

Then open the pod's URL for port 8000 and continue with [Connect SillyTavern to llama.cpp](#connect-sillytavern-to-llamacpp).

Day to day: apply `.env` changes with `docker compose up -d` (a plain `restart` does not re-read `.env`). Update with `docker compose pull sillytavern && docker compose build --pull --no-cache llama && docker compose up -d`. Pin llama.cpp with `LLAMA_CPP_REF`; match `CUDA_VERSION` to the pod's driver.

### Path 2: no Docker (pod is itself a container)

```bash
# 1. Keep the stack on the persistent volume so it survives pod restarts.
cd /workspace && git clone <this repo> && cd <repo>/ai-companion-stack
cp .env.example .env && chmod 600 .env && nano .env

# 2. Build llama.cpp with CUDA, install Node + SillyTavern (release branch), download the model, start both.
bash scripts/pod-start.sh

# 3. Verify.
bash scripts/pod-start.sh status
bash scripts/healthcheck.sh
tail -f "${DATA_ROOT:-/workspace/companion}"/logs/{llama,sillytavern}.log
```

`pod-start.sh` takes `start` (default), `stop`, `restart`, `status`; `POD_FOREGROUND=1` keeps it attached. It is idempotent: a second run skips the build, the model download and the installs, and only starts what is not running. Pid files left over from before a pod restart are ignored unless the pid still belongs to `llama-server` / SillyTavern. It builds llama.cpp as the model card specifies:

```bash
cmake llama.cpp -B llama.cpp/build -DBUILD_SHARED_LIBS=OFF -DGGML_CUDA=ON
cmake --build llama.cpp/build --config Release -j --target llama-server
```

Everything it installs lives under `DATA_ROOT` (`bin/`, `src/llama.cpp`, `node/`, `sillytavern/app`, `logs/`, `run/`). After a pod restart, run the same command again from a shell or SSH session. To make that automatic, set it as the pod's start command with `POD_FOREGROUND=1`:

```bash
POD_FOREGROUND=1 bash /workspace/<repo>/ai-companion-stack/scripts/pod-start.sh
```

`POD_FOREGROUND=1` is required there: without it the script returns once both services are up, and a container whose start command exits is stopped or restarted by the provider. If the provider's start command replaces the image's own entrypoint (SSH, Jupyter), chain it instead, for example `bash -c '<image start command> & POD_FOREGROUND=1 bash /workspace/.../scripts/pod-start.sh'`.

Here `llama-server` binds `127.0.0.1:8080`, so the SillyTavern API URL is `http://127.0.0.1:8080`. Rebuild llama.cpp with `LLAMA_REBUILD=1`, update SillyTavern with `ST_UPDATE=1`, apply `.env` changes with `restart`.

## config.yaml

`sillytavern/config.yaml`, installed into the persistent config dir by `sillytavern/init.sh` on every start. The two placeholders are replaced from `ST_BASIC_AUTH_USER` / `ST_BASIC_AUTH_PASSWORD`; credentials are never committed. Keys not listed get SillyTavern's defaults.

```yaml
dataRoot: ./data
listen: true
listenAddress:
  ipv4: 0.0.0.0
  ipv6: '[::]'
protocol:
  ipv4: true
  ipv6: false
port: 8000
browserLaunch:
  enabled: false
# IP whitelist off: with it on, only localhost passes. Basic auth is the gate.
whitelistMode: false
basicAuthMode: true
basicAuthUser:
  username: "__ST_BASIC_AUTH_USER__"
  password: "__ST_BASIC_AUTH_PASSWORD__"
# Disabled so pod proxy hostnames (e.g. *.proxy.runpod.net) are accepted.
hostWhitelist:
  enabled: false
  scan: true
  hosts: []
enableUserAccounts: false
securityOverride: false
```

In both paths the same settings are also pinned with SillyTavern's `SILLYTAVERN_<KEY>` environment overrides (`SILLYTAVERN_LISTEN`, `SILLYTAVERN_WHITELISTMODE`, `SILLYTAVERN_BASICAUTHMODE`, `SILLYTAVERN_BASICAUTHUSER_USERNAME`, `SILLYTAVERN_BASICAUTHUSER_PASSWORD`), which take precedence over the file, so a stale or edited config on the volume cannot switch auth off. Edit the template in the repo, not the installed copy: the installed copy is overwritten on each start.

## Connect SillyTavern to llama.cpp

1. Open SillyTavern and log in with the Basic Auth credentials.
2. Top bar, plug icon (**API Connections**).
3. **API**: `Text Completion`.
4. **API Type**: `llama.cpp`.
5. **API URL**: `http://llama:8080` (compose) or `http://127.0.0.1:8080` (no-Docker path). No trailing `/v1`.
6. Only if `LLAMA_API_KEY` is set: it is seeded on start as `api_key_llamacpp` in both paths, so the key field is already filled; otherwise leave it empty.
7. **Connect**. The status line shows the model name when it works.
8. Left panel (sliders icon): tick **Unlocked** next to **Context (tokens)** and set it to at most `LLAMA_CTX`, leaving room for the response length (Unlocked allows up to 524288). Alternatively tick **Derive context size from backend** on the API Connections panel, which reads `n_ctx` from `llama-server`.

The URL is resolved by the SillyTavern server, not by your browser. That is why `http://llama:8080` works from a phone, and why `127.0.0.1` is wrong inside compose.

## ElevenLabs TTS

1. Top bar, stacked-blocks icon (**Extensions**), open the **TTS** drawer.
2. **Select TTS Provider**: `ElevenLabs`.
3. API key: next to **ElevenLabs TTS Key**, press the key button (**Click to set**) and paste the key. It is stored server side in `data/default-user/secrets.json` as `api_key_elevenlabs`, not in the browser. If `ELEVENLABS_API_KEY` was in `.env`, the button is already highlighted and this step is done.
4. **Model**: pick one (`Eleven Flash v2.5` or `Turbo v2.5` for low latency, `Multilingual v2` or `Eleven v3` for quality).
5. Tick **Enabled**. The voice map below is not built while TTS is disabled.
6. Press **Reload** beside the provider dropdown, then **Available voices** to list and preview the voices on your account.
7. Voice map: with a chat open, the drawer lists one row per speaker.
   - **`[Default Voice]`**: set this first. It is the fallback for any speaker without its own voice.
   - Each character and your persona: choose a specific voice, `[Default Voice]` to inherit, or `disabled` to keep that speaker silent.
   - A character only appears once its chat (or a group containing it) is open; press **Reload** after adding characters.
8. Tick **Auto Generation** to speak every new reply automatically. Without it, use the **Narrate** (megaphone) button in a message's action menu. **Narrate by paragraphs (when streaming)** starts audio before the reply finishes.
9. Optional: **Narrate user messages**, **Only narrate "quotes"**, **Ignore \*text, even "quotes", inside asterisks\***, **Audio Playback Speed**.

Synthesis requests go from the SillyTavern server to `api.elevenlabs.io`, so the pod needs outbound HTTPS. Phones block audio until the page has been interacted with: tap the page once after loading.

## Persistence and backup

Everything stateful is under `DATA_ROOT` (default `/workspace/companion`) on the pod's persistent volume:

| Path under `DATA_ROOT` | Compose mount (`sillytavern` / `llama`) | Contents |
|---|---|---|
| `models/` | `/models` | GGUF files (21.7 GB, re-downloadable) |
| `sillytavern/config/` | `/home/node/app/config` | Installed `config.yaml` (contains the password) |
| `sillytavern/data/` | `/home/node/app/data` | Chats, characters, settings, `secrets.json` (API keys) |
| `sillytavern/plugins/` | `/home/node/app/plugins` | Server plugins |
| `sillytavern/extensions/` | `/home/node/app/public/scripts/extensions/third-party` | Third-party extensions |
| `bin/ src/ node/ sillytavern/app/ logs/ run/` | script path only | Built binaries, runtimes, logs (all rebuildable) |

Keep `.env` on the volume too (it lives next to the compose file; clone the repo under `/workspace`).

Backup, skipping the model:

```bash
tar -C "${DATA_ROOT:-/workspace/companion}" -czf "companion-$(date +%F).tgz" sillytavern/config sillytavern/data sillytavern/plugins sillytavern/extensions
```

The archive holds the Basic Auth password and API keys in plain text; store it accordingly. Restore by extracting into `DATA_ROOT` before starting. A persistent volume survives pod restarts, not deletion of the volume or, with some providers, termination of the pod: copy the archive off the pod.

## Access from phone and desktop

- **Pod HTTP proxy** (for example `https://<pod-id>-8000.proxy.runpod.net`): expose HTTP port 8000 in the pod settings and open the URL. TLS ends at the provider's proxy, so the Basic Auth header is encrypted in transit. Preferred for phones. `hostWhitelist` is disabled so these hostnames are accepted.
- **Mapped TCP port** (`http://<public-ip>:<mapped-port>`): plain HTTP. Basic Auth is only base64, so the password and all chat text are readable on the path. Do not use it as is. Options: an SSH tunnel (`ssh -L 8000:127.0.0.1:8000 <pod>` then `http://127.0.0.1:8000`; set `ST_BIND=127.0.0.1` in compose), Tailscale/WireGuard, a Cloudflare Tunnel, or a TLS reverse proxy (Caddy) in front of port 8000.
- Never publish port 8080. Compose binds it to `127.0.0.1`; the script path binds `llama-server` to `127.0.0.1`.
- Browsers ask for the Basic Auth username and password once per session. On a phone, use **Add to Home Screen** for an app-like window.
- More than five wrong passwords from one IP within a minute get HTTP 429 from SillyTavern's rate limiter; wait a minute.

### Auto-stop when idle (no-Docker path)

Set `IDLE_STOP_MINUTES` (for example `30`) as a pod environment variable or in `.env`. `scripts/idle-stop.sh` then stops the pod once neither `llama-server` nor SillyTavern has logged a request for that long, so a forgotten pod stops billing. It relies on `runpodctl` and the `RUNPOD_POD_ID` / `RUNPOD_API_KEY` variables that Runpod sets inside every pod; on other providers it disables itself. `0` (the default) turns it off. Its decisions are logged to `$DATA_ROOT/logs/idle-stop.log`.

## VRAM: read this before the first start

Sizes from `https://huggingface.co/api/models/huihui-ai/Huihui-Qwen3.6-35B-A3B-abliterated-MTP-GGUF/tree/main`:

| File | Bytes | GiB |
|---|---|---|
| `...-Q2_K.gguf` | 13,246,129,376 | 12.3 |
| `...-Q3_K.gguf` | 17,165,606,112 | 16.0 |
| `...-Q4_K.gguf` (default) | 21,712,409,824 | 20.2 |
| `...-Q5_K.gguf` | 25,346,479,328 | 23.6 |

A 24 GB card has 24 GiB minus driver overhead. With `-ngl 99` the Q4_K weights alone take 20.2 GiB, leaving under 4 GiB for the KV cache, the MTP draft head and compute buffers. The KV cache grows linearly with `-c`. **Q4_K fully offloaded with `-c 262144` should be expected not to fit in 24 GB.** The defaults are kept because they are the requested base command; this has not been run on a 4090 here, so treat the numbers below as starting points and read the real figures from the `llama-server` load log and `nvidia-smi`.

Knobs, in the order to try them (all in `.env`):

1. `LLAMA_CTX=32768` (then `16384`, `8192`). Biggest effect, no quality loss within the window. Lower SillyTavern's **Context (tokens)** to match.
2. `LLAMA_EXTRA_ARGS=-ctk q8_0 -ctv q8_0` roughly halves the KV cache.
3. `MODEL_FILE=Huihui-Qwen3.6-35B-A3B-abliterated-ggml-model-Q3_K.gguf` frees about 4 GiB for context at some quality cost.
4. `LLAMA_NGL=<n>` below the layer count keeps some layers on CPU: slower, but lets a long context coexist with Q4_K. Needs matching system RAM.
5. `LLAMA_EXTRA_ARGS=-nkvo` keeps the KV cache in system RAM (large slowdown; last resort).

Check for other processes holding VRAM with `nvidia-smi` before blaming the settings.

## Troubleshooting

Logs: `docker compose logs -f llama|sillytavern`, or `$DATA_ROOT/logs/{llama,sillytavern,llama-build}.log` in the script path. Quick check: `bash scripts/healthcheck.sh`.

| Symptom | Cause | Fix |
|---|---|---|
| SillyTavern **Connect** fails, "No connection" | API URL mismatch | Compose: `http://llama:8080` (inside the `sillytavern` container `127.0.0.1` is that container, not llama). Script path: `http://127.0.0.1:8080`. Never the pod's public URL, never `https`, no `/v1`. API must be `Text Completion` and API Type `llama.cpp`. |
| Connect fails right after start | Model still downloading or loading | `/health` returns 503 until loaded. Wait for `curl http://127.0.0.1:8080/health` to return `{"status":"ok"}`. |
| Connect returns 401 from llama | `LLAMA_API_KEY` set but SillyTavern has no or a different key | Apply `.env` (`docker compose up -d` or `pod-start.sh restart`) so `init.sh` seeds `api_key_llamacpp`, or set it via the key button on the llama.cpp connection; or clear `LLAMA_API_KEY`. |
| Browser shows 401 / keeps re-prompting | Wrong Basic Auth credentials, or `.env` changed without restart | Check `ST_BASIC_AUTH_USER` / `ST_BASIC_AUTH_PASSWORD` in `.env`; `docker compose up -d` or `pod-start.sh restart`. If the password contains `$`, `#` or spaces, wrap it in single quotes in `.env` (double quotes still let Compose expand `$NAME`), or generate one without them. |
| 429 after several wrong passwords | Basic Auth rate limiter (5 attempts per IP per minute) | Wait a minute, or restart `sillytavern`. |
| `sillytavern` exits at start with `FATAL` / `init.sh: ERROR` | Password empty, under 12 characters, equal to the user, or a known default | Set a real password in `.env`. This is deliberate: the stack refuses to run unauthenticated. |
| 403 Forbidden page, log says `Blocked connection from <ip>` | `whitelistMode` is on (edited config or override) | Keep `whitelistMode: false` in `sillytavern/config.yaml` and restart. Behind a proxy every client arrives with the proxy's IP, so IP whitelisting cannot work there. |
| Request refused on the proxy hostname, log mentions the host whitelist | `hostWhitelist.enabled: true` | Leave it `false`, or add the proxy hostname to `hostWhitelist.hosts`. |
| Works on the pod, not from the phone | Port 8000 not exposed, or bound to loopback | Expose 8000 in the pod settings; `ST_BIND=0.0.0.0`; test with `curl -I http://127.0.0.1:8000/` on the pod (expect 401). |
| `CUDA error: out of memory`, `failed to allocate`, `unable to allocate ... buffer`, or llama exits during load | Weights + KV cache exceed 24 GB | See [VRAM](#vram-read-this-before-the-first-start): lower `LLAMA_CTX` first, then KV quantization, a lower quant, or fewer GPU layers. |
| Loads, then OOM or crawl on long chats | Context fills beyond what fits | Lower `LLAMA_CTX` and SillyTavern's **Context (tokens)**. |
| `error: invalid argument: --spec-type` / `--spec-draft-n-max`, or `unknown speculative type: draft-mtp` | llama.cpp build predates MTP support | Rebuild from current `master`: `docker compose build --no-cache llama`, or `LLAMA_REBUILD=1 bash scripts/pod-start.sh restart`. Do not pin an old `LLAMA_CPP_REF`. |
| `could not select device driver "nvidia"` / no GPU in the container | NVIDIA Container Toolkit missing, or Docker unavailable in a containerized pod | Install the toolkit, or use `scripts/pod-start.sh`. |
| Build fails: CUDA not found / `nvcc` missing | Pod image has only the CUDA runtime | Use a `-devel` CUDA image for the pod, or the Docker path. In Docker, set `CUDA_VERSION` no newer than the driver supports. |
| Model download fails or stalls | Network drop, disk full, gated repo | Restart: the download resumes from the `.part` file. `df -h "$DATA_ROOT"` (need 22 GB+ free). Set `HF_TOKEN` for 401/403. Check `HF_REPO` / `MODEL_FILE` spelling against the HF file list (404). |
| `size mismatch` from the entrypoint | Truncated download | Restart to resume; if it repeats, delete the `.part` file in `$DATA_ROOT/models`. |
| Voice map empty after **Reload** | **Enabled** unticked: the map is only built while TTS is enabled | Tick **Enabled**, then **Reload**. |
| TTS silent, no error | **Enabled** unticked, **Auto Generation** off, or browser autoplay block | Tick both; tap the page once on mobile; check the device is not muted. |
| `<name> not in voicemap` toast | No voice for that speaker and no default | Set `[Default Voice]` in the voice map. |
| Empty voice list, or SillyTavern log shows `ElevenLabs API key not found` / `ElevenLabs synthesis failed: HTTP 401` | Key missing or invalid | Set it via **ElevenLabs TTS Key**, press **Reload**. Keys restricted by scope need text-to-speech and voices read access. |
| Log shows `ElevenLabs synthesis failed: HTTP 429` or a quota message | ElevenLabs character quota or concurrency limit | Check the ElevenLabs usage page; pick a cheaper model; narrate quotes only. |
| TTS fails with a network error in the SillyTavern log | Pod has no outbound HTTPS to `api.elevenlabs.io` | Fix pod egress; the request is made by the server, not the browser. |
| Settings or chats gone after a pod restart | `DATA_ROOT` not on the persistent volume | Point `DATA_ROOT` at the volume (`/workspace/...`) and restore from backup. |
