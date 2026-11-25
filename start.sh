#!/usr/bin/env bash
# start.sh — boot the webport server, bring up its Cloudflare tunnel, and keep
# the static gate pointed at the public origin.
#
#   ./start.sh                      reuse a healthy tunnel, else start one
#   ./start.sh --fresh              stop the recorded tunnel, then start a new one
#   ./start.sh --no-worker          point config.js at the tunnel instead of the Worker
#   ./start.sh --health <url>       exit 0 only for a 2xx (test hook)
#   ./start.sh --setup <hostname>   once: Cloudflare login, named tunnel, DNS
#
# A named tunnel (created by --setup) has a fixed hostname, so config.js is
# written once and later starts push nothing. Until one is configured this
# falls back to a trycloudflare quick tunnel, whose name changes on every
# restart — then config.js follows it with a commit each time.
#
# env overrides: WEBPORT_SERVER, WEBPORT_PORT, CLOUDFLARED,
#                TUNNEL_NAME, TUNNEL_HOSTNAME, TUNNEL_TOKEN_FILE
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)   # this repo
root=$(cd "$here/.." && pwd)                          # _work/fix4
server=${WEBPORT_SERVER:-$root/roblox-webport}
port=${WEBPORT_PORT:-9989}
cloudflared=${CLOUDFLARED:-$root/bin/cloudflared.exe}

run=$here/.run
mkdir -p "$run"
tunnel_pid=$run/cloudflared.pid
tunnel_log=$run/cloudflared.log
tunnel_out=$run/cloudflared.out
tunnel_env=$run/tunnel.env
server_log=$run/server.log

die() { echo "start: $*" >&2; exit 1; }

# 2xx only. `curl -o /dev/null` accepts any status and `-f` still accepts 3xx,
# so read the code: a tunnel that answers 404 must not count as healthy.
http_ok() {
  local code
  code=$(curl -sk --max-time 8 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null) || return 1
  case "$code" in 2??) return 0 ;; *) return 1 ;; esac
}

# The game streams over /udp-relay, so a proxy that serves HTML but drops the
# upgrade looks healthy right up to the first join. A real WebSocket client is
# the only honest check: 101 means the upgrade was proxied end to end.
ws_101() {
  node -e '
    const fs = require("fs");
    const say = (s, code) => { try { fs.writeSync(1, s + "\n"); } catch {} process.exit(code); };
    const ws = new WebSocket(process.argv[1]);
    const t = setTimeout(() => say("timeout", 2), 10000);
    ws.onopen = () => { clearTimeout(t); try { ws.close(); } catch {} say("101", 0); };
    ws.onerror = () => { clearTimeout(t); say("no upgrade", 1); };
  ' "$1/udp-relay"
}

# `$!` is the shell's own (MSYS) pid, not the Windows pid tasklist reports, so
# ask this shell's process table. Never taskkill a translated pid: it belongs to
# a different process.
pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# stop, then keep asking until the pid is really gone; the caller must know a
# half-killed tunnel is not replaced silently
stop_pid() {
  kill "$1" 2>/dev/null || true
  for _ in $(seq 20); do pid_alive "$1" || return 0; sleep 0.5; done
  return 1
}

case "${1:-}" in
  --health)
    [ -n "${2:-}" ] || die "usage: ./start.sh --health <url>"
    if http_ok "$2"; then echo "2xx  $2"; else echo "not 2xx  $2" >&2; exit 1; fi
    exit 0 ;;
  --setup)
    host=${2:-}; [ -n "$host" ] || die "usage: ./start.sh --setup <hostname> [tunnel-name]"
    name=${3:-roblox-webport}
    [ -f "$cloudflared" ] || die "no cloudflared at $cloudflared"
    if [ -f "${TUNNEL_ORIGIN_CERT:-$HOME/.cloudflared/cert.pem}" ]; then
      echo "cloudflared is already logged in"
    else
      echo "Cloudflare login: a browser opens — pick the zone that owns $host."
      "$cloudflared" tunnel login || die "cloudflared login failed"
    fi
    if ! "$cloudflared" tunnel list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$name"; then
      "$cloudflared" tunnel create "$name" || die "could not create tunnel $name"
    else
      echo "tunnel:  '$name' already exists"
    fi
    "$cloudflared" tunnel route dns "$name" "$host" \
      || echo "dns:     route for $host may already exist — continuing"
    cat >"$tunnel_env" <<EOF
# written by ./start.sh --setup; local paths only, no secrets
TUNNEL_NAME=$name
TUNNEL_HOSTNAME=$host
EOF
    echo "tunnel:  named '$name' -> https://$host"
    echo "next:    ./start.sh --fresh"
    exit 0 ;;
esac

