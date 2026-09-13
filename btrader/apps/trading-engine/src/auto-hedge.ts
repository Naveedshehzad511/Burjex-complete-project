import { prisma } from '@btrader/db';
import type Redis from 'ioredis';

const d = (v: unknown): number => (v == null ? 0 : Number(v));

/**
 * Auto net-hedge sweep — kept in Node because it only writes hedge_orders for
 * the MT5 bridge. Matching/SL/TP is in Rust.
 */
export async function autoHedgeSweep(redis: Redis): Promise<void> {
  const rules = await prisma.autoHedgeRule.findMany({ where: { enabled: true } });
  if (!rules.length) return;
  const byTenant = new Map<string, typeof rules>();
  for (const r of rules) {
    const arr = byTenant.get(r.tenantId) ?? [];
    arr.push(r);
    byTenant.set(r.tenantId, arr);
  }
  for (const [tenantId, tenantRules] of byTenant) {
    const cfg = await prisma.lpExecutionConfig.findFirst({
      where: { tenantId, driver: 'MT5', enabled: true },
      orderBy: [{ isDefault: 'desc' }, { createdAt: 'asc' }],
      select: { lpProviderId: true },
    });
    if (!cfg) continue;
    for (const rule of tenantRules) {
      await autoHedgeSymbol(redis, tenantId, rule, cfg.lpProviderId).catch(() => undefined);
    }
  }
}

async function autoHedgeSymbol(
  redis: Redis,
  tenantId: string,
  rule: { symbolName: string; thresholdLots: unknown; minClipLots: unknown; maxClipLots: unknown },
  lpProviderId: string | null,
): Promise<void> {
  const sym = await prisma.symbol.findFirst({ where: { tenantId, symbol: rule.symbolName } });
  if (!sym) return;

  const inflight = await prisma.hedgeOrder.count({
    where: {
      tenantId,
      symbolName: rule.symbolName,
      kind: { in: ['BROKER_AUTO', 'BROKER_MANUAL'] },
      status: { in: ['PENDING', 'CLOSE_PENDING'] },
    },
  });
  if (inflight > 0) return;

  const positions = await prisma.position.findMany({
    where: { tenantId, symbolId: sym.id, status: 'OPEN', account: { isDemo: false } },
    select: { side: true, volume: true, coveredVolume: true },
  });
  let clientNet = 0;
  for (const p of positions) {
    const warehoused = Math.max(0, d(p.volume) - d(p.coveredVolume));
    clientNet += (p.side === 'BUY' ? 1 : -1) * warehoused;
  }

  const fills = await prisma.hedgeOrder.findMany({
    where: {
      tenantId,
      symbolName: rule.symbolName,
      kind: { in: ['BROKER_AUTO', 'BROKER_MANUAL'] },
      status: 'FILLED',
    },
    select: { side: true, volume: true },
  });
  let hedged = 0;
  for (const h of fills) hedged += (h.side === 'BUY' ? 1 : -1) * d(h.volume);

  const threshold = Math.abs(d(rule.thresholdLots));
  const sign = clientNet >= 0 ? 1 : -1;
  const desired = Math.abs(clientNet) <= threshold ? 0 : sign * (Math.abs(clientNet) - threshold);
  const delta = desired - hedged;

  const lotStep = d(sym.lotStep) || 0.01;
  const minClip = Math.max(d(rule.minClipLots) || lotStep, lotStep);
  let volume = Math.round(Math.abs(delta) / lotStep) * lotStep;
  if (volume < minClip) return;
  const maxClip = rule.maxClipLots == null ? null : Math.abs(d(rule.maxClipLots));
  if (maxClip && volume > maxClip) volume = maxClip;
  volume = Number(volume.toFixed(4));
  if (volume <= 0) return;

  const side = delta > 0 ? 'BUY' : 'SELL';
  let mid: number | null = null;
  try {
    const raw = await redis.hget(`bt:${tenantId}:lastticks`, sym.symbol);
    if (raw) {
      const t = JSON.parse(raw) as { bid?: number; ask?: number };
      if (t.bid != null && t.ask != null) mid = (t.bid + t.ask) / 2;
      else mid = t.bid ?? t.ask ?? null;
    }
  } catch {
    mid = null;
  }

  await prisma.hedgeOrder.create({
    data: {
      tenantId,
      symbolId: sym.id,
      symbolName: sym.symbol,
      side,
      volume,
      status: 'PENDING',
      kind: 'BROKER_AUTO',
      driver: 'MT5',
      lpProviderId,
      requestPrice: mid,
    },
  });
}
