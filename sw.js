// The service worker is deliberately thin.
//
// The controller in the tab owns the transport, the cookie jar and the
// rewriting; this worker only has to forward requests that arrive under a
// frame's prefix to that controller, and leave every other request alone so the
// static site (index.html, vendor/*) loads straight from Pages.
try {
  importScripts('./vendor/controller.sw.js');
} catch (e) {
  console.error('[sw] scramjet controller failed to load:', e);
}

addEventListener('fetch', (event) => {
  const ctl = self.$scramjetController;
  if (!ctl || !ctl.shouldRoute(event)) return; // normal static request
  event.respondWith(ctl.route(event));
});
