// BARINV Service Worker — network-first for HTML, cache-first for assets
// Auto-refreshes open windows when a new version activates
const CACHE = 'barinv-v315';
const SHELL = ['/', '/index.html', '/manifest.json'];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    )
    .then(() => self.clients.claim())
    // Force any open windows to reload so they get the fresh HTML
    .then(() => self.clients.matchAll({ type: 'window' }).then(clients => {
      clients.forEach(c => { try { c.navigate(c.url); } catch {} });
    }))
  );
});

self.addEventListener('fetch', e => {
  // Non-GET: never intercepted, never cached.
  if (e.request.method !== 'GET') return;

  // Dynamic API traffic (Supabase REST + Edge Functions) — pass through
  // with NO cache read and NO cache write. This guarantees nights and
  // every other live query always go network-first to the origin. The
  // only offline "response" here is a synthetic {error:"offline"} JSON
  // so JS handlers can catch it cleanly.
  if (e.request.url.includes('supabase.co') ||
      e.request.url.includes('/rest/v1/') ||
      e.request.url.includes('/functions/v1/')) {
    e.respondWith(
      fetch(e.request).catch(() => new Response('{"error":"offline"}', {
        headers: { 'Content-Type': 'application/json' }
      }))
    );
    return;
  }

  const url = new URL(e.request.url);
  const isHTML = e.request.mode === 'navigate' ||
                 url.pathname === '/' ||
                 url.pathname.endsWith('.html');

  if (isHTML) {
    // Network-first for HTML: always try fresh first, fall back to cache offline
    e.respondWith(
      fetch(e.request).then(res => {
        if (res.ok) {
          const clone = res.clone();
          caches.open(CACHE).then(c => c.put(e.request, clone));
        }
        return res;
      }).catch(() =>
        caches.open(CACHE).then(c => c.match(e.request).then(r =>
          r || c.match('/index.html')
        ))
      )
    );
    return;
  }

  // Cache-first for assets (JS/CSS/images) — they rarely change between versions
  e.respondWith(
    caches.open(CACHE).then(cache =>
      cache.match(e.request).then(cached => {
        const networkFetch = fetch(e.request).then(res => {
          if (res.ok) cache.put(e.request, res.clone());
          return res;
        }).catch(() => cached);
        return cached || networkFetch;
      })
    )
  );
});
