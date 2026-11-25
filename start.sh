#!/usr/bin/env bash
# start.sh — boot the webport server + a cloudflared quick tunnel, then point
# the static gate at that tunnel and push it to GitHub Pages.
#
#   ./start.sh            reuse a healthy tunnel, otherwise start one
#   ./start.sh --fresh    start a new tunnel even if the last one still answers
#
# A trycloudflare quick tunnel gets a new name on every restart, so config.js
# is rewritten from the URL cloudflared actually printed — not guessed — and
# committed. Run this after a reboot, or whenever the gate stops reaching the
# server.
#
# Paths (override with env vars):
#   WEBPORT_SERVER  the roblox-webport checkout   default ../roblox-webport
#   WEBPORT_PORT    the one https port it uses    default 9989
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)   # this repo (roblox-web-ported)
root=$(cd "$here/.." && pwd)                          # _work/fix4
server=${WEBPORT_SERVER:-$root/roblox-webport}
port=${WEBPORT_PORT:-9989}
cloudflared=$root/bin/cloudflared.exe

run=$here/.run
mkdir -p "$run"
tunnel_pid=$run/cloudflared.pid
tunnel_log=$run/cloudflared.log
tunnel_out=$run/cloudflared.out
server_log=$run/server.log

fresh=0
[ "${1:-}" = "--fresh" ] && fresh=1

die() { echo "start: $*" >&2; exit 1; }

# ---------- server ----------------------------------------------------------
# https with a self-signed cert, so every probe uses -k
up() { curl -sk --max-time 5 -o /dev/null "https://127.0.0.1:$port/"; }

if up; then
  echo "server:  already up on :$port"
else
  echo "server:  starting (log: $server_log)"
  ( cd "$server" && node index.mjs >"$server_log" 2>&1 & echo $! >"$run/server.pid" )
  for _ in $(seq 40); do up && break; sleep 1; done
  up || { tail -n 20 "$server_log" >&2; die "server did not answer on :$port"; }
  echo "server:  up on :$port"
fi

# ---------- tunnel ----------------------------------------------------------
read_url() { grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$tunnel_log" 2>/dev/null | tail -1; }
answers() { [ -n "${1:-}" ] && curl -s --max-time 8 -o /dev/null "$1/"; }

[ -f "$cloudflared" ] || die "no cloudflared at $cloudflared"

# stop the tunnel this script started last time (by recorded pid, never by name)
if [ -f "$tunnel_pid" ]; then
  pid=$(cat "$tunnel_pid" 2>/dev/null || true)
  if [ "$fresh" = 1 ] && [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || taskkill //PID "$pid" //T //F >/dev/null 2>&1 || true
    rm -f "$tunnel_pid"
    echo "tunnel:  stopped pid $pid"
  fi
fi

url=$(read_url || true)
if [ "$fresh" = 0 ] && answers "$url"; then
  echo "tunnel:  reusing $url"
else
  : >"$tunnel_log"
  "$cloudflared" tunnel --url "https://127.0.0.1:$port" --no-tls-verify --no-autoupdate \
    --logfile "$tunnel_log" >"$tunnel_out" 2>&1 &
  echo $! >"$tunnel_pid"
  url=""
  for _ in $(seq 40); do url=$(read_url || true); [ -n "$url" ] && break; sleep 1; done
  [ -n "$url" ] || { tail -n 20 "$tunnel_log" >&2; die "cloudflared printed no tunnel URL in 40s"; }
  for _ in $(seq 30); do answers "$url" && break; sleep 1; done
  answers "$url" || { tail -n 20 "$tunnel_log" >&2; die "tunnel $url does not reach the server yet"; }
  echo "tunnel:  $url"
fi
printf '%s\n' "$url" >"$run/tunnel-url"

# ---------- config.js -------------------------------------------------------
before=$(cat "$here/config.js")
node - "$url" <<'NODE'
const fs = require('fs');
const url = process.argv[2];
const path = 'config.js';
const before = fs.readFileSync(path, 'utf8');
const after = before.replace(/(\n\s*backend:\s*')[^']*(')/, `$1${url}$2`);
if (after === before && !before.includes(`backend: '${url}'`))
  throw new Error('config.js has no backend: line to update');
fs.writeFileSync(path, after);
NODE
after=$(cat "$here/config.js")
if [ "$before" = "$after" ]; then
  echo "config:  already points at $url"
else
  echo "config:  backend -> $url"
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
Point the gate at the current tunnel

cloudflared handed out $url; a quick tunnel changes name on every
restart, so config.js follows the one that is actually running.

Generated with Codebuff 🤖
Co-Authored-By: Codebuff <noreply@codebuff.com>
EOF
)"
git push -q origin HEAD:main
echo "pages:   pushed — https://damonrosshutchins-boop.github.io/roblox-web-ported/"
