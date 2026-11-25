// worker/index.js — a stable front door for a changing quick tunnel.
//
// The webport server is reached through a `trycloudflare.com` quick tunnel,
// whose name changes every restart. This Worker holds the current origin in a
// plain var (start.sh redeploys it after each restart) and forwards every
// request, so the public address the gate points at never moves.
//
// It is a transparent proxy on purpose: no rewriting, no caching, no auth.
// The game's `/udp-relay` WebSocket and the Quick Login POSTs both have to work
// byte-for-byte, so the request is forwarded as it arrived and the response is
// returned as it came back.

export default {
  async fetch(request, env) {
    const origin = new URL(env.ORIGIN || '');
    const incoming = new URL(request.url);

    // same path + query, different host
    const target = new URL(incoming.pathname + incoming.search, origin);

    const headers = new Headers(request.headers);
    headers.delete('host');
    // let Cloudflare negotiate compression with the browser; the origin then
    // does not gzip something that is already compressed
    headers.delete('accept-encoding');

    const init = { method: request.method, headers, redirect: 'manual' };
    // a GET/HEAD body is a runtime error in fetch
    if (request.method !== 'GET' && request.method !== 'HEAD') init.body = request.body;

    const res = await fetch(target.toString(), init);
    // a 101 response already carries `webSocket`; returning it completes the
    // upgrade, which is what /udp-relay needs
    return res;
  },
};
