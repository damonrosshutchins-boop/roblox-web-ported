# Roblox web port — static front end

The sign-in half of a self-hosted Roblox web port, running as a plain static site
(GitHub Pages, or any host that serves files). It is the front door for the
`roblox-webport` server: you sign in to a real Roblox account here, and the game
itself is streamed by that server.

## What is here

| file | role |
| --- | --- |
| `index.html` | the gate — set your server and relay, sign in on roblox.com, hand the cookie over |
| `proxy.html` | optional: roblox.com's login running through Scramjet in your browser |
| `sw.js` | a thin service worker that forwards only the proxy prefix |
| `config.js` | default server / Wisp relay / place id |
| `vendor/` | Scramjet runtime, pinned (see below) |

## How it works

Sign in is **Quick Login**, done by your server. The gate's **Sign in with a
one-time code** button opens `backend/?place=…`; the server asks Roblox for a
short-lived code and shows it. You approve that code in the Roblox app, or at
`roblox.com → Account Settings → Quick Login`, on a device that is already signed
in. Roblox then hands the server a `.ROBLOSECURITY` in a server-to-server call,
the server confirms it, mints the session and opens the place. No password is
typed into this site, and no cookie is ever copied out of DevTools or into a
browser page.

### Fallback: paste the cookie

If you would rather not use Quick Login, sign in on **roblox.com itself** in a
normal tab — the only place Roblox's bot check can finish — and paste the
resulting `.ROBLOSECURITY` value into the gate (DevTools → Application → Cookies →
`https://www.roblox.com`). The gate hands only that one value to the server you
configured, in the URL **fragment** (`#token=…&place=…`) — a fragment is never part
of a request, so the cookie does not appear in the server's access log, and the
server's landing page clears it from the address bar before using it. The server
verifies the cookie with Roblox, mints a session and opens the place.

That cookie is never written to `localStorage` or a file by this page.

### The proxied login (optional)

`proxy.html` loads Scramjet in the page, registers `sw.js`, and renders
`https://www.roblox.com/login` inside an iframe under a `/~/sj/` prefix. Scramjet
rewrites Roblox's own HTML and JS so the site runs on this origin. Requests leave
the browser through a **Wisp relay** — a WebSocket that carries raw TCP — and the
TLS session to Roblox is established inside the page by libcurl compiled to WASM,
so the relay only ever sees ciphertext and your password is never terminated at
it. If that login ever gets through, **Use this session** reads the cookie out of
the proxy's own jar and hands it over the same way.

## Why the bot check stops the proxy login

Roblox gates sign-in behind a “Verifying you're not a bot” challenge. It is a
fingerprint challenge aimed at a normal browser origin, and it does not complete
in a proxied page: the frame sits on that spinner indefinitely, no matter how fast
the relay is. The proxy page watches for that screen and shows a link to the cookie
path instead of leaving the spinner running. Nothing here solves or bypasses the
challenge — you answer it on Roblox's own site, which is where it works.

## What a static host cannot do

Two pieces need a real server, and GitHub Pages is not one:

- **the Wisp relay** — `github.io` cannot open TCP sockets for you, so the proxy
  needs a Wisp endpoint somewhere else (`wss://…/`), set on `index.html`;
- **the game** — the engine is a genuine WebTransport client, so joining needs the
  web-port server. Pages serves the sign-in page only.

## Starting it

```bash
./start.sh --setup roblox.example.com   # once: Cloudflare login, named tunnel, DNS
./start.sh                              # boot server + tunnel, point config.js
./start.sh --fresh                      # stop the recorded tunnel, start a new one
./start.sh --health https://…/          # exit 0 only for a 2xx
```

`--setup` opens Cloudflare's login in a browser, creates a tunnel named
`roblox-webport`, routes your hostname to it and records both in
`.run/tunnel.env`. From then on the public origin is fixed, so `config.js` is
written once and restarts push nothing. A locally-managed tunnel keeps its
credentials under `~/.cloudflared/`; for a dashboard-made tunnel put
`TUNNEL_TOKEN_FILE=/path/to/token` in `.run/tunnel.env` instead.

Health is 2xx-only: `curl -o /dev/null` accepts a 404 and `-f` accepts a 3xx, so
the status code is read explicitly. `--fresh` stops the tunnel this script
started, waits until that pid is gone, and fails rather than leaving two
running. Pids, logs and the current URL live in `.run/` (git-ignored).
`WEBPORT_SERVER` and `WEBPORT_PORT` override the defaults.

Without `--setup` it falls back to a trycloudflare quick tunnel; because that
name changes on every restart, `config.js` is rewritten and pushed each time.

## Pointing it at your own server

Set *your server* and *Wisp relay* on `index.html` (remembered per browser), or
edit the defaults in `config.js` and redeploy. The server must be the one running
this project's `roblox-webport` checkout with the landing page that accepts a
handed-over cookie (`#token=…&place=…`); it replies by minting `/pg/<sid>/`.

A `trycloudflare.com` quick tunnel changes URL every restart, and `config.js`
currently points at one (`https://powell-entitled-federal-antibody.trycloudflare.com`).
When it stops answering, restart `cloudflared` and either type the new origin in
step 1 of `index.html` (remembered per browser) or update `config.js` and redeploy.

## Vendored Scramjet

Downloaded from npm and committed so the page has no build step and no second
network dependency (the usual bootstrap fetches its runtime from jsdelivr at
service-worker start):

- `@mercuryworkshop/scramjet` 2.1.0 — `vendor/scramjet.js`, `vendor/scramjet.wasm`
- `@mercuryworkshop/scramjet-controller` 0.1.0 — `vendor/controller.api.js`,
  `vendor/controller.inject.js`, `vendor/controller.sw.js`
- `@mercuryworkshop/scramjet-utils` 0.0.3 — `vendor/scramjet-utils.js`
- `@mercuryworkshop/libcurl-transport` 2.x — `vendor/libcurl-client.js`

Each keeps its upstream licence (MIT/Apache-2.0 as published by those packages).
`HttpCachePlugin` from the utils bundle is deliberately not used: that bundling
throws inside the request path (`fromNativeResponse` is undefined).

## Notes

Unofficial, unaffiliated with Roblox. Signing in through a proxy is not a
supported way to reach Roblox, and an account used this way can be flagged.
Nothing here solves or bypasses a captcha: you solve it yourself on Roblox's own
page.