fresh=0
worker=1
for arg in "$@"; do
  case "$arg" in
    --fresh) fresh=1 ;;
    --no-worker) worker=0 ;;
    '') ;;
    *) die "unknown argument: $arg" ;;
  esac
done

# ---------- tunnel configuration -------------------------------------------
tunnel_name=${TUNNEL_NAME:-}
tunnel_host=${TUNNEL_HOSTNAME:-}
token_file=${TUNNEL_TOKEN_FILE:-}
if [ -f "$tunnel_env" ]; then
  # shellcheck disable=SC1090
  . "$tunnel_env"
  tunnel_name=${TUNNEL_NAME:-$tunnel_name}
  tunnel_host=${TUNNEL_HOSTNAME:-$tunnel_host}
  token_file=${TUNNEL_TOKEN_FILE:-$token_file}
fi
[ -f "$cloudflared" ] || die "no cloudflared at $cloudflared"

# ---------- server ----------------------------------------------------------
if http_ok "https://127.0.0.1:$port/"; then
  echo "server:  already up on :$port"
else
  echo "server:  starting (log: $server_log)"
  ( cd "$server" && node index.mjs >"$server_log" 2>&1 & echo $! >"$run/server.pid" )
  for _ in $(seq 40); do http_ok "https://127.0.0.1:$port/" && break; sleep 1; done
  http_ok "https://127.0.0.1:$port/" || { tail -n 20 "$server_log" >&2; die "server is not answering 2xx on :$port"; }
  echo "server:  up on :$port"
fi

