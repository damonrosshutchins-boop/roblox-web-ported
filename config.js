// Defaults for the static front end. Nothing secret lives here: `wisp` is the
// relay the proxy tunnels through, `backend` is the web-port server that mints
// the game session. Both are editable on index.html and remembered per browser
// (localStorage), so a new tunnel or relay does not need a new deploy.
window.RWP = {
  // Your web-port server's public origin, e.g. a named Cloudflare tunnel.
  // A trycloudflare quick tunnel lives only as long as it is running, so it is
  // deliberately not baked in; type the current one on index.html instead.
  backend: '',
  // Scramjet needs a Wisp endpoint; github.io cannot host one.
  wisp: 'wss://wisp.mercurywork.shop/',
  place: '1818',
};
