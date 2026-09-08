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
      crmOutbox: async (tenantId, eventType, payload) => {
        await prisma.crmSyncOutbox.create({ data: { tenantId, eventType, payload: payload as object } });
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
    await this.sub.psubscribe(`bt:*:${Channels.TICKS}`);
    this.sub.on('pmessage', (_p, channel, message) => {
      const tenantId = channel.split(':')[1];
      this.prices.set(tenantId, JSON.parse(message) as Tick);
    });
    await this.reloadLpConfigs();
    // Periodically re-sync bridges (admin may change config / credentials).
    setInterval(() => this.reloadLpConfigs().catch(() => undefined), 60_000);
    this.logger.log('engine ready (in-process execution + tick cache + A-book router)');
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