# ---------- tunnel ----------------------------------------------------------
read_url() { grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$tunnel_log" 2>/dev/null | tail -1; }

if [ "$fresh" = 1 ] && [ -f "$tunnel_pid" ]; then
  old=$(cat "$tunnel_pid" 2>/dev/null || true)
  if pid_alive "$old"; then
    stop_pid "$old" && echo "tunnel:  stopped pid $old" || die "pid $old survived stop_pid"
  else
    echo "tunnel:  pid ${old:-?} already gone"
  fi
  rm -f "$tunnel_pid"
fi

start_tunnel() {
  : >"$tunnel_log"
  if [ -n "$tunnel_name" ] && [ -n "$token_file" ]; then
    TUNNEL_TOKEN=$(cat "$token_file") "$cloudflared" tunnel --no-autoupdate \
      --logfile "$tunnel_log" run >"$tunnel_out" 2>&1 &
  elif [ -n "$tunnel_name" ]; then
    "$cloudflared" tunnel --url "https://127.0.0.1:$port" --no-tls-verify --no-autoupdate \
      --logfile "$tunnel_log" run "$tunnel_name" >"$tunnel_out" 2>&1 &
  else
    "$cloudflared" tunnel --url "https://127.0.0.1:$port" --no-tls-verify --no-autoupdate \
      --logfile "$tunnel_log" >"$tunnel_out" 2>&1 &
  fi
  echo $! >"$tunnel_pid"
}

if [ -n "$tunnel_name" ]; then
  public="https://$tunnel_host"
  running=0
  if [ "$fresh" = 0 ] && [ -f "$tunnel_pid" ] && pid_alive "$(cat "$tunnel_pid")" && http_ok "$public/"; then
    running=1
    echo "tunnel:  reusing $public"
  fi
  if [ "$running" = 0 ]; then
    start_tunnel
    for _ in $(seq 60); do
      http_ok "$public/" && break
      pid_alive "$(cat "$tunnel_pid" 2>/dev/null || true)" \
        || { tail -n 20 "$tunnel_log" >&2; die "cloudflared exited before $public answered (tunnel name or credentials wrong?)"; }
      sleep 1
    done
    http_ok "$public/" || { tail -n 20 "$tunnel_log" >&2; die "named tunnel is not answering 2xx at $public/ (DNS not routed yet?)"; }
    echo "tunnel:  $public (named '$tunnel_name')"
  fi
else
  url=$(read_url || true)
  running=0
  if [ "$fresh" = 0 ] && [ -f "$tunnel_pid" ] && pid_alive "$(cat "$tunnel_pid")" \
     && [ -n "$url" ] && http_ok "$url/"; then
    running=1
    echo "tunnel:  reusing $url"
  fi
  if [ "$running" = 0 ]; then
    start_tunnel
    url=""
    for _ in $(seq 40); do url=$(read_url || true); [ -n "$url" ] && break; sleep 1; done
    [ -n "$url" ] || { tail -n 20 "$tunnel_log" >&2; die "cloudflared printed no tunnel URL in 40s"; }
    # a fresh quick tunnel can answer 502/530 for its first seconds while the
    # edge picks up the new name, so give it a minute and keep retrying
    for _ in $(seq 60); do
      http_ok "$url/" && break
      pid_alive "$(cat "$tunnel_pid" 2>/dev/null || true)" \
        || { tail -n 20 "$tunnel_log" >&2; die "cloudflared exited before $url answered"; }
      sleep 1
    done
    http_ok "$url/" || { tail -n 20 "$tunnel_log" >&2; die "quick tunnel $url is not answering 2xx"; }
    echo "tunnel:  $url"
    echo "tunnel:  quick tunnel — this name dies with it; ./start.sh --setup <hostname> for a stable one"
  fi
  public=$url
fi
printf '%s\n' "$public" >"$run/tunnel-url"
tunnel_url=$public

# ---------- stable address ---------------------------------------------------
# A quick tunnel's name dies with the process, so the gate's address would move
# on every restart. The Worker in worker/ holds the current origin in a var and
# proxies everything (WebSocket included), which means config.js is written
# once and later restarts only redeploy the Worker.
if [ "$worker" = 1 ] && [ -n "$tunnel_name" ]; then
  # a named tunnel is already a fixed address; a Worker in front only adds hops
  worker=0
fi
worker_ok() { http_ok "$1/" && ws_101 "$1" >/dev/null; }
if [ "$worker" = 1 ] && [ -f "$here/worker/wrangler.jsonc" ]; then
  wurl=$(cat "$run/worker-url" 2>/dev/null || true)
  was=$(cat "$run/worker-origin" 2>/dev/null || true)
  # A deploy spends a few seconds and a new version, so only do it when the
  # origin the Worker holds is not the one this tunnel just got — and even then
  # only after the existing Worker has been proven to work as-is.
  if [ "$was" = "$tunnel_url" ] && [ -n "$wurl" ] && worker_ok "$wurl"; then
    public=$wurl
    echo "worker:  origin unchanged — $wurl (200, /udp-relay 101)"
  else
    echo "worker:  deploying front door -> $tunnel_url"
    out=$( cd "$here/worker" && npx -y wrangler@4 deploy --var "ORIGIN:$tunnel_url" 2>&1 ) || true
    # the deployed URL is <name>.<account-subdomain>.workers.dev, so every label
    # has to be allowed, not just one
    wurl=$(printf '%s\n' "$out" | grep -oE 'https://[A-Za-z0-9.-]+\.workers\.dev' | tail -1 || true)
    if [ -n "$wurl" ]; then
      for _ in $(seq 10); do worker_ok "$wurl" && break; sleep 1; done
      printf '%s\n' "$wurl" >"$run/worker-url"
      if http_ok "$wurl/" && ws_101 "$wurl" >/dev/null; then
        printf '%s\n' "$tunnel_url" >"$run/worker-origin"
        public=$wurl
        echo "worker:  $wurl (200, /udp-relay 101)"
      elif http_ok "$wurl/"; then
        echo "worker:  $wurl serves 200 but /udp-relay did not upgrade to 101 — config.js follows the tunnel" >&2
      else
        printf '%s\n' "$out" | tail -n 10 >&2
        echo "worker:  deployed but not answering 2xx — config.js follows the tunnel" >&2
      fi
    else
      printf '%s\n' "$out" | tail -n 10 >&2
      echo "worker:  deploy failed (logged in? npx wrangler login) — config.js follows the tunnel" >&2
    fi
  fi
fi

# ---------- config.js -------------------------------------------------------
node - "$public" <<'NODE'
const fs = require('fs');
const url = process.argv[2];
const path = 'config.js';
const before = fs.readFileSync(path, 'utf8');
const after = before.replace(/(\n\s*backend:\s*')[^']*(')/, `$1${url}$2`);
if (after === before && !before.includes(`backend: '${url}'`))
  throw new Error('config.js has no backend: line to update');
if (after !== before) fs.writeFileSync(path, after);
NODE
if grep -q "backend: '$public'" "$here/config.js"; then
  echo "config:  backend = $public"
else
  die "config.js did not take $public"
fi

# ---------- publish ---------------------------------------------------------
cd "$here"
if git diff --quiet -- config.js; then
  echo "pages:   nothing to commit"
  exit 0
fi
ident=()
git config user.email >/dev/null || ident=(-c user.name=damonrosshutchins-boop
  -c user.email=damonrosshutchins-boop@users.noreply.github.com)
git add config.js
git ${ident[@]+"${ident[@]}"} commit -q -m "$(cat <<EOF
Point the gate at $public

$(if [ -n "$tunnel_name" ]; then echo "The named tunnel is fixed, so this line stops moving."; else echo "A quick tunnel changes name on every restart, so config.js follows the one that is running."; fi)

Generated with Codebuff 🤖
Co-Authored-By: Codebuff <noreply@codebuff.com>
EOF
)"
git push -q origin HEAD:main
echo "pages:   pushed — https://damonrosshutchins-boop.github.io/roblox-web-ported/"
