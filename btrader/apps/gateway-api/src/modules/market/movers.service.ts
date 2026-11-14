import { Injectable } from '@nestjs/common';
import { prisma } from '@btrader/db';
import { ttlWrap } from '../../common/ttl-cache';
import { SymbolsService } from '../symbols/symbols.service';
import { QuotesService } from './quotes.service';
import {
  MoverCandidate,
  brokerDayStartSec,
  changePercent,
  moverCategory,
  pickMovers,
} from './movers.logic';

/** Shown on a card. */
export interface MoverDto {
  symbol: string;
  underlying: string;
  name: string;
  category: string;
  price: number;
  digits: number;
  changePct: number;
  /** True when the price is from the current broker day; false = the symbol's last trading day (market closed). */
  live: boolean;
}

export interface MoversDto {
  /** When this was computed (epoch ms). */
  asOf: number;
  gainers: MoverDto[];
  losers: MoverDto[];
}

/** The movers are recomputed at most this often per account: "near real time" without a query per phone per poll. */
const MOVERS_CACHE_MS = 5_000;

/** A previous close older than this is not "yesterday's" (a symbol that has not traded for a long time). */
const PREV_CLOSE_MAX_AGE_SEC = 10 * 86_400;

function brokerUtcOffsetSec(): number {
  const raw = process.env.BROKER_UTC_OFFSET_SEC;
  const n = raw == null || raw === '' ? 0 : parseInt(raw, 10);
  return Number.isFinite(n) ? n : 0;
}

/**
 * Top Gainers / Losers for the client app.
 *
 * - Instruments: every enabled instrument of the platform - NOT only the ones the client's trading group offers
 *   (the movers are market information; what an account may trade is decided elsewhere) - classed
 *   Commodities (incl. metals) / Crypto / Indices / Stocks. A symbol with no valid market data is left out.
 * - Price: the last known bid (live tick; a last candle close for a symbol that has not ticked yet).
 * - Reference: the close of the last bar before the day of that price began - the previous day's close.
 * - Market closed (night, weekend, holiday, feed paused): a symbol with no quote today still shows its LAST trading
 *   day - its last real price against the close before that day (e.g. Friday's move on Saturday). Each symbol keeps
 *   its own last session; nothing is invented, and a symbol with no real price in the last 10 days is left out.
 */
@Injectable()
export class MoversService {
  constructor(
    private readonly symbols: SymbolsService,
    private readonly quotes: QuotesService,
  ) {}

  /** Previous closes by `symbol|dayStart`: the close before a given broker day never changes. */
  private readonly prevCloses = new Map<string, number | null>();

  async movers(tenantId: string, _accountId?: string, _requireUserId?: string): Promise<MoversDto> {
    // The list no longer depends on the account, so one answer per tenant serves every client.
    return ttlWrap(`movers:${tenantId}`, MOVERS_CACHE_MS, () => this.compute(tenantId));
  }

