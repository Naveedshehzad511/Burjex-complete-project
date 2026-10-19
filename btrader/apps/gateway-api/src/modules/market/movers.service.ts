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
 * - Instruments: the ones the client's trading group offers (the same list the app's Quotes uses), classed
 *   Commodities (incl. metals) / Crypto / Indices / Stocks.
 * - Price: the last known bid (live tick; a last candle close for a symbol that has not ticked yet).
 * - Reference: the close of the last bar before the broker's current day began - the previous day's close.
 *   A symbol with no quote today is not a mover (nothing happened today).
 */
@Injectable()
export class MoversService {
  constructor(
    private readonly symbols: SymbolsService,
    private readonly quotes: QuotesService,
  ) {}

  /** Previous closes by symbol, per broker day: they do not change during the day. */
  private readonly prevCloses = new Map<string, number | null>();
  private prevCloseDay = 0;

  async movers(tenantId: string, accountId?: string, requireUserId?: string): Promise<MoversDto> {
    return ttlWrap(`movers:${tenantId}:${accountId ?? ''}:${requireUserId ?? ''}`, MOVERS_CACHE_MS, () =>
      this.compute(tenantId, accountId, requireUserId),
    );
  }

  private async compute(tenantId: string, accountId?: string, requireUserId?: string): Promise<MoversDto> {
    const now = Date.now();
    const dayStartSec = brokerDayStartSec(now, brokerUtcOffsetSec());

    const rows = (await this.symbols.list(tenantId, true, accountId, requireUserId)) as Array<{
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
    const prev = await this.loadPrevCloses(eligible.map((r) => r.symbol.toUpperCase()), dayStartSec);

    const candidates: MoverCandidate[] = [];
    for (const r of eligible) {
      const key = r.symbol.toUpperCase();
      const tick = tickBySymbol.get(key);
      const prevClose = prev.get(key);
      // No quote since the day began: it has not moved today.
      if (!tick || prevClose == null || !(tick.ts >= dayStartSec * 1000)) continue;
      // The stored bars are built from the bid, so the live price is the bid too (the mid would add half the spread).
      const price = tick.bid > 0 ? tick.bid : tick.ask;
      const pct = changePercent(price, prevClose);
      if (pct == null) continue;
      candidates.push({
        symbol: r.displaySymbol || r.symbol,
        underlying: r.symbol,
        name: r.description ?? '',
        category: moverCategory(r.class)!,
        price,
        digits: r.digits,
        changePct: pct,
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
    });
    return {
      asOf: now,
      gainers: pickMovers(candidates, 'gainers').map(dto),
      losers: pickMovers(candidates, 'losers').map(dto),
    };
  }

  /**
   * The close of the last minute bar before [dayStartSec], per symbol (one indexed lookup per symbol, so this stays
   * cheap on a large candle table). Remembered for the rest of the broker day.
   */
  private async loadPrevCloses(symbols: string[], dayStartSec: number): Promise<Map<string, number | null>> {
    if (this.prevCloseDay !== dayStartSec) {
      this.prevCloses.clear();
      this.prevCloseDay = dayStartSec;
    }
    const missing = symbols.filter((s) => !this.prevCloses.has(s));
    if (missing.length > 0) {
      const rows = await prisma.$queryRawUnsafe<Array<{ symbol: string; c: number }>>(
        `SELECT s.symbol AS symbol, b.c::float8 AS c
           FROM unnest($1::text[]) AS s(symbol)
           CROSS JOIN LATERAL (
             SELECT c FROM market_candles
              WHERE symbol = s.symbol AND tf = '1m' AND t < $2 AND t >= $3
              ORDER BY t DESC LIMIT 1
           ) b`,
        missing,
        dayStartSec,
        dayStartSec - PREV_CLOSE_MAX_AGE_SEC,
      );
      const found = new Map(rows.map((r) => [r.symbol.toUpperCase(), Number(r.c)]));
      for (const s of missing) this.prevCloses.set(s, found.get(s) ?? null);
    }
    return this.prevCloses;
  }
}
