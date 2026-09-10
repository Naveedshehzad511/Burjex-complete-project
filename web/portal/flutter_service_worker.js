// Intentionally not a caching service worker.
// Its only job is to evict the previous one and get out of the way.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      await caches.delete(key);
    }
    await self.registration.unregister();
    // Reload any open tab so the user lands on the current build immediately
    // rather than finishing the session on the code they already had.
    for (const client of await self.clients.matchAll({ type: 'window' })) {
      client.navigate(client.url);
    }
  })());
});
