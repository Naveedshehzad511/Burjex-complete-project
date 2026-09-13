import { Injectable, OnModuleInit, Logger } from '@nestjs/common';
import Redis from 'ioredis';
import { prisma } from '@btrader/db';
import { BtError, BtErrorCode, Channels, Tick } from '@btrader/shared';
import { PriceSource, LpExecutionRouter, venueKeyFor } from '@btrader/engine-core';

/**
 * Gateway trading facade: live quotes stay in-process (CRM/book P/L), but
 * market/pending/SL/TP execution is the Rust matching engine over HTTP.
 * Do not run onTickFast here — that would double-fire stops with Rust.
 */
class RustMatchingClient {
  constructor(
    private readonly url: string,
    private readonly token: string,
  ) {}

  private async rpc(method: string, path: string, body: unknown): Promise<any> {
    const headers: Record<string, string> = { 'content-type': 'application/json' };
    if (this.token) headers['x-engine-token'] = this.token;
    const res = await fetch(`${this.url}${path}`, {
      method,
      headers,
      body: body == null ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let json: any = {};
    try {
      json = text ? JSON.parse(text) : {};
    } catch {
      json = { message: text };
    }
    if (!res.ok) {
      const code = (json.code as BtErrorCode) || BtErrorCode.INTERNAL;
      throw new BtError(code, json.message || `matching engine HTTP ${res.status}`);
    }
    return json;
  }

  placeOrder(tenantId: string, req: any) {
    return this.rpc('POST', '/v1/place', { tenantId, ...req, type: req.type });
  }

  modifyOrder(tenantId: string, id: string, dto: any) {
    return this.rpc('PATCH', `/v1/orders/${id}`, { tenantId, ...dto });
  }

  cancelOrder(tenantId: string, id: string) {
    return this.rpc('DELETE', `/v1/orders/${id}`, { tenantId });
  }

  modifyPosition(tenantId: string, id: string, slPrice?: number | null, tpPrice?: number | null) {
    return this.rpc('PATCH', `/v1/positions/${id}`, { tenantId, slPrice, tpPrice });
  }

  setPositionOpenPrice(tenantId: string, id: string, openPrice: number) {
    return this.rpc('PATCH', `/v1/positions/${id}/open-price`, { tenantId, openPrice });
  }

  closePosition(tenantId: string, id: string, volume?: number, opts?: any) {
    return this.rpc('POST', `/v1/positions/${id}/close`, {
      tenantId,
      volume,
      closePriceOverride: opts?.closePriceOverride,
      requireAccountId: opts?.requireAccountId,
      accountIdForQueue: opts?.accountIdForQueue,
    });
  }

  async closeAll(tenantId: string, accountId: string): Promise<number> {
    const r = await this.rpc('POST', '/v1/close-all', { tenantId, accountId });
    return Number(r.closed ?? 0);
  }

  coverMore(tenantId: string, id: string, lots: number) {
    return this.rpc('POST', `/v1/positions/${id}/cover-more`, { tenantId, lots });
  }

  invalidateGroupCache(id?: string) {
    return this.rpc('POST', '/v1/cfg/invalidate', { id }).catch(() => undefined);
  }
}

@Injectable()
export class EngineProvider implements OnModuleInit {
  private readonly logger = new Logger('EngineProvider');
  readonly prices = new PriceSource();
  readonly lp = new LpExecutionRouter();
  readonly engine: RustMatchingClient;
  private readonly pub = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6380');
  private readonly sub = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6380');

  constructor() {
    const url = (process.env.RUST_ENGINE_URL ?? 'http://127.0.0.1:4300').replace(/\/$/, '');
    this.engine = new RustMatchingClient(url, process.env.RUST_ENGINE_TOKEN ?? '');
  }

  async onModuleInit() {
    await this.sub.psubscribe(`bt:*:${Channels.TICKS}`);
    this.sub.on('pmessage', (_p, channel, message) => {
      const tenantId = channel.split(':')[1];
      let tick: Tick;
      try {
        tick = JSON.parse(message) as Tick;
      } catch {
        return;
      }
      this.prices.set(tenantId, tick);
    });
    await this.reloadLpConfigs();
    setInterval(() => this.reloadLpConfigs().catch(() => undefined), 60_000);
    this.logger.log(`quotes cache on Redis ticks; execution via ${process.env.RUST_ENGINE_URL ?? 'http://127.0.0.1:4300'}`);
  }

  async activeSourceCode(tenantId: string, symbol: string): Promise<string | null> {
    return this.pub.hget(`bt:bestsrc:${tenantId}`, symbol);
  }

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
          secret: c.credentialRef ? process.env[`LP_SECRET_${c.credentialRef}`] ?? null : null,
        },
      });
    }
    if (configs.length) this.logger.log(`A-book venues configured: ${configs.length} row(s)`);
  }

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
