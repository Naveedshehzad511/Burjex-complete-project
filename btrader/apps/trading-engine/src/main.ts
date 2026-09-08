// ============================================================================
//  Trading Engine service entrypoint.
//  - Subscribes to normalized ticks (Redis pub/sub) → updates PriceSource,
//    runs onTick (pending triggers, SL/TP, stop-out), pushes account updates.
//  - Consumes engine commands (place/close/modify) from a Redis Stream so the
//    gateway-api can offload execution. Also usable in-process by importing
//    TradingEngine directly (low-latency path).
// ============================================================================

import Redis from 'ioredis';
import * as crypto from 'crypto';
import { prisma } from '@btrader/db';
import { Channels, Tick } from '@btrader/shared';
import { PriceSource, TradingEngine, LpExecutionRouter, venueKeyFor, tenantOwnedByThisShard, engineShard, engineShardCount } from '@btrader/engine-core';
import { maybeApplySwaps } from './swap-accrual';
import { acquireInstanceLock } from './instance-lock';

const REDIS_URL = process.env.REDIS_URL ?? 'redis://localhost:6380';

async function main() {
  const prices = new PriceSource();
  const pub = new Redis(REDIS_URL);
  const sub = new Redis(REDIS_URL);

  // Exactly one engine, enforced. The in-memory position book makes a second
  // instance a correctness problem, not just wasted work - see instance-lock.ts.
  const lock = await acquireInstanceLock(pub, (reason) => {
    // eslint-disable-next-line no-console
    console.error(
      `[engine] FATAL: lost the instance lock (${reason}). Exiting rather than ` +
        'risk a second engine acting on the same positions.',
    );
    process.exit(1);
  });

  for (const sig of ['SIGTERM', 'SIGINT'] as const) {
    process.on(sig, () => {
      // Hand the lock back on a clean stop so a replacement can start at once
      // instead of waiting out the TTL.
      lock.release().finally(() => process.exit(0));
    });
  }

  // A-book router so tick-driven pending-order fills are covered to the LP too.
  const lp = new LpExecutionRouter();
  await loadLpConfigs(lp);
  setInterval(() => loadLpConfigs(lp).catch(() => undefined), 60_000);

  const engine = new TradingEngine({
    prices,
    lp,
    emit: (evt) => {
      // Broadcast engine events for the WS gateway to fan out to clients.
      pub.publish(`bt:${evt.tenantId}:${Channels.ENGINE_EVT}`, JSON.stringify(evt)).catch(() => {});
    },
    crmOutbox: async (tenantId, eventType, payload) => {
      await prisma.crmSyncOutbox.create({
        data: { tenantId, eventType, payload: payload as object },
      });
    },
    activeSource: async (tenantId, symbol) => pub.hget(`bt:bestsrc:${tenantId}`, symbol),
    maxPriceAgeMs: Number(process.env.MAX_PRICE_AGE_MS ?? 8000),
    maxFeedStillMs: Number(process.env.MAX_FEED_STILL_MS ?? 120000),
  });

  // Ticks arrive far faster than the DB can service onTick, which runs several
  // queries per pass. Calling onTick straight from the subscriber let every
  // tick start its own concurrent pass, so a busy feed piled up hundreds of
  // overlapping passes, exhausted the Prisma connection pool, and made ALL
  // tick-driven work fail with pool timeouts — pending orders never triggered
  // and SL/TP/stop-out never fired.
  //
  // Instead: apply the price synchronously (that is what order fills read), then
  // just mark the symbol dirty. A drain loop coalesces to at most one pass per
  // symbol per interval and runs them with bounded concurrency, so DB usage is
  // capped no matter how fast the feed is.
  // #2A: two dirty sets drained on two cadences.
  //  - fast: pending triggers + protective SL/TP — latency-critical and cheap
  //    (protective reads the in-memory book; the pending query is one indexed
  //    lookup), so it runs often to cut "late SL / late limit" to tens of ms.
  //  - slow: stop-out + live P&L — heavier, stays coalesced at the old cadence.
  const dirtyFast = new Map<string, { tenantId: string; symbol: string }>();
  const dirtySlow = new Map<string, { tenantId: string; symbol: string }>();
  const drainMs = Math.max(50, Number(process.env.ENGINE_TICK_INTERVAL_MS ?? 250));
  const fastMs = Math.max(20, Number(process.env.ENGINE_FAST_INTERVAL_MS ?? 50));
  const drainConcurrency = Math.max(1, Number(process.env.ENGINE_TICK_CONCURRENCY ?? 4));
  const fastState = { busy: false };
  const slowState = { busy: false };

  // The position book must be full before the first tick pass. An unhydrated
  // book reports every symbol as holding nothing, so stop-losses, take-profits
  // and stop-out would all silently no-op for as long as it took to fill.
  const held = await engine.hydrateBook();
  // eslint-disable-next-line no-console
  console.log(`[engine] position book hydrated: ${held} open positions`);

  // Positions are also written outside the engine - swap accrual, admin tools,
  // anything with a Prisma client. Write-through cannot see those, so re-read
  // the authority on an interval and correct the difference.
  //
  // A non-zero result is a BUG REPORT, not routine maintenance: it means some
  // write path is not updating the book, and between two reconciles that
  // position was being evaluated against stale numbers. Logged loudly on
  // purpose - self-healing in silence is how this kind of drift goes unnoticed.
  const reconcileMs = Math.max(5_000, Number(process.env.ENGINE_BOOK_RECONCILE_MS ?? 30_000));
  setInterval(() => {
    engine
      .reconcileBook()
      .then((r) => {
        if (r.missing || r.stale || r.extra) {
          // eslint-disable-next-line no-console
          console.warn(
            `[engine] position book DRIFT corrected: missing=${r.missing} stale=${r.stale} extra=${r.extra} ` +
              `- a write path is not updating the book`,
          );
        }
      })
      .catch((e) => {
        // eslint-disable-next-line no-console
        console.error('[engine] position book reconcile failed', (e as Error).message);
      });
  }, reconcileMs);

  await sub.psubscribe(`bt:*:${Channels.TICKS}`);
  sub.on('pmessage', (_pattern, channel, message) => {
    // channel = bt:{tenantId}:ticks
    const tenantId = channel.split(':')[1];
    let tick: Tick;
    try {
      tick = JSON.parse(message) as Tick;
    } catch {
      return;
    }
    prices.set(tenantId, tick);
    if (!tenantOwnedByThisShard(tenantId)) return;
    const work = { tenantId, symbol: tick.symbol };
    const dkey = `${tenantId}\u0000${tick.symbol}`;
    dirtyFast.set(dkey, work);
    dirtySlow.set(dkey, work);
  });

  // Drain one dirty set with bounded concurrency. A slow pass just leaves
  // symbols dirty for the next interval — never queue a second drain of the
  // same set on top of one already running.
  async function drainSet(
    map: Map<string, { tenantId: string; symbol: string }>,
    state: { busy: boolean },
    run: (tenantId: string, symbol: string) => Promise<void>,
  ): Promise<void> {
    if (state.busy || map.size === 0) return;
    state.busy = true;
    try {
      const batch = [...map.values()];
      map.clear();
      for (let i = 0; i < batch.length; i += drainConcurrency) {
        await Promise.all(
          batch.slice(i, i + drainConcurrency).map((w) =>
            run(w.tenantId, w.symbol).catch((e) => {
              // Engine must never crash the loop; log and continue.
              // eslint-disable-next-line no-console
              console.error(`onTick error [${w.symbol}]`, (e as Error).message);
            }),
          ),
        );
      }
    } finally {
      state.busy = false;
    }
  }

  setInterval(() => void drainSet(dirtyFast, fastState, (t, s) => engine.onTickFast(t, s)), fastMs);
  setInterval(() => void drainSet(dirtySlow, slowState, (t, s) => engine.onTickSlow(t, s)), drainMs);
  setInterval(() => void engine.refreshPendings().catch(() => undefined), fastMs);
  // eslint-disable-next-line no-console
  console.log(
    `[trading-engine] tick worker: fast ${fastMs}ms (pending+SL/TP), slow ${drainMs}ms (stop-out+P&L), concurrency ${drainConcurrency}, shard ${engineShard()}/${engineShardCount()}`,
  );

  // Consume execution commands from the gateway via a Redis Stream consumer group.
  const STREAM = 'bt:engine:cmd';
  const GROUP = 'engine';
  await pub.xgroup('CREATE', STREAM, GROUP, '$', 'MKSTREAM').catch(() => {});
  consumeCommands(pub, engine, STREAM, GROUP).catch((e) => console.error(e));

  // ── CRM outbox delivery worker ─────────────────────────────────────────────
  // Always runs: each event is delivered to ITS tenant's configured CRM webhook
  // (admin → Integrations), falling back to CRM_WEBHOOK_URL for single-tenant.
  setInterval(() => drainCrmOutbox().catch((e) => console.error('[outbox]', e?.message)), 2000);
  console.log('[trading-engine] CRM outbox worker active (per-tenant webhooks)');

  // ── Overnight swap accrual (checks for the rollover hour each minute) ────────
  setInterval(() => maybeApplySwaps().catch((e) => console.error('[swaps]', e?.message)), 60_000);

  // ── Auto net-hedge sweep: cover B-book exposure over per-symbol thresholds ───
  const autoHedgeSec = Math.max(5, Number(process.env.AUTOHEDGE_INTERVAL_SEC ?? 15));
  setInterval(() => engine.autoHedgeSweep().catch((e) => console.error('[autohedge]', e?.message)), autoHedgeSec * 1000);
  console.log(`[trading-engine] auto net-hedge sweep every ${autoHedgeSec}s`);

  // eslint-disable-next-line no-console
  console.log('[trading-engine] running, subscribed to ticks + command stream');
}

