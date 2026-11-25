# Roblox web port — static front end

The sign-in half of a self-hosted Roblox web port, running as a plain static site
(GitHub Pages, or any host that serves files). It is the front door for the
`roblox-webport` server: you sign in to a real Roblox account here, and the game
itself is streamed by that server.

## What is here

| file | role |
| --- | --- |
| `index.html` | the gate — set your server + relay, then go to the proxy |
| `proxy.html` | roblox.com's real login running through Scramjet in your browser |
| `sw.js` | a thin service worker that forwards only the proxy prefix |
| `config.js` | default server / Wisp relay / place id |
| `vendor/` | Scramjet runtime, pinned (see below) |

## How it works

`proxy.html` loads Scramjet in the page, registers `sw.js`, and renders
`https://www.roblox.com/login` inside an iframe under a `/~/sj/` prefix. Scramjet
rewrites Roblox's own HTML and JS so the site runs on this origin. Requests leave
the browser through a **Wisp relay** — a WebSocket that carries raw TCP — and the
TLS session to Roblox is established inside the page by libcurl compiled to WASM,
so the relay only ever sees ciphertext and your password is never terminated at
it.

The cookie from that login stays in the proxy's own cookie jar. Press **Use this
session** and only the `.ROBLOSECURITY` value is read out of the jar and handed to
the server you configured, in the URL fragment (`#token=…`) — a fragment is never
part of a request, so it does not appear in the server's access log. The server
verifies the cookie with Roblox, mints a session and opens the place.

## What a static host cannot do

Two pieces need a real server, and GitHub Pages is not one:

- **the Wisp relay** — `github.io` cannot open TCP sockets for you, so the proxy
  needs a Wisp endpoint somewhere else (`wss://…/`), set on `index.html`;
- **the game** — the engine is a genuine WebTransport client, so joining needs the
  web-port server. Pages serves the sign-in page only.

## Pointing it at your own server

Set *your server* and *Wisp relay* on `index.html` (remembered per browser), or
edit the defaults in `config.js` and redeploy. The server must be the one running
this project's `roblox-webport` checkout with the landing page that accepts a
handed-over cookie (`#token=…&place=…`); it replies by minting `/pg/<sid>/`.

A `trycloudflare.com` quick tunnel changes URL every restart — put a stable origin
in `config.js` once you have one.

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
