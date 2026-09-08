import { Injectable } from '@nestjs/common';
import Redis from 'ioredis';
import { prisma } from '@btrader/db';
import { Tick } from '@btrader/shared';

/**
 * Last-known-quote snapshot. market-data writes the last real tick per symbol to
 * `bt:{tenant}:lastticks`; this serves it so the client watchlist can seed from
 * it and never show a blank price (a stale-but-real price when a symbol isn't
 * currently ticking — never a fabricated one).
 */
@Injectable()
export class QuotesService {
  private readonly redis = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6380');

  async snapshot(tenantId: string): Promise<Tick[]> {
    const [raw, symbols] = await Promise.all([
      this.redis.hgetall(`bt:${tenantId}:lastticks`),
      prisma.symbol.findMany({ where: { tenantId, enabled: true }, select: { symbol: true } }),
    ]);
    const allowed = new Set(symbols.map((s) => s.symbol.toUpperCase()));
    const out: Tick[] = [];
    const seen = new Set<string>();
    for (const [sym, val] of Object.entries(raw)) {
      if (!allowed.has(sym.toUpperCase())) continue;
      try {
        out.push(JSON.parse(val) as Tick);
        seen.add(sym.toUpperCase());
      } catch {
        // skip a corrupt entry
      }
    }

    // Fallback for symbols that haven't ticked since the feed came up (e.g. a
    // closed/quiet FX market): use the last stored candle close — a real,
    // durable price — so the watchlist is never blank. bid=ask (no spread) until
    // a live tick refines it; the stale timestamp keeps it out of order fills.
    const missing = [...allowed].filter((s) => !seen.has(s));
    if (missing.length) {
      const rows = await prisma.marketCandle.findMany({
        where: { symbol: { in: missing } },
        orderBy: [{ symbol: 'asc' }, { t: 'desc' }],
        distinct: ['symbol'],
        select: { symbol: true, c: true, t: true },
      });
      for (const r of rows) {
        const c = Number(r.c);
        out.push({ symbol: r.symbol, bid: c, ask: c, ts: r.t * 1000 });
      }
    }
    return out;
  }
}
