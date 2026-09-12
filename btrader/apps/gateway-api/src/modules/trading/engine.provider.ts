import { Injectable, OnModuleInit, Logger } from '@nestjs/common';
import Redis from 'ioredis';
import { prisma } from '@btrader/db';
import { Channels, Tick } from '@btrader/shared';
import { TradingEngine, PriceSource, LpExecutionRouter, venueKeyFor } from '@btrader/engine-core';

/**
 * In-process engine for the low-latency execution path: the gateway holds a
 * PriceSource fed directly from Redis ticks and runs TradingEngine synchronously
 * so REST order calls return a real fill immediately. The standalone
 * trading-engine service runs the same code for tick-driven SL/TP/stop-out and
 * horizontal scale; both share the DB as the source of truth.
 *
 * It also owns the A-book LpExecutionRouter: on boot (and on demand) it loads
 * each tenant's LpExecutionConfig and configures the matching bridge, so A-book
 * fills are covered to the LP.
 */
@Injectable()
export class EngineProvider implements OnModuleInit {
  private readonly logger = new Logger('EngineProvider');
  readonly prices = new PriceSource();
  readonly lp = new LpExecutionRouter();
  readonly engine: TradingEngine;
  private readonly pub = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6380');
  private readonly sub = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6380');

  constructor() {
    this.engine = new TradingEngine({
      prices: this.prices,
      lp: this.lp,
      emit: (evt) =>
        this.pub
          .publish(`bt:${evt.tenantId}:${Channels.ENGINE_EVT}`, JSON.stringify(evt))
          .catch(() => {}),
      crmOutbox: (tenantId, eventType, payload) => {
        void prisma.crmSyncOutbox.create({ data: { tenantId, eventType, payload: payload as object } }).catch(() => {});
        return Promise.resolve();
      },
      // BEST_PRICE venue routing: the currently-active pricing source per symbol
      // (written by market-data to bt:bestsrc:{tenant}).
      activeSource: async (tenantId, symbol) => this.pub.hget(`bt:bestsrc:${tenantId}`, symbol),
      // Refuse to fill opens on a stale/late feed (default 8s; 0 disables).
      maxPriceAgeMs: Number(process.env.MAX_PRICE_AGE_MS ?? 8000),
      maxFeedStillMs: Number(process.env.MAX_FEED_STILL_MS ?? 120000),
    });
  }

  async onModuleInit() {
    await this.engine.hydrateBook().catch((e) =>
      this.logger.warn(`position book hydrate failed: ${(e as Error).message}`),
    );
    await this.sub.psubscribe(`bt:*:${Channels.TICKS}`);
    await this.sub.subscribe(`bt:${Channels.ENGINE_CFG}`);
    this.sub.on('message', (channel, message) => {
      if (channel !== `bt:${Channels.ENGINE_CFG}`) return;
      try {
        const j = JSON.parse(message) as { type?: string; id?: string };
        if (j.type === 'group') this.engine.invalidateGroupCache(j.id);
        else this.engine.invalidateGroupCache();
      } catch {
        this.engine.invalidateGroupCache();
      }
    });
    const dirtyFast = new Map<string, { tenantId: string; symbol: string }>();
    const fastMs = Math.max(20, Number(process.env.ENGINE_FAST_INTERVAL_MS ?? 50));
    this.sub.on('pmessage', (_p, channel, message) => {
      const tenantId = channel.split(':')[1];
      let tick: Tick;
      try {
        tick = JSON.parse(message) as Tick;
      } catch {
        return;
      }
      this.prices.set(tenantId, tick);
      dirtyFast.set(`${tenantId}\u0000${tick.symbol}`, { tenantId, symbol: tick.symbol });
    });
    setInterval(() => {
      if (dirtyFast.size === 0) return;
      const batch = [...dirtyFast.values()];
      dirtyFast.clear();
      for (const w of batch) {
        void this.engine.onTickFast(w.tenantId, w.symbol).catch(() => undefined);
      }
    }, fastMs);
    await this.reloadLpConfigs();
    setInterval(() => this.reloadLpConfigs().catch(() => undefined), 60_000);
    this.logger.log(`engine ready (in-process fill + SL/TP/pending drain every ${fastMs}ms)`);
  }

  /** Currently-active pricing source code for a (tenant, symbol), or null. */
  async activeSourceCode(tenantId: string, symbol: string): Promise<string | null> {
    return this.pub.hget(`bt:bestsrc:${tenantId}`, symbol);
  }

  /** (Re)load every tenant venue from its LpExecutionConfig rows (multi-venue). */
  async reloadLpConfigs(): Promise<void> {
    const configs = await prisma.lpExecutionConfig.findMany();
    for (const c of configs) {
      const venueKey = venueKeyFor(c.tenantId, c.lpProviderId, c.driver);
      await this.lp.configure(venueKey, c.tenantId, {
        driver: c.driver,
        enabled: c.enabled,
        simSlippageBps: c.simSlippageBps,
        simRejectPct: c.simRejectPct,
        conn: {
          endpoint: c.endpoint,
          senderCompId: c.senderCompId,
          targetCompId: c.targetCompId,
          // Secret is resolved from the secret store by the bridge, not stored here.
          secret: c.credentialRef ? process.env[`LP_SECRET_${c.credentialRef}`] ?? null : null,
        },
      });
    }
    if (configs.length) this.logger.log(`A-book venues configured: ${configs.length} row(s)`);
  }

  /** Reconfigure all of a single tenant's venues (called after an admin edit). */
  async reloadLpConfig(tenantId: string): Promise<void> {
    await this.lp.clearTenant(tenantId);
    const rows = await prisma.lpExecutionConfig.findMany({ where: { tenantId } });
    for (const c of rows) {
      const venueKey = venueKeyFor(tenantId, c.lpProviderId, c.driver);
      await this.lp.configure(venueKey, tenantId, {
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
}