// ── A-book bridge configs: load every tenant's LP execution config ────────────
async function loadLpConfigs(lp: LpExecutionRouter): Promise<void> {
  const configs = await prisma.lpExecutionConfig.findMany();
  for (const c of configs) {
    const venueKey = venueKeyFor(c.tenantId, c.lpProviderId, c.driver);
    await lp.configure(venueKey, c.tenantId, {
      driver: c.driver,
      enabled: c.enabled,
      simSlippageBps: c.simSlippageBps,
      simRejectPct: c.simRejectPct,
      conn: {
        endpoint: c.endpoint,
        senderCompId: c.senderCompId,
        targetCompId: c.targetCompId,
        secret: c.credentialRef ? process.env[`LP_SECRET_${c.credentialRef}`] ?? null : null,
      },
    });
  }
}

// ── CRM outbox: at-least-once delivery with exponential backoff ───────────────
async function drainCrmOutbox(): Promise<void> {
  const due = await prisma.crmSyncOutbox.findMany({
    where: { status: 'PENDING', nextAttempt: { lte: new Date() } },
    orderBy: { createdAt: 'asc' },
    take: 50,
  });
  for (const evt of due) {
    try {
      await deliverToCrm(evt);
      await prisma.crmSyncOutbox.update({
        where: { id: evt.id },
        data: { status: 'SENT', sentAt: new Date() },
      });
    } catch (e: any) {
      const attempts = evt.attempts + 1;
      const backoffSec = Math.min(2 ** attempts, 300); // cap 5 min
      await prisma.crmSyncOutbox.update({
        where: { id: evt.id },
        data: {
          attempts,
          lastError: String(e?.message ?? e),
          nextAttempt: new Date(Date.now() + backoffSec * 1000),
          status: attempts >= 10 ? 'FAILED' : 'PENDING',
        },
      });
    }
  }
}