  private async compute(tenantId: string): Promise<MoversDto> {
    const now = Date.now();
    const dayStartSec = brokerDayStartSec(now, brokerUtcOffsetSec());

    const rows = (await this.symbols.list(tenantId, true)) as Array<{
      symbol: string;
      displaySymbol?: string;
      description?: string | null;
      class: string;
      digits: number;
    }>;
    const eligible = rows.filter((r) => moverCategory(r.class) != null);
    if (eligible.length === 0) return { asOf: now, gainers: [], losers: [] };

    const ticks = await this.quotes.snapshot(tenantId);
    const tickBySymbol = new Map(ticks.map((t) => [String(t.symbol).toUpperCase(), t]));
    const offset = brokerUtcOffsetSec();

    // The last real price of each symbol and when it was: the live / last tick, or (no tick kept) the last minute bar.
    const last = new Map<string, { price: number; tsSec: number }>();
    for (const r of eligible) {
      const key = r.symbol.toUpperCase();
      const tick = tickBySymbol.get(key);
      // The stored bars are built from the bid, so the live price is the bid too (the mid would add half the spread).
      const price = tick ? (tick.bid > 0 ? tick.bid : tick.ask) : 0;
      if (tick && price > 0 && tick.ts > 0) last.set(key, { price, tsSec: Math.floor(tick.ts / 1000) });
    }
    const noTick = eligible.map((r) => r.symbol.toUpperCase()).filter((s) => !last.has(s));
    for (const [s, v] of await this.loadLastBars(noTick, Math.floor(now / 1000))) last.set(s, v);

    // Each symbol against the close before ITS price's day: today for a live symbol, its last session otherwise.
    const want = new Map<string, number>();
    for (const [s, v] of last) want.set(s, brokerDayStartSec(v.tsSec * 1000, offset));
    const prev = await this.loadPrevCloses(want);

    const candidates: (MoverCandidate & { live: boolean })[] = [];
    for (const r of eligible) {
      const key = r.symbol.toUpperCase();
      const lp = last.get(key);
      const day = want.get(key);
      if (!lp || day == null) continue;
      // Older than the 10-day window: not market data any more.
      if (lp.tsSec < dayStartSec - PREV_CLOSE_MAX_AGE_SEC) continue;
      const prevClose = prev.get(`${key}|${day}`);
      if (prevClose == null) continue;
      const pct = changePercent(lp.price, prevClose);
      if (pct == null) continue;
      candidates.push({
        symbol: r.displaySymbol || r.symbol,
        underlying: r.symbol,
        name: r.description ?? '',
        category: moverCategory(r.class)!,
        price: lp.price,
        digits: r.digits,
        changePct: pct,
        live: day === dayStartSec,
      });
    }

    const dto = (c: MoverCandidate): MoverDto => ({
      symbol: c.symbol,
      underlying: c.underlying,
      name: c.name,
      category: c.category,
      price: c.price,
      digits: c.digits,
      changePct: Math.round(c.changePct * 100) / 100,
      live: (c as MoverCandidate & { live: boolean }).live,
    });
    return {
      asOf: now,
      gainers: pickMovers(candidates, 'gainers').map(dto),
      losers: pickMovers(candidates, 'losers').map(dto),
    };
  }

  /** The last minute bar (close, time) of each symbol within the 10-day window, for symbols with no tick kept. */
  private async loadLastBars(symbols: string[], nowSec: number): Promise<Map<string, { price: number; tsSec: number }>> {
    const out = new Map<string, { price: number; tsSec: number }>();
    if (symbols.length === 0) return out;
    const rows = await prisma.$queryRawUnsafe<Array<{ symbol: string; c: number; t: number }>>(
      `SELECT s.symbol AS symbol, b.c::float8 AS c, b.t::float8 AS t
         FROM unnest($1::text[]) AS s(symbol)
         CROSS JOIN LATERAL (
           SELECT c, t FROM market_candles
            WHERE symbol = s.symbol AND tf = '1m' AND t >= $2
            ORDER BY t DESC LIMIT 1
         ) b`,
      symbols,
      nowSec - PREV_CLOSE_MAX_AGE_SEC,
    );
    for (const r of rows) {
      const c = Number(r.c);
      if (c > 0) out.set(r.symbol.toUpperCase(), { price: c, tsSec: Number(r.t) });
    }
    return out;
  }

  /**
   * The close of the last minute bar before each symbol's day start ([want]: symbol -> day start), one indexed lookup
   * per symbol and day. Remembered: the close before a past day start never changes.
   */
  private async loadPrevCloses(want: Map<string, number>): Promise<Map<string, number | null>> {
    if (this.prevCloses.size > 20_000) this.prevCloses.clear();
    const missing = [...want].filter(([s, d]) => !this.prevCloses.has(`${s}|${d}`));
    if (missing.length > 0) {
      const rows = await prisma.$queryRawUnsafe<Array<{ symbol: string; d: number; c: number }>>(
        `SELECT s.symbol AS symbol, s.d::float8 AS d, b.c::float8 AS c
           FROM unnest($1::text[], $2::bigint[]) AS s(symbol, d)
           CROSS JOIN LATERAL (
             SELECT c FROM market_candles
              WHERE symbol = s.symbol AND tf = '1m' AND t < s.d AND t >= s.d - $3
              ORDER BY t DESC LIMIT 1
           ) b`,
        missing.map(([s]) => s),
        missing.map(([, d]) => d),
        PREV_CLOSE_MAX_AGE_SEC,
      );
      const found = new Map(rows.map((r) => [`${r.symbol.toUpperCase()}|${Number(r.d)}`, Number(r.c)]));
      for (const [s, d] of missing) this.prevCloses.set(`${s}|${d}`, found.get(`${s}|${d}`) ?? null);
    }
    return this.prevCloses;
  }
}
