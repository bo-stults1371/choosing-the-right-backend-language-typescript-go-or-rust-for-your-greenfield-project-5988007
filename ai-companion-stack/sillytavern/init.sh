#!/bin/sh
# Installs config.yaml into the persistent config dir, injects basic-auth
# credentials, seeds API secrets, then execs "$@" (if given).
# POSIX sh: runs in the official Alpine image and on bare pods. Needs node.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
: "${ST_CONFIG_TEMPLATE:=$HERE/config.yaml}"
: "${ST_CONFIG_DIR:=/home/node/app/config}"
: "${ST_DATA_DIR:=/home/node/app/data}"
: "${ST_USER_HANDLE:=default-user}"
: "${ST_BASIC_AUTH_USER:=}"
: "${ST_BASIC_AUTH_PASSWORD:=}"
: "${ELEVENLABS_API_KEY:=}"
: "${LLAMA_API_KEY:=}"

die() { echo "init.sh: ERROR: $*" >&2; exit 1; }

[ -n "$ST_BASIC_AUTH_USER" ] || die "ST_BASIC_AUTH_USER is empty"
case "$ST_BASIC_AUTH_USER" in *:*) die "ST_BASIC_AUTH_USER must not contain ':'" ;; esac
[ -n "$ST_BASIC_AUTH_PASSWORD" ] || die "ST_BASIC_AUTH_PASSWORD is empty"
[ "${#ST_BASIC_AUTH_PASSWORD}" -ge 12 ] || die "ST_BASIC_AUTH_PASSWORD must be at least 12 characters"
[ "$ST_BASIC_AUTH_PASSWORD" != "$ST_BASIC_AUTH_USER" ] || die "ST_BASIC_AUTH_PASSWORD must differ from the username"
case "$(printf %s "$ST_BASIC_AUTH_PASSWORD" | tr '[:upper:]' '[:lower:]')" in
  password*|changeme*|change-me*|change_me*|changethis*|replace-me*|replace_me*|your-password*|your_password*|__st_basic_auth*|123456789012*|sillytavern|sillytavern123)
    die "ST_BASIC_AUTH_PASSWORD is a known default; set a real one" ;;
esac
[ "${ST_INIT_CHECK_ONLY:-0}" != 1 ] || exit 0

[ -f "$ST_CONFIG_TEMPLATE" ] || die "config template not found: $ST_CONFIG_TEMPLATE"
command -v node >/dev/null 2>&1 || die "node not found in PATH"

umask 077
mkdir -p "$ST_CONFIG_DIR" "$ST_DATA_DIR/$ST_USER_HANDLE"
export ST_CONFIG_TEMPLATE ST_CONFIG_DIR ST_DATA_DIR ST_USER_HANDLE \
  ST_BASIC_AUTH_USER ST_BASIC_AUTH_PASSWORD ELEVENLABS_API_KEY LLAMA_API_KEY

node - <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const env = process.env;

const writeAtomic = (file, text) => {
    const tmp = `${file}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, text, { mode: 0o600 });
    fs.renameSync(tmp, file);
};

// JSON strings are valid YAML double-quoted scalars.
const template = fs.readFileSync(env.ST_CONFIG_TEMPLATE, 'utf8');
const config = template
    .replace('"__ST_BASIC_AUTH_USER__"', () => JSON.stringify(env.ST_BASIC_AUTH_USER))
    .replace('"__ST_BASIC_AUTH_PASSWORD__"', () => JSON.stringify(env.ST_BASIC_AUTH_PASSWORD));
if (config === template || /^\s*(username|password): "__ST_BASIC_AUTH_/m.test(config)) {
    console.error('init.sh: ERROR: credential placeholders missing from config template');
    process.exit(1);
}
writeAtomic(path.join(env.ST_CONFIG_DIR, 'config.yaml'), config);

const seeds = {
    api_key_elevenlabs: env.ELEVENLABS_API_KEY,
    api_key_llamacpp: env.LLAMA_API_KEY,
};
const file = path.join(env.ST_DATA_DIR, env.ST_USER_HANDLE, 'secrets.json');
let secrets = {};
if (fs.existsSync(file)) {
    try {
        secrets = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (err) {
        console.error(`init.sh: ERROR: cannot parse ${file}: ${err.message}`);
        process.exit(1);
    }
}
// Legacy files hold flat strings; SillyTavern migrates those itself on start.
const legacy = !secrets._migrated && Object.values(secrets).length > 0
    && !Object.values(secrets).some(Array.isArray);
let changed = false;
for (const [key, raw] of Object.entries(seeds)) {
    const value = (raw || '').trim();
    if (!value) continue;
    if (legacy) {
        if (secrets[key] !== value) { secrets[key] = value; changed = true; }
        continue;
    }
    const list = Array.isArray(secrets[key]) ? secrets[key] : [];
    const current = list.find(s => s.value === value);
    if (current && current.active) continue;
    list.forEach(s => { s.active = false; });
    if (current) current.active = true;
    else list.push({ id: crypto.randomUUID(), value, label: 'env', active: true });
    secrets[key] = list;
    changed = true;
    console.log(`init.sh: seeded secret ${key}`);
}
if (changed) writeAtomic(file, JSON.stringify(secrets, null, 4));
NODE

# Official image drops to the "node" user when PUID/PGID are set.
if [ "$(id -u)" = 0 ] && [ -n "${PUID:-}" ] && [ -n "${PGID:-}" ]; then
  chown "$PUID:$PGID" "$ST_CONFIG_DIR" "$ST_CONFIG_DIR/config.yaml" \
    "$ST_DATA_DIR" "$ST_DATA_DIR/$ST_USER_HANDLE"
  [ ! -f "$ST_DATA_DIR/$ST_USER_HANDLE/secrets.json" ] ||
    chown "$PUID:$PGID" "$ST_DATA_DIR/$ST_USER_HANDLE/secrets.json"
fi

echo "init.sh: config installed at $ST_CONFIG_DIR/config.yaml (basic auth user: $ST_BASIC_AUTH_USER)"
[ "$#" -eq 0 ] || exec "$@"
