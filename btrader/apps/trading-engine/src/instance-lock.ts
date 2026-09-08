/**
 * Guarantees exactly one trading engine is running.
 *
 * WHY
 * ---
 * The engine holds an in-memory PositionBook and drives every stop-loss,
 * take-profit and stop-out from it. Two engines would each hold their own book,
 * each evaluate the same positions, and each try to close them - duplicate
 * closes, doubled realised P/L, and a race on the account balance.
 *
 * That was ALWAYS true of tick-driven execution, but before the book it merely
 * duplicated work that the database would mostly serialise. Now it is a
 * correctness boundary, so it is enforced rather than assumed.
 *
 * HOW
 * ---
 * A Redis key held with SET NX PX and renewed on a timer. The value is a random
 * id unique to this process, and both renew and release are compare-and-set
 * against it, so a process that lost the lock can never renew or delete a lock
 * another instance now owns.
 *
 * FAILURE POSTURE
 * ---------------
 * Losing the lock is FATAL, not a warning. If this process can no longer prove
 * it is the only engine, its book may already be diverging from an instance
 * that is also acting on the same positions. Continuing to evaluate stops in
 * that state is worse than stopping: the container restarts, hydrates a fresh
 * book, and either re-acquires the lock or stays down. Never keep trading on a
 * lock you cannot prove you hold.
 *
 * A Redis outage therefore takes the engine down. That is deliberate - Redis is
 * already the tick transport, so an engine that cannot reach it has no prices
 * to act on either.
 */

import type Redis from 'ioredis';
import * as crypto from 'crypto';
import { engineLockKey } from '@btrader/engine-core';

const KEY = engineLockKey();

/** Lock lifetime. A dead engine's lock frees itself after this. */
const TTL_MS = Number(process.env.ENGINE_LOCK_TTL_MS ?? 30_000);

/**
 * Renewal cadence. Comfortably shorter than the TTL so a slow tick pass or a
 * GC pause does not let the lock lapse while the process is healthy - if it
 * lapsed, a second engine could legitimately take it while this one still runs.
 */
const RENEW_MS = Math.max(1_000, Math.floor(TTL_MS / 3));

/** Renew only if we still hold it. */
const RENEW_LUA = `
if redis.call('get', KEYS[1]) == ARGV[1] then
  return redis.call('pexpire', KEYS[1], ARGV[2])
else
  return 0
end`;

/** Release only our own lock, never someone else's. */
const RELEASE_LUA = `
if redis.call('get', KEYS[1]) == ARGV[1] then
  return redis.call('del', KEYS[1])
else
  return 0
end`;

export type InstanceLock = { release: () => Promise<void> };

/**
 * Acquire the engine lock, or reject.
 *
 * [onLost] fires if renewal ever fails; callers are expected to treat that as
 * fatal. It is a callback rather than a process.exit here so the caller can
 * flush logs and close connections on its own terms.
 */
export async function acquireInstanceLock(
  redis: Redis,
  onLost: (reason: string) => void,
): Promise<InstanceLock> {
  if (process.env.ENGINE_INSTANCE_LOCK === 'off') {
    // Escape hatch for local development and integration tests, which run
    // engines in-process. Never set this in a deployed environment.
    // eslint-disable-next-line no-console
    console.warn('[engine] INSTANCE LOCK DISABLED (ENGINE_INSTANCE_LOCK=off) - do not do this in production');
    return { release: async () => undefined };
  }

  const id = crypto.randomUUID();
  const got = await redis.set(KEY, id, 'PX', TTL_MS, 'NX');
  if (got !== 'OK') {
    const holder = await redis.get(KEY).catch(() => null);
    throw new Error(
      `another trading engine already holds ${KEY} (holder=${holder ?? 'unknown'}). ` +
        'Running two engines would double-execute stop-loss and stop-out. ' +
        `If the previous instance died, its lock clears within ${TTL_MS}ms.`,
    );
  }

  const timer = setInterval(() => {
    redis
      .eval(RENEW_LUA, 1, KEY, id, String(TTL_MS))
      .then((ok) => {
        if (ok !== 1) {
          clearInterval(timer);
          onLost('lock is held by another instance');
        }
      })
      .catch((e: Error) => {
        clearInterval(timer);
        onLost(`could not renew lock: ${e.message}`);
      });
  }, RENEW_MS);
  // Renewal must not be the only thing keeping the process alive.
  timer.unref?.();

  return {
    release: async () => {
      clearInterval(timer);
      await redis.eval(RELEASE_LUA, 1, KEY, id).catch(() => undefined);
    },
  };
}
