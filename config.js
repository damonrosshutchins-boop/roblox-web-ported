// Defaults for the static front end. Nothing secret lives here: `wisp` is the
// relay the proxy tunnels through, `backend` is the web-port server that mints
// the game session. Both are editable on index.html and remembered per browser
// (localStorage), so a new tunnel or relay does not need a new deploy.
window.RWP = {
  // Your web-port server's public origin — currently a Cloudflare quick
  // tunnel. A quick tunnel lives only as long as `cloudflared` is running and
  // gets a new name on every restart, so if this stops answering, start the
  // tunnel again and put its new origin in step 1 of index.html.
  backend: 'https://caps-solve-dover-generator.trycloudflare.com',
  // Scramjet needs a Wisp endpoint; github.io cannot host one.
  wisp: 'wss://wisp.mercurywork.shop/',
  place: '1818',
};
