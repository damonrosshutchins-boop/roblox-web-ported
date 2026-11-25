// Defaults for the static front end. Nothing secret lives here: `wisp` is the
// relay the proxy tunnels through, `backend` is the web-port server that mints
// the game session. Both are editable on index.html and remembered per browser
// (localStorage), so a new tunnel or relay does not need a new deploy.
window.RWP = {
  // The web-port server's stable front door: the Cloudflare Worker in worker/,
  // which proxies to whichever trycloudflare quick tunnel is currently up. The
  // Worker holds that origin in a var `start.sh` updates, so this address
  // survives tunnel restarts. If it stops answering, run ./start.sh.
  backend: 'https://roblox-webport.damonrosshutchins.workers.dev',
  // Scramjet needs a Wisp endpoint; github.io cannot host one.
  wisp: 'wss://wisp.mercurywork.shop/',
  place: '1818',
};
