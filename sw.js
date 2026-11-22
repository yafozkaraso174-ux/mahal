const CACHE = 'mahal-v42';
const ASSETS = ['./index.html', './manifest.json', './icon-192.png', './icon-512.png', './vendor/zxing.min.js', './vendor/jsbarcode.min.js'];
self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.addAll(ASSETS.map(u => new Request(u, { cache: 'reload' }))))
      .then(() => self.skipWaiting())
  );
});
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  // طلبات سوبابيز وأي موقع خارجي: سيبها للشبكة دايماً — من غير كاش خالص
  if (new URL(req.url).origin !== self.location.origin) return;
  // Only the owner app may update its offline shell. Store/admin HTML must never replace it.
  if (req.mode === 'navigate' || req.destination === 'document') {
    const base = new URL(self.registration.scope);
    const target = new URL(req.url);
    const ownerPage = target.pathname === base.pathname || target.pathname === new URL('index.html', base).pathname;
    e.respondWith(
      fetch(req, { cache: 'no-cache' }).then(res => {
        if (ownerPage && res.ok) {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put('./index.html', copy));
        }
        return res;
      }).catch(async () => {
        if (ownerPage) {
          const shell = await caches.match('./index.html', { ignoreSearch: true });
          if (shell) return shell;
        }
        return new Response('<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>غير متصل</title><body style="font-family:sans-serif;padding:24px">الصفحة دي محتاجة اتصال بالإنترنت. ارجع لبرنامج المحل عشان تكمّل شغلك أوفلاين.</body></html>', {status:503, headers:{'Content-Type':'text/html; charset=utf-8'}});
      })
    );
    return;
  }
  // باقي الملفات الثابتة: كاش أولاً
  e.respondWith(
    caches.match(req, { ignoreSearch: true }).then(hit => hit || fetch(req).then(res => {
      const copy = res.clone();
      if (res.ok) caches.open(CACHE).then(c => c.put(req, copy));
      return res;
    }).catch(() => hit))
  );
});
