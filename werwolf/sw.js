/* Werewolf Companion – Service Worker
 *
 * Cacht nur die eigenen App-Dateien (gleiche Domain), damit die App offline startet.
 * Die Adobe-Fonts (use.typekit.net / p.typekit.net) werden bewusst NICHT angefasst
 * und NICHT gecacht: Die Adobe-Fonts-Lizenz erlaubt nur die Auslieferung über das
 * Embed-Kit, kein Selbst-Hosten bzw. lokales Speichern der Font-Dateien.
 * Offline greift deshalb die Fallback-Schrift aus --font.
 *
 * Updates: index.html wird bei Netz immer frisch geladen (max. 3 s Wartezeit), Änderungen
 * kommen also von selbst an. Nur wenn Icons oder manifest.json geändert werden: VERSION hochzählen.
 */
const VERSION = 'v1';
const CACHE = 'wwc-app-' + VERSION;
const ASSETS = [
  './',
  'manifest.json',
  'icon-192.png',
  'icon-512.png',
  'apple-touch-icon.png'
];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE)
      .then((c) => c.addAll(ASSETS.map((u) => new Request(u, { cache: 'reload' }))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith('wwc-app-') && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

function withTimeout(promise, ms) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('timeout')), ms);
    promise.then((r) => { clearTimeout(t); resolve(r); }, (err) => { clearTimeout(t); reject(err); });
  });
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  // Nur eigene Dateien innerhalb von /werwolf/. Alles andere (u. a. Adobe Fonts) läuft ganz normal übers Netz.
  if (url.origin !== self.location.origin) return;
  const scope = new URL('./', self.location).pathname;
  if (!url.pathname.startsWith(scope)) return;

  const isPage = req.mode === 'navigate' || url.pathname === scope || url.pathname === scope + 'index.html';

  if (isPage) {
    // Seite: zuerst Netz (max. 3 s, damit schlechter Empfang nicht hängt), sonst gespeicherte Fassung.
    e.respondWith(
      withTimeout(fetch(req), 3000)
        .then((res) => {
          if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put('./', copy)); }
          return res;
        })
        .catch(() => caches.match('./').then((r) => r || Response.error()))
    );
    return;
  }

  // Icons & Manifest: zuerst Cache, sonst Netz.
  e.respondWith(caches.match(req, { ignoreSearch: true }).then((r) => r || fetch(req)));
});
