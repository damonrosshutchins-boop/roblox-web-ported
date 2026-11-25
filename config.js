// Defaults for the static front end. Nothing secret lives here: `wisp` is the
// relay the proxy tunnels through, `backend` is the web-port server that mints
// the game session. Both are editable on index.html and remembered per browser
// (localStorage), so a new tunnel or relay does not need a new deploy.
window.RWP = {
  // Quick-tunnel demo server. A trycloudflare URL changes every time the
  // server restarts — put your own origin here (or in the field on index.html).
  backend: 'https://gadgets-maritime-picture-ethical.trycloudflare.com',
  // Scramjet needs a Wisp endpoint; github.io cannot host one.
  wisp: 'wss://wisp.mercurywork.shop/',
  place: '1818',
};
