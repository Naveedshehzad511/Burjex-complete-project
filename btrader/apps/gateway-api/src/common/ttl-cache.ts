/** Tiny in-process TTL map. Used for identical portal reads under concurrent VUs. */

import { envPositiveInt } from './throttle.config';

type Entry<T> = { exp: number; value: T };

const store = new Map<string, Entry<unknown>>();

/** Portal poll interval is 8–18s; 2s is fresh enough and collapses a thundering herd. */
export const PORTAL_READ_CACHE_MS = envPositiveInt('PORTAL_READ_CACHE_MS', 2000);

export function ttlGet<T>(key: string): T | undefined {
  const e = store.get(key) as Entry<T> | undefined;
  if (!e) return undefined;
  if (e.exp < Date.now()) {
    store.delete(key);
    return undefined;
  }
  return e.value;
}

export function ttlSet<T>(key: string, value: T, ttlMs: number): T {
  store.set(key, { exp: Date.now() + ttlMs, value });
  return value;
}

const inflight = new Map<string, Promise<unknown>>();

export async function ttlWrap<T>(key: string, ttlMs: number, fn: () => Promise<T>): Promise<T> {
  const hit = ttlGet<T>(key);
  if (hit !== undefined) return hit;
  const pending = inflight.get(key) as Promise<T> | undefined;
  if (pending) return pending;
  const p = fn()
    .then((v) => {
      ttlSet(key, v, ttlMs);
      return v;
    })
    .finally(() => inflight.delete(key));
  inflight.set(key, p);
  return p;
}

export function ttlDelPrefix(prefix: string): void {
  for (const k of store.keys()) {
    if (k.startsWith(prefix)) store.delete(k);
  }
}