async function deliverToCrm(evt: {
  id: string;
  tenantId: string;
  eventType: string;
  payload: unknown;
  createdAt: Date;
}): Promise<void> {
  // Per-tenant CRM config wins; fall back to env for single-tenant setups.
  const cfg = await prisma.crmConfig.findUnique({ where: { tenantId: evt.tenantId } });
  const url = cfg?.enabled ? cfg.webhookUrl : null;
  const fallbackUrl = process.env.CRM_WEBHOOK_URL ?? null;
  const target = url ?? fallbackUrl;
  if (!target) {
    // No CRM configured for this tenant → acknowledge so it doesn't retry forever.
    return;
  }
  const secret = (cfg?.enabled ? cfg.webhookSecret : null) ?? process.env.CRM_WEBHOOK_SECRET ?? '';
  // Optional event filter.
  if (cfg?.enabled && cfg.events.length && !cfg.events.includes(evt.eventType)) return;

  const body = JSON.stringify({
    id: evt.id,
    tenantId: evt.tenantId,
    type: evt.eventType,
    occurredAt: evt.createdAt.toISOString(),
    data: evt.payload,
  });
  const ts = Date.now().toString();
  const sig = crypto.createHmac('sha256', secret).update(`${ts}.${body}`).digest('hex');
  const res = await fetch(target, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-BT-Timestamp': ts, 'X-BT-Signature': sig },
    body,
  });
  if (!res.ok) throw new Error(`CRM webhook responded ${res.status}`);
}


async function consumeCommands(redis: Redis, engine: TradingEngine, stream: string, group: string) {
  const consumer = `engine-${process.pid}`;
  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      await redis.xautoclaim(stream, group, consumer, 30_000, '0-0', 'COUNT', 20);
    } catch {
      /* group may not exist yet */
    }
    const res = (await redis.xreadgroup(
      'GROUP',
      group,
      consumer,
      'COUNT',
      50,
      'BLOCK',
      2000,
      'STREAMS',
      stream,
      '>',
    )) as [string, [string, string[]][]][] | null;
    if (!res) continue;
    for (const [, entries] of res) {
      for (const [id, fields] of entries) {
        try {
          const cmd = JSON.parse(fields[1]);
          await dispatch(engine, cmd);
          await redis.xack(stream, group, id);
        } catch (e) {
          console.error('cmd error', (e as Error).message);
          // Leave in PEL for retry — never ack a failed money command.
        }
      }
    }
  }
}

async function dispatch(engine: TradingEngine, cmd: any) {
  if (cmd.tenantId && !tenantOwnedByThisShard(cmd.tenantId)) return;
  switch (cmd.kind) {
    case 'PLACE_ORDER':
      return engine.placeOrder(cmd.tenantId, cmd.payload);
    case 'CLOSE_POSITION':
      return engine.closePosition(cmd.tenantId, cmd.positionId, cmd.volume);
    case 'CLOSE_ALL':
      return engine.closeAll(cmd.tenantId, cmd.accountId);
    case 'MODIFY_POSITION':
      return engine.modifyPosition(cmd.tenantId, cmd.positionId, cmd.sl, cmd.tp);
    case 'CANCEL_ORDER':
      return engine.cancelOrder(cmd.tenantId, cmd.orderId);
    default:
      return undefined;
  }
}

main().catch((e) => {
  // eslint-disable-next-line no-console
  console.error('[trading-engine] fatal', e);
  process.exit(1);
});
