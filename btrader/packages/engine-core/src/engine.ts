// ============================================================================
//  Trading Engine — execution + position lifecycle + risk + margin.
//  Authoritative money mutations happen here inside DB transactions.
//
//  Decimal note: hot-path math uses JS number for speed; all PERSISTED money is
//  written through Prisma Decimal(28,8). For a production deployment the
//  ledger-affecting steps should use a decimal lib (e.g. decimal.js) — the
//  calc.ts functions are pure and swappable. Kept as number here for clarity.
// ============================================================================

import { prisma, Prisma } from '@btrader/db';

import { PositionBook, type BookRow } from './position-book';
import { PendingBook, type PendingRow } from './pending-book';
import { pendingFires, isLimitFillType, protectiveHit } from './trigger';
import {
  PlaceOrderRequest,
  ExecutionResult,
  OrderSide,
  OrderType,
  BtError,
  BtErrorCode,
  AccountSnapshot,
  LpExecDriver,
  BookType,
  latency,
  counters,
} from '@btrader/shared';
import { PriceSource } from './price-source';
import { isSymbolTradable, sessionClosesAt, SessionWindow } from './sessions';
import { resolveBook } from './book';
import { resolveRouting, RoutingRuleLike, RoutingResolution } from './routing';
import { LpExecutionRouter, venueKeyFor } from './lp';
import {
  SymbolCalcSpec,
  requiredMargin,
  positionProfit,
  computeAggregates,
  normalizeVolume,
  snapVolume,
  roundPrice,
  slippageBound,
  pointSize,
  applyMarkup,
  dealingCommission,
  spreadMarkupFromBand,
  commissionFromMapping,
  splitPositionCharges,
  worstPosition,
  resolveFxFactor,
  withdrawableCash,
  GroupPricing,
  OpenPositionView,
} from './calc';

const d = (v: Prisma.Decimal | number | string | null | undefined): number =>
  v == null ? 0 : typeof v === 'number' ? v : Number(v);

/** Snap a lot amount to the symbol's lot step, kept to 4dp (Decimal(12,4)). */
function roundLots(v: number, step: number): number {
  const s = step > 0 ? step : 0.01;
  return Number((Math.round(v / s) * s).toFixed(4));
}

type SymbolRow = Awaited<ReturnType<typeof prisma.symbol.findFirst>>;

/** How long a tick-path symbol lookup stays cached. */
const SYMBOL_CACHE_TTL_MS = 30_000;

/** How often the floating-P/L cache on `Position.profit` is flushed to the DB. */
const PROFIT_PERSIST_MS = Number(process.env.PROFIT_PERSIST_MS ?? 2000);

/**
 * A pending order is claimed as PARTIAL while its market fill is in flight. If the
 * process dies (or the restore write itself fails) the claim is never released, so
 * an untouched claim older than this is treated as PENDING again.
 */
const STALE_CLAIM_MS = 30_000;

function specOf(sym: NonNullable<SymbolRow>): SymbolCalcSpec {
  return {
    digits: sym.digits,
    pipSize: d(sym.pipSize),
    contractSize: d(sym.contractSize),
    marginRate: d(sym.marginRate),
    // #14: per-symbol margin % (crypto/metals) — leverage-independent when set.
    marginPercent: sym.marginPercent == null ? null : d(sym.marginPercent),
    quoteCurrency: sym.quoteCurrency,
    baseCurrency: sym.baseCurrency,
  };
}

export interface EngineDeps {
  prices: PriceSource;
  /** Emit an engine event (account/position/order update) onto the bus. */
  emit?: (evt: { kind: string; tenantId: string; [k: string]: unknown }) => void;
  /** Enqueue a CRM outbox event for reliable delivery. */
  crmOutbox?: (tenantId: string, eventType: string, payload: unknown) => Promise<void>;
  /** A-book execution router; when present, A-book fills are covered to the LP. */
  lp?: LpExecutionRouter;
  /** Current best-price source code per (tenant, symbol) — for BEST_PRICE venue
   *  routing. Reads market-data's `bt:bestsrc:{tenant}` map. Optional. */
  activeSource?: (tenantId: string, symbol: string) => Promise<string | null>;
  /** Reject opens when the latest tick is older than this (ms). 0/undefined =
   *  disabled. Blocks trading on a stale/frozen/late feed (e.g. weekends). */
  maxPriceAgeMs?: number;
  /** Refuse to open when the whole book has been frozen this long. 0 disables. */
  maxFeedStillMs?: number;
}

/**
 * Tiny in-memory TTL cache for rarely-changing config read on every order
 * (group pricing, symbol-group default book, routing rules). Admin edits
 * propagate within the TTL. Caches negatives (null) too, so a missing row
 * doesn't re-hit the DB each order.
 */
class TtlCache<V> {
  private readonly m = new Map<string, { v: V; at: number }>();
  constructor(private readonly ttlMs: number) {}
  get(key: string): { v: V } | undefined {
    const e = this.m.get(key);
    if (!e) return undefined;
    if (Date.now() - e.at > this.ttlMs) {
      this.m.delete(key);
      return undefined;
    }
    return { v: e.v };
  }
  set(key: string, v: V): void {
    this.m.set(key, { v, at: Date.now() });
  }
}

// Config that changes only on admin action → short TTL is safe and cuts several
// DB round-trips off every order.
const _CONFIG_TTL_MS = 5000;

function toBookRow(r: Record<string, unknown>, accountCurrency: string): BookRow {
  return { ...r, accountCurrency } as BookRow;
}

export class TradingEngine {
  constructor(private readonly deps: EngineDeps) {}

  private readonly _groupCache = new TtlCache<Prisma.TradingGroupGetPayload<{
    include: { rules: true; symbolMappings: true };
  }> | null>(_CONFIG_TTL_MS);
  private readonly _symGroupBookCache = new TtlCache<{ defaultBook: BookType } | null>(_CONFIG_TTL_MS);
  private readonly _routingCache = new TtlCache<RoutingRuleLike[]>(_CONFIG_TTL_MS);

  // ── PLACE ORDER ───────────────────────────────────────────────────────────
  async placeOrder(tenantId: string, req: PlaceOrderRequest): Promise<ExecutionResult> {
    const stopValidate = latency.start('order.validate');
    // Account + symbol are independent reads — fetch them in parallel.
    const [account, sym] = await Promise.all([
      prisma.account.findFirst({ where: { id: req.accountId, tenantId } }),
      prisma.symbol.findFirst({ where: { tenantId, symbol: req.symbol } }),
    ]);
    if (!account) throw new BtError(BtErrorCode.VALIDATION, 'account not found');
    if (account.status === 'TRADING_DISABLED' || account.status === 'READ_ONLY')
      throw new BtError(BtErrorCode.TRADING_DISABLED);
    if (!sym) throw new BtError(BtErrorCode.VALIDATION, 'symbol not found');
    if (!sym.enabled) throw new BtError(BtErrorCode.SYMBOL_DISABLED);

    // Instrument visibility: if the account's trading group restricts which
    // symbol groups it can see, reject symbols outside that set. Defence in
    // depth — the client app also hides them from the symbol list, but a direct
    // order on a hidden-yet-enabled symbol must still be refused.
    if (account.groupId) {
      // Precedence: per-symbol picks > symbol-group buckets > all enabled.
      const picks = await prisma.tradingGroupSymbol.findMany({
        where: { tradingGroupId: account.groupId },
        select: { symbolId: true },
      });
      if (picks.length > 0) {
        if (!picks.some((p) => p.symbolId === sym.id))
          throw new BtError(BtErrorCode.SYMBOL_DISABLED, 'symbol not available for your account group');
      } else {
        const access = await prisma.tradingGroupSymbolAccess.findMany({
          where: { tradingGroupId: account.groupId },
          select: { symbolGroupId: true },
        });
        if (access.length > 0) {
          const allowed = new Set(access.map((a) => a.symbolGroupId));
          if (!sym.groupId || !allowed.has(sym.groupId))
            throw new BtError(BtErrorCode.SYMBOL_DISABLED, 'symbol not available for your account group');
        }
      }
    }
    if (!isSymbolTradable(sym.tradingSessions as unknown as SessionWindow[] | null, sym.class, new Date()))
      throw new BtError(BtErrorCode.MARKET_CLOSED);

    // News mode: pause OPENING new positions during a high-impact news event
    // (this is placeOrder — closes go through closePosition and stay allowed).
    if (sym.newsMode && sym.newsHaltOpens)
      throw new BtError(BtErrorCode.MARKET_CLOSED, 'trading paused — news event (new orders halted)');

    const spec = specOf(sym);
    const volume = snapVolume(req.volume, d(sym.minLot), d(sym.maxLot), d(sym.lotStep));
    if (volume == null || volume <= 0) {
      throw new BtError(
        BtErrorCode.INVALID_VOLUME,
        `invalid volume ${req.volume} (min ${sym.minLot}, max ${sym.maxLot}, step ${sym.lotStep})`,
      );
    }

    await this.enforceRisk(tenantId, account.id, req.symbol, volume);
    stopValidate();

    if (req.clientOrderId) {
      const dup = await prisma.order.findFirst({
        where: { tenantId, accountId: account.id, clientOrderId: req.clientOrderId },
      });
      if (dup) {
        counters.inc('order.idempotent_hit');
        return this.existingToResult(dup);
      }
    }

    const isMarket = req.type === 'MARKET';
    if (isMarket) {
      const tif = (req.timeInForce ?? 'GTC').toUpperCase();
      try {
        return await this.executeMarket(tenantId, account, sym, spec, req, volume);
      } catch (err) {
        if (
          (tif === 'IOC' || tif === 'FOK') &&
          err instanceof BtError &&
          err.code === BtErrorCode.NO_PRICE
        ) {
          counters.inc('order.ioc_cancelled');
          const cancelled = await prisma.order.create({
            data: {
              tenantId,
              accountId: account.id,
              symbolId: sym.id,
              side: req.side,
              type: 'MARKET',
              status: tif === 'FOK' ? 'REJECTED' : 'CANCELLED',
              volume,
              rejectReason: err.message,
              clientOrderId: req.clientOrderId ?? null,
              source: req.source ?? 'api',
            },
          });
          return {
            accepted: false,
            orderId: cancelled.id,
            status: cancelled.status,
            reason: err.message,
          };
        }
        throw err;
      }
    }
    return this.placePending(tenantId, account, sym, spec, req, volume);
  }

  private existingToResult(order: {
    id: string;
    status: string;
    positionId: string | null;
    avgFillPrice: Prisma.Decimal | number | null;
    filledVolume: Prisma.Decimal | number;
  }): ExecutionResult {
    return {
      accepted: order.status === 'FILLED' || order.status === 'PENDING' || order.status === 'PARTIAL',
      orderId: order.id,
      positionId: order.positionId ?? undefined,
      status: order.status as ExecutionResult['status'],
      fillPrice: order.avgFillPrice != null ? d(order.avgFillPrice) : undefined,
      filledVolume: d(order.filledVolume),
    };
  }

  // ── TRADING-GROUP PRICING ─────────────────────────────────────────────────
  /**
   * Resolve the effective spread markup + dealing commission for an account's
   * group on a given symbol. Layered: per-symbol rule > per-class rule > group
   * default. Returns zero pricing when the account has no group (or it's off).
   */
  private async groupPricing(
    groupId: string | null,
    sym: NonNullable<SymbolRow>,
    tenantId?: string,
  ): Promise<GroupPricing> {
    const none: GroupPricing = { markupPoints: 0, slippagePoints: 0, commissionType: 'NONE', commissionValue: 0, executionMode: 'MARKET', instantDeviationPoints: 0 };
    if (!groupId) return none;
    // Cache group + rules + symbol mappings (changes only on admin edit; ~5s TTL).
    const cached = this._groupCache.get(groupId);
    let group = cached?.v;
    if (!cached) {
      group = await prisma.tradingGroup.findUnique({
        where: { id: groupId },
        include: { rules: true, symbolMappings: true },
      });
      this._groupCache.set(groupId, group ?? null);
    }
    if (!group || !group.enabled) return none;

    // Prefer per-symbol Symbol Mapping (LP → client pricing) when configured.
    // Spec: mapping is the sole markup source for mapped symbols — never stack
    // GroupMarkupRule / group.markupPoints on top (no dual path).
    const mapping =
      group.symbolMappings?.find(
        (m) =>
          m.enabled &&
          (m.symbolId === sym.id ||
            m.lpSymbol.toUpperCase() === sym.symbol.toUpperCase()),
      ) ?? null;
    const hasMappings = (group.symbolMappings?.length ?? 0) > 0;

    let markupPoints = 0;
    let minSpreadPoints = 0;
    let maxSpreadPoints = 0;
    let pricingMethod: GroupPricing['pricingMethod'];
    let commissionType: GroupPricing['commissionType'] = 'NONE';
    let commissionValue = 0;

    if (mapping) {
      pricingMethod = mapping.pricingMethod as GroupPricing['pricingMethod'];
      minSpreadPoints = mapping.minSpreadPoints;
      maxSpreadPoints = mapping.maxSpreadPoints;
      const tick = tenantId ? this.deps.prices.get(tenantId, sym.symbol) : undefined;
      const lpSpreadPts =
        tick && sym.digits >= 0
          ? Math.max(0, (tick.ask - tick.bid) / pointSize(sym.digits))
          : 0;
      // Mapping owns pricing — no legacy fallback (min=max=0 ⇒ zero markup).
      markupPoints = spreadMarkupFromBand(
        lpSpreadPts,
        pricingMethod,
        minSpreadPoints,
        maxSpreadPoints,
        0,
      );
      const mappedComm = commissionFromMapping(
        {
          pricingMethod: mapping.pricingMethod as NonNullable<GroupPricing['pricingMethod']>,
          minSpreadPoints: mapping.minSpreadPoints,
          maxSpreadPoints: mapping.maxSpreadPoints,
          commissionType: mapping.commissionType as GroupPricing['commissionType'],
          commissionValue: d(mapping.commissionValue),
        },
        { commissionType: 'NONE', commissionValue: 0 },
      );
      commissionType = mappedComm.commissionType;
      commissionValue = mappedComm.commissionValue;
    } else if (!hasMappings) {
      // Legacy path only for groups that have not adopted Symbol Mappings yet.
      const symRule = group.rules.find((r) => r.symbolId === sym.id);
      const classRule = group.rules.find((r) => r.symbolId == null && r.instrumentClass === sym.class);
      markupPoints = symRule?.markupPoints ?? classRule?.markupPoints ?? group.markupPoints;
      const commRule =
        symRule && symRule.commissionType != null
          ? symRule
          : classRule && classRule.commissionType != null
            ? classRule
            : null;
      commissionType = (commRule?.commissionType ?? group.commissionType) as GroupPricing['commissionType'];
      commissionValue = commissionType === 'NONE' ? 0 : d(commRule?.commissionValue ?? group.commissionValue);
    }
    // else: group has mappings but this symbol is unmapped → zero markup/commission

    return {
      markupPoints,
      slippagePoints: group.slippagePoints,
      commissionType,
      commissionValue,
      minSpreadPoints,
      maxSpreadPoints,
      pricingMethod,
      // #2B: execution model — MARKET (fill at market) or INSTANT (honour click / requote).
      executionMode: (group.executionMode as 'MARKET' | 'INSTANT') ?? 'MARKET',
      instantDeviationPoints: group.instantDeviationPoints ?? 0,
    };
  }

  // ── MARKET EXECUTION ────────────────────────────────────────────────────
  private async executeMarket(
    tenantId: string,
    account: NonNullable<Awaited<ReturnType<typeof prisma.account.findFirst>>>,
    sym: NonNullable<SymbolRow>,
    spec: SymbolCalcSpec,
    req: PlaceOrderRequest,
    volume: number,
    // #2A: when a pending LIMIT order fires, its fill must never be worse than
    // the limit the client set. A fast market can carry the raw price past the
    // limit before this pass runs, and the group markup widens it further; this
    // caps the fill at the limit (BUY at or below, SELL at or above). Undefined
    // for market and stop fills, which take the current price with slippage.
    clampWorstPrice?: number,
  ): Promise<ExecutionResult> {
    const accountId = account.id;
    const px =
      req.side === 'BUY'
        ? this.deps.prices.buyPrice(tenantId, req.symbol)
        : this.deps.prices.sellPrice(tenantId, req.symbol);
    if (px == null) throw new BtError(BtErrorCode.NO_PRICE);

    // Live-price guard: refuse to fill on a stale/frozen/late feed. The last tick
    // may be cached (px != null) yet old — never fill an open at a stale price.
    const maxAge = this.deps.maxPriceAgeMs ?? 0;
    if (maxAge > 0) {
      const age = this.deps.prices.ageMs(tenantId, req.symbol);
      if (age == null || age > maxAge) {
        throw new BtError(BtErrorCode.NO_PRICE, 'no live price (feed stale or late) — order not filled');
      }
    }

    // Frozen-book guard.
    //
    // The age check above only proves a tick ARRIVED recently. An upstream that
    // republishes the same quote with a fresh timestamp keeps every symbol
    // looking current while the market behind it has gone — and orders then
    // fill at a price that stopped being real minutes ago. Stillness across the
    // whole book is what separates that from a genuinely quiet instrument.
    const maxStill = this.deps.maxFeedStillMs ?? 0;
    if (maxStill > 0) {
      const still = this.deps.prices.stillMs(tenantId);
      if (still != null && still > maxStill) {
        throw new BtError(
          BtErrorCode.NO_PRICE,
          `feed frozen — no price has moved for ${Math.round(still / 1000)}s`,
        );
      }
    }

    // #2B: the one-click deviation cap and the INSTANT honour/requote decision
    // are made together below, once the disclosed quote (withMarkup) is known —
    // both compare against the price the client actually clicked.

    const stopReads = latency.start('order.exec.reads');
    // account is passed in from placeOrder — no duplicate fetch.
    // Strict: never open risk we cannot value in the account currency.
    const conv = this.quoteToAccountStrict(tenantId, account.currency, spec.quoteCurrency);

    // Trading-group pricing: widen the client's fill by the group spread markup
    // (broker edge) and compute the dealing commission. The raw LP price `px` is
    // used for the A-book cover so the markup stays the broker's profit.
    const pricing = await this.groupPricing(account.groupId, sym, tenantId);
    // Widen the fill by the news spread while active so fills match the widened
    // quote clients see (still the real price, just a wider — disclosed — spread).
    // When a Symbol Mapping prices this instrument, mapping markup is authoritative —
    // do NOT also add Symbol.spreadMarkup (would double-apply vs Spec §3.3).
    const newsMarkup = sym.newsMode ? sym.newsSpreadPoints : 0;
    const mappingOwnsSpread =
      pricing.pricingMethod === 'SPREAD_ONLY' ||
      pricing.pricingMethod === 'SPREAD_AND_COMMISSION' ||
      pricing.pricingMethod === 'COMMISSION_ONLY';
    const symbolBookMarkup = mappingOwnsSpread ? 0 : sym.spreadMarkup;
    const totalMarkup = symbolBookMarkup + pricing.markupPoints + newsMarkup;
    // The disclosed quote the client sees for this side (LP price + all markups).
    const withMarkup = applyMarkup(req.side, px, totalMarkup, sym.digits);

    // #2B: execution model. The INSTANT honour/requote path applies only to a
    // client-submitted MARKET order carrying the price the trader clicked; a
    // pending-order fill (clampWorstPrice != null) or an order with no reference
    // price always fills at market, whatever the group's mode.
    const instantEligible =
      pricing.executionMode === 'INSTANT' &&
      req.type === 'MARKET' &&
      req.price != null &&
      clampWorstPrice == null;

    let fillPrice: number;
    if (instantEligible) {
      // Requote tolerance (points): group override, else the symbol's deviation
      // cap, else 0 — meaning any adverse move requotes (broker-safe default).
      const tol =
        (pricing.instantDeviationPoints && pricing.instantDeviationPoints > 0
          ? pricing.instantDeviationPoints
          : sym.slippagePoints) || 0;
      // Adverse = the current disclosed quote moved against the fill the broker
      // would have to honour: a BUY now higher than clicked, a SELL now lower.
      const bound = slippageBound(req.side, req.price!, tol, sym.digits);
      const adverse = req.side === 'BUY' ? withMarkup > bound : withMarkup < bound;
      if (adverse) {
        throw new BtError(BtErrorCode.REQUOTE, 'price moved — please re-confirm the new price', {
          symbol: sym.symbol,
          side: req.side,
          requestedPrice: req.price,
          newPrice: roundPrice(withMarkup, sym.digits),
          deviationPoints: tol,
        });
      }
      // Within tolerance: honour exactly the clicked price. INSTANT applies no
      // group execution slippage — filling at the quoted price is the guarantee.
      fillPrice = roundPrice(req.price!, sym.digits);
    } else {
      // MARKET: enforce the one-click deviation cap (when the symbol sets one),
      // then fill at market, worsened by the group's execution slippage (anti-HFT)
      // — a BUY fills even higher, a SELL even lower.
      if (req.oneClick && req.price != null && sym.slippagePoints > 0) {
        const bound = slippageBound(req.side, req.price, sym.slippagePoints, sym.digits);
        const worseThanBound = req.side === 'BUY' ? px > bound : px < bound;
        if (worseThanBound) throw new BtError(BtErrorCode.INVALID_PRICE, 'slippage exceeded');
      }
      fillPrice = roundPrice(applyMarkup(req.side, withMarkup, pricing.slippagePoints, sym.digits), sym.digits);
    }
    // #2A: honour the limit on a pending LIMIT fill — never worse than the level
    // the client set. Applied before commission/margin/position all read it, so
    // the clamped price is used consistently downstream.
    if (clampWorstPrice != null) {
      const clamped = req.side === 'BUY'
        ? Math.min(fillPrice, clampWorstPrice)
        : Math.max(fillPrice, clampWorstPrice);
      fillPrice = roundPrice(clamped, sym.digits);
    }
    const commission = dealingCommission(pricing, volume, spec, fillPrice, conv);
    const margin = requiredMargin(volume, spec, fillPrice, account.leverage, conv);

    // Resolve the execution book + LP venue from the Routing Rules layer
    // (most-specific Group × Symbol/Class rule wins), falling back to the
    // existing book hierarchy: symbol.forceBook > rule > account.book >
    // symbol-group default > B.
    // Symbol-group default book + routing rules — both change only on admin
    // action, so cache them (~5s TTL) instead of querying every order.
    let group: { defaultBook: BookType } | null = null;
    if (sym.groupId) {
      const c = this._symGroupBookCache.get(sym.groupId);
      if (c) {
        group = c.v;
      } else {
        group = await prisma.symbolGroup.findUnique({ where: { id: sym.groupId }, select: { defaultBook: true } });
        this._symGroupBookCache.set(sym.groupId, group);
      }
    }
    let routingRules = this._routingCache.get(tenantId)?.v;
    if (!routingRules) {
      routingRules = (await prisma.routingRule.findMany({
        where: { tenantId, enabled: true },
        select: {
          id: true, tradingGroupId: true, symbolId: true, instrumentClass: true,
          book: true, venueMode: true, lpProviderId: true, lpDriver: true, coverageRatio: true, priority: true, createdAt: true,
        },
      })) as RoutingRuleLike[];
      this._routingCache.set(tenantId, routingRules);
    }
    const routing = resolveRouting(routingRules as RoutingRuleLike[], {
      accountGroupId: account.groupId,
      symbolId: sym.id,
      symbolClass: sym.class,
      accountBook: account.book,
      symbolForceBook: sym.forceBook,
      symbolGroupDefaultBook: group?.defaultBook,
    });
    // Demo accounts are ALWAYS warehoused (B-book) and never cover to the LP —
    // virtual money must never touch a real venue, whatever the routing says.
    const book = account.isDemo ? 'B' : routing.book;
    // Partial A-book: cover only `coverageRatio`% of the volume; warehouse the
    // rest. coveredVolume on the position tracks the A-book allocation.
    const coveredVolume =
      book === 'A' ? roundLots((volume * routing.coverageRatio) / 100, d(sym.lotStep)) : 0;

    // Fast-fail free-margin check (authoritative re-check is inside the TX with
    // a row lock so concurrent opens / withdrawals cannot double-spend margin).
    const agg = await this.aggregatesFor(tenantId, accountId);
    if (agg.freeMargin < margin) throw new BtError(BtErrorCode.INSUFFICIENT_MARGIN);
    stopReads();

    const stopTx = latency.start('order.exec.tx');
    const result = await prisma.$transaction(async (tx) => {
      // Serialize money-affecting opens on this account.
      await tx.$queryRaw`SELECT id FROM accounts WHERE id = ${accountId} FOR UPDATE`;
      const locked = await tx.account.findUniqueOrThrow({ where: { id: accountId } });
      if (locked.status === 'TRADING_DISABLED' || locked.status === 'READ_ONLY') {
        throw new BtError(BtErrorCode.TRADING_DISABLED);
      }
      const views = await this.openViewsTx(tx, tenantId, accountId, locked.currency);
      const live = computeAggregates(d(locked.balance), d(locked.credit), views);
      if (live.freeMargin < margin) {
        throw new BtError(
          BtErrorCode.INSUFFICIENT_MARGIN,
          `insufficient free margin: need ${margin}, available ${live.freeMargin}`,
        );
      }

      const position = await tx.position.create({
        data: {
          tenantId,
          accountId,
          symbolId: sym.id,
          side: req.side,
          status: 'OPEN',
          book,
          volume,
          coveredVolume,
          openPrice: fillPrice,
          slPrice: req.slPrice ?? null,
          tpPrice: req.tpPrice ?? null,
          marginUsed: margin,
          commission,
          comment: req.comment,
        },
      });
      const order = await tx.order.create({
        data: {
          tenantId,
          accountId,
          symbolId: sym.id,
          side: req.side,
          type: 'MARKET',
          status: 'FILLED',
          book,
          volume,
          filledVolume: volume,
          // Requested = the quote the client clicked (one-click) or the market at
          // the instant of request; executed = fillPrice. Gap = slippage.
          requestedPrice: req.price ?? px,
          avgFillPrice: fillPrice,
          slPrice: req.slPrice ?? null,
          tpPrice: req.tpPrice ?? null,
          slippagePoints: sym.slippagePoints,
          positionId: position.id,
          source: req.source ?? 'api',
          filledAt: new Date(),
          clientOrderId: req.clientOrderId ?? null,
        },
      });
      await tx.deal.create({
        data: {
          tenantId,
          accountId,
          positionId: position.id,
          symbolId: sym.id,
          type: 'OPEN',
          side: req.side,
          volume,
          price: fillPrice,
          balanceAfter: locked.balance,
          comment: req.comment,
        },
      });
      return { position, order };
    });
    stopTx();

    // Partial A-book: cover only the allocated portion (coveredVolume) to the
    // LP. Non-blocking for the client — the fill already stands; the cover keeps
    // the broker flat on the covered lots and warehouses the rest.
    if (book === 'A' && coveredVolume > 0) {
      // Cover at the RAW LP price (px), not the marked-up client fill — the
      // markup difference is the broker's A-book spread profit.
      // Pricing spread at order time (for TCA): ask - bid on this symbol.
      const aPx = this.deps.prices.buyPrice(tenantId, req.symbol);
      const bPx = this.deps.prices.sellPrice(tenantId, req.symbol);
      const quotedSpread = aPx != null && bPx != null ? aPx - bPx : null;
      const stopCover = latency.start('order.exec.cover');
      await this.coverOpen(
        tenantId, result.position.id, accountId, sym, req.side, coveredVolume, px, routing, quotedSpread,
      ).catch(async (e) => {
        // coverOpen handles its own *expected* failures (venue disabled, LP
        // reject) by marking the hedge REJECTED and alerting. Reaching here
        // means something unexpected threw — e.g. the DB refused the hedgeOrder
        // insert — so there is no hedge row and nothing else will alert. Do not
        // leave that silent: the position is live and uncovered.
        await this.releaseCover(result.position.id, coveredVolume);
        this.deps.emit?.({ kind: 'HEDGE_UNCOVERED', tenantId, positionId: result.position.id });
        await this.deps.crmOutbox?.(tenantId, 'hedge.uncovered', {
          positionId: result.position.id,
          reason: `cover threw: ${(e as Error)?.message ?? 'unknown'}`,
        });
      });
      stopCover();
    }

    const stopRecompute = latency.start('order.exec.recompute');
    const snapshot = await this.recomputeAccount(tenantId, accountId);
    stopRecompute();
    await this.syncBook(result.position.id);
    this.deps.emit?.({ kind: 'POSITION_UPDATE', tenantId, positionId: result.position.id, accountId });
    this.deps.emit?.({ kind: 'ACCOUNT_UPDATE', tenantId, account: snapshot });
    await this.deps.crmOutbox?.(tenantId, 'account.snapshot', {
      login: snapshot.login,
      balance: snapshot.balance,
      credit: snapshot.credit,
      equity: snapshot.equity,
      margin: snapshot.margin,
      freeMargin: snapshot.freeMargin,
      marginLevel: snapshot.marginLevel,
      floatingPL: snapshot.floatingPL,
      positionId: result.position.id,
      reason: 'position.opened',
    });
    await this.deps.crmOutbox?.(tenantId, 'position.opened', {
      login: snapshot.login,
      positionId: result.position.id,
    });

    return {
      accepted: true,
      orderId: result.order.id,
      positionId: result.position.id,
      status: 'FILLED',
      fillPrice,
      filledVolume: volume,
      account: snapshot,
    };
  }

  // ── A-BOOK COVER (STP) ────────────────────────────────────────────────────
  /**
   * Resolve the execution venue for an A-book cover from the routing decision:
   * a FIXED rule provider, the BEST_PRICE active source, the rule's legacy
   * driver, or the tenant default venue. Returns the venue's config + a stable
   * routing key, falling back to MOCK when nothing is configured.
   */
  private async resolveVenue(
    tenantId: string,
    symbol: string,
    routing: RoutingResolution,
  ): Promise<{ providerId: string | null; driver: LpExecDriver; enabled: boolean; venueKey: string }> {
    const sel = {
      lpProviderId: true, driver: true, enabled: true,
    } as const;

    let providerId: string | null = null;
    if (routing.venueMode === 'BEST_PRICE') {
      const code = (await this.deps.activeSource?.(tenantId, symbol)) ?? null;
      if (code) {
        const prov = await prisma.liquidityProvider.findFirst({
          where: { tenantId, code }, select: { id: true },
        });
        providerId = prov?.id ?? null;
      }
    } else {
      providerId = routing.lpProviderId ?? null;
    }

    let cfg = providerId
      ? await prisma.lpExecutionConfig.findUnique({ where: { lpProviderId: providerId }, select: sel })
      : null;

    // Fall back: rule's legacy driver, then the tenant default enabled venue.
    if (!cfg && routing.lpDriver) {
      cfg = await prisma.lpExecutionConfig.findFirst({
        where: { tenantId, lpProviderId: null, driver: routing.lpDriver }, select: sel,
      });
    }
    if (!cfg) {
      cfg = await prisma.lpExecutionConfig.findFirst({
        where: { tenantId, enabled: true },
        orderBy: [{ isDefault: 'desc' }, { createdAt: 'asc' }],
        select: sel,
      });
    }

    providerId = cfg?.lpProviderId ?? providerId;
    const driver = cfg?.driver ?? 'MOCK';
    return { providerId, driver, enabled: cfg?.enabled ?? false, venueKey: venueKeyFor(tenantId, providerId, driver) };
  }

  // ── A-BOOK COVER (STP) ────────────────────────────────────────────────────
  /** Route a 1:1 cover order to the LP for an A-book open and record the hedge. */
  /**
   * Hand `volume` lots back from the A-book allocation to the warehouse.
   *
   * `Position.coveredVolume` is written optimistically when the position is
   * created, before the cover is attempted. Nothing used to reduce it when the
   * cover was rejected, so the row claimed lots that no LP position backed —
   * and `autoHedgeSymbol` computes warehoused exposure as
   * `volume - coveredVolume`, so the sweep that exists to catch this saw zero
   * exposure and left the broker carrying the risk. The admin exposure board
   * reads the same field and overstated coverage identically.
   */
  private async releaseCover(positionId: string, volume: number): Promise<void> {
    if (!(volume > 0)) return;
    try {
      await prisma.$executeRaw`
        UPDATE positions
        SET "coveredVolume" = GREATEST(0, "coveredVolume" - ${volume}::numeric)
        WHERE id = ${positionId}::text AND status = 'OPEN'
      `;
    } catch {
      // Best-effort. Callers emit HEDGE_UNCOVERED regardless, which is the
      // operator-facing alert; this only keeps the exposure maths honest.
    }
  }

  private async coverOpen(
    tenantId: string,
    positionId: string,
    accountId: string,
    sym: NonNullable<SymbolRow>,
    side: OrderSide,
    volume: number,
    referencePrice: number,
    routing: RoutingResolution,
    quotedSpread: number | null = null,
  ): Promise<void> {
    const venue = await this.resolveVenue(tenantId, sym.symbol, routing);
    const driver = venue.driver;

    const hedge = await prisma.hedgeOrder.create({
      data: {
        tenantId,
        positionId,
        accountId,
        symbolId: sym.id,
        symbolName: sym.symbol,
        side,
        volume,
        status: 'PENDING',
        driver,
        lpProviderId: venue.providerId,
        quotedSpread,
        requestPrice: referencePrice,
      },
    });

    // MT5 is an ASYNC venue: the engine runs in a Linux container with no MT5
    // access, so it cannot place the cover itself. It leaves the hedge PENDING;
    // the MT5 Manager bridge polls /bridge/hedges/pending, executes the cover
    // via DealerSend, and reports the fill back (which flips PENDING→FILLED).
    if (driver === 'MT5') {
      if (!venue.enabled) {
        await prisma.hedgeOrder.update({
          where: { id: hedge.id },
          data: { status: 'REJECTED', rejectReason: 'MT5 bridge disabled' },
        });
        await this.releaseCover(positionId, volume);
        this.deps.emit?.({ kind: 'HEDGE_UNCOVERED', tenantId, positionId, hedgeId: hedge.id });
        await this.deps.crmOutbox?.(tenantId, 'hedge.uncovered', { positionId, reason: 'mt5-disabled' });
        return;
      }
      // Queued for the bridge; stays PENDING until the bridge confirms.
      this.deps.emit?.({ kind: 'HEDGE_QUEUED', tenantId, positionId, hedgeId: hedge.id });
      return;
    }

    // No enabled bridge → broker is exposed on this A-book flow; alert loudly.
    if (!this.deps.lp || !venue.enabled) {
      await prisma.hedgeOrder.update({
        where: { id: hedge.id },
        data: { status: 'REJECTED', rejectReason: 'no enabled LP bridge' },
      });
      await this.releaseCover(positionId, volume);
      this.deps.emit?.({ kind: 'HEDGE_UNCOVERED', tenantId, positionId, hedgeId: hedge.id });
      await this.deps.crmOutbox?.(tenantId, 'hedge.uncovered', { positionId, reason: 'no-lp' });
      return;
    }

    const res = await this.deps.lp.route(venue.venueKey, {
      positionId,
      symbol: sym.symbol,
      side,
      volume,
      referencePrice,
      digits: sym.digits,
    });

    if (res.accepted) {
      const fill = res.fillPrice ?? referencePrice;
      await prisma.hedgeOrder.update({
        where: { id: hedge.id },
        data: {
          status: 'FILLED',
          fillPrice: fill,
          externalRef: res.externalRef ?? null,
          slippage: fill - referencePrice,
        },
      });
      this.deps.emit?.({ kind: 'HEDGE_FILLED', tenantId, positionId, hedgeId: hedge.id });
    } else {
      await prisma.hedgeOrder.update({
        where: { id: hedge.id },
        data: { status: 'REJECTED', rejectReason: res.rejectReason ?? 'lp rejected' },
      });
      await this.releaseCover(positionId, volume);
      this.deps.emit?.({ kind: 'HEDGE_UNCOVERED', tenantId, positionId, hedgeId: hedge.id });
      await this.deps.crmOutbox?.(tenantId, 'hedge.rejected', {
        positionId,
        reason: res.rejectReason ?? 'lp rejected',
      });
    }
  }

  /**
   * Close `coverToClose` lots of a position's LP cover (proportional partial
   * A-book close). Walks the FILLED cover legs oldest-first, closing whole legs
   * until the remainder is smaller than a leg, then splits that leg: the closed
   * portion becomes a CLOSE_PENDING/CLOSED child (MT5 bridge partial-closes the
   * same ticket; sync venues close at the LP), and the leg keeps the rest open.
   * Pass coverToClose >= total covered to unwind everything (full close).
   */
  private async coverClose(tenantId: string, positionId: string, coverToClose: number, referencePrice: number): Promise<void> {
    if (coverToClose <= 0) return;
    const legs = await prisma.hedgeOrder.findMany({
      where: { tenantId, positionId, status: 'FILLED' },
      orderBy: { openedAt: 'asc' },
    });
    let remaining = coverToClose;
    let closedNow = 0;
    const EPS = 1e-9;

    const closeLeg = async (legId: string, externalRef: string | null, driver: any, lpProviderId: string | null) => {
      if (driver === 'MT5') {
        await prisma.hedgeOrder.update({ where: { id: legId }, data: { status: 'CLOSE_PENDING' } });
        return;
      }
      let closePrice = referencePrice;
      if (this.deps.lp && externalRef) {
        const venueKey = venueKeyFor(tenantId, lpProviderId, driver);
        const r = await this.deps.lp.close(venueKey, externalRef, referencePrice).catch(() => null);
        if (r?.accepted && r.closePrice != null) closePrice = r.closePrice;
      }
      await prisma.hedgeOrder.update({ where: { id: legId }, data: { status: 'CLOSED', closePrice, closedAt: new Date() } });
    };

    for (const h of legs) {
      if (remaining <= EPS) break;
      const legVol = d(h.volume);
      if (legVol <= EPS) continue;
      if (remaining + EPS >= legVol) {
        // Close the whole leg.
        await closeLeg(h.id, h.externalRef, h.driver, h.lpProviderId);
        remaining -= legVol;
        closedNow++;
      } else {
        // Partial: shrink this leg and spin off a child for the closed portion.
        const take = Number(remaining.toFixed(4));
        await prisma.hedgeOrder.update({ where: { id: h.id }, data: { volume: legVol - take } });
        const child = await prisma.hedgeOrder.create({
          data: {
            tenantId, positionId, accountId: h.accountId, symbolId: h.symbolId, symbolName: h.symbolName,
            side: h.side, volume: take, kind: h.kind, driver: h.driver, lpProviderId: h.lpProviderId,
            externalRef: h.externalRef, requestPrice: h.requestPrice, fillPrice: h.fillPrice,
            status: 'FILLED',
          },
        });
        await closeLeg(child.id, h.externalRef, h.driver, h.lpProviderId);
        remaining = 0;
        closedNow++;
      }
    }
    if (closedNow) this.deps.emit?.({ kind: 'HEDGE_CLOSED', tenantId, positionId });
  }

  /**
   * Manually cover MORE of a position (move warehoused B-book lots to A): covers
   * up to `lots` of the uncovered remainder to the LP and bumps coveredVolume.
   * Returns the new covered / warehoused split.
   */
  async coverMore(tenantId: string, positionId: string, lots: number): Promise<{ covered: number; warehoused: number }> {
    const pos = await prisma.position.findFirst({
      where: { id: positionId, tenantId, status: 'OPEN' },
      include: { symbol: true, account: { select: { groupId: true } } },
    });
    if (!pos) throw new BtError(BtErrorCode.POSITION_NOT_FOUND);
    const sym = pos.symbol;
    const openVol = d(pos.volume);
    const covered = d(pos.coveredVolume);
    const warehoused = Math.max(0, openVol - covered);
    const n = roundLots(Math.min(Math.max(0, lots), warehoused), d(sym.lotStep));
    if (n <= 0) return { covered, warehoused };

    // Resolve the A-book venue for this position's group × symbol.
    const grp = sym.groupId
      ? await prisma.symbolGroup.findUnique({ where: { id: sym.groupId }, select: { defaultBook: true } })
      : null;
    const rules = await prisma.routingRule.findMany({
      where: { tenantId, enabled: true },
      select: {
        id: true, tradingGroupId: true, symbolId: true, instrumentClass: true,
        book: true, venueMode: true, lpProviderId: true, lpDriver: true, coverageRatio: true, priority: true, createdAt: true,
      },
    });
    const routing = resolveRouting(rules as RoutingRuleLike[], {
      accountGroupId: pos.account.groupId,
      symbolId: sym.id,
      symbolClass: sym.class,
      accountBook: 'A', // force A so a venue resolves even for a B-book position
      symbolForceBook: null,
      symbolGroupDefaultBook: grp?.defaultBook,
    });
    const px = pos.side === 'BUY'
      ? this.deps.prices.buyPrice(tenantId, sym.symbol)
      : this.deps.prices.sellPrice(tenantId, sym.symbol);

    await this.coverOpen(tenantId, pos.id, pos.accountId, sym, pos.side as OrderSide, n, px ?? d(pos.openPrice), routing, null);
    await prisma.position.update({ where: { id: pos.id }, data: { coveredVolume: covered + n } });
    await this.syncBook(pos.id);
    this.deps.emit?.({ kind: 'POSITION_UPDATE', tenantId, positionId: pos.id, accountId: pos.accountId });
    return { covered: Number((covered + n).toFixed(4)), warehoused: Number((warehoused - n).toFixed(4)) };
  }

  // ── AUTO NET-HEDGE (B-book) ────────────────────────────────────────────────
  /**
   * Sweep every tenant's enabled AutoHedgeRules. For each symbol it computes the
   * broker's net B-book exposure, subtracts what's already hedged on MT5, and —
   * if the unhedged net exceeds the rule's threshold — sends a BROKER_AUTO cover
   * for the excess (either direction, so it also unwinds when exposure falls).
   * Only routes through an enabled MT5 LP config; the bridge executes the cover.
   * Designed to be called on a timer from the trading-engine service.
   */
  async autoHedgeSweep(): Promise<void> {
    const rules = await prisma.autoHedgeRule.findMany({ where: { enabled: true } });
    if (!rules.length) return;
    const byTenant = new Map<string, typeof rules>();
    for (const r of rules) {
      const arr = byTenant.get(r.tenantId) ?? [];
      arr.push(r);
      byTenant.set(r.tenantId, arr);
    }
    for (const [tenantId, tenantRules] of byTenant) {
      // Auto-hedge only routes to an enabled MT5 cover venue (prefer the default).
      const cfg = await prisma.lpExecutionConfig.findFirst({
        where: { tenantId, driver: 'MT5', enabled: true },
        orderBy: [{ isDefault: 'desc' }, { createdAt: 'asc' }],
        select: { lpProviderId: true },
      });
      if (!cfg) continue;
      for (const rule of tenantRules) {
        await this.autoHedgeSymbol(tenantId, rule, cfg.lpProviderId).catch((e) =>
          this.deps.emit?.({ kind: 'AUTOHEDGE_ERROR', tenantId, symbol: rule.symbolName, error: (e as Error).message }),
        );
      }
    }
  }

  private async autoHedgeSymbol(
    tenantId: string,
    rule: { symbolName: string; thresholdLots: any; minClipLots: any; maxClipLots: any },
    lpProviderId: string | null = null,
  ): Promise<void> {
    const sym = await prisma.symbol.findFirst({ where: { tenantId, symbol: rule.symbolName } });
    if (!sym) return;

    // Don't stack hedges: wait for any in-flight broker hedge on this symbol to settle.
    const inflight = await prisma.hedgeOrder.count({
      where: {
        tenantId,
        symbolName: rule.symbolName,
        kind: { in: ['BROKER_AUTO', 'BROKER_MANUAL'] },
        status: { in: ['PENDING', 'CLOSE_PENDING'] },
      },
    });
    if (inflight > 0) return;

    // Net warehoused exposure (signed lots): the UNCOVERED part of every open
    // position (full B-book volume + the uncovered remainder of partial-A). + = net long.
    const positions = await prisma.position.findMany({
      // Exclude demo accounts: their virtual flow must never drive a real hedge.
      where: { tenantId, symbolId: sym.id, status: 'OPEN', account: { isDemo: false } },
      select: { side: true, volume: true, coveredVolume: true },
    });
    let clientNet = 0;
    for (const p of positions) {
      const warehoused = Math.max(0, d(p.volume) - d(p.coveredVolume));
      clientNet += (p.side === 'BUY' ? 1 : -1) * warehoused;
    }

    // What we've already covered on MT5 (signed): broker hedges that are live.
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

    // To flatten, the broker holds the SAME direction as clients' net on MT5.
    // Leave up to `thresholdLots` of net unhedged.
    const threshold = Math.abs(d(rule.thresholdLots));
    const sign = clientNet >= 0 ? 1 : -1;
    const desired = Math.abs(clientNet) <= threshold ? 0 : sign * (Math.abs(clientNet) - threshold);
    let delta = desired - hedged;

    const lotStep = d(sym.lotStep) || 0.01;
    const minClip = Math.max(d(rule.minClipLots) || lotStep, lotStep);
    // Snap to lot step.
    let volume = Math.round(Math.abs(delta) / lotStep) * lotStep;
    if (volume < minClip) return;
    const maxClip = rule.maxClipLots == null ? null : Math.abs(d(rule.maxClipLots));
    if (maxClip && volume > maxClip) volume = maxClip;
    volume = Number(volume.toFixed(4));
    if (volume <= 0) return;

    const side: OrderSide = delta > 0 ? 'BUY' : 'SELL';
    const bid = this.deps.prices.sellPrice(tenantId, sym.symbol);
    const ask = this.deps.prices.buyPrice(tenantId, sym.symbol);
    const mid = bid != null && ask != null ? (bid + ask) / 2 : (bid ?? ask ?? null);

    const hedge = await prisma.hedgeOrder.create({
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
    this.deps.emit?.({ kind: 'AUTOHEDGE_SENT', tenantId, symbol: sym.symbol, side, volume, hedgeId: hedge.id });
  }

  // ── PENDING ORDERS ────────────────────────────────────────────────────────

  /** Map a persisted order (+ symbol name) to the WS/REST OrderDTO shape. */
  private orderDto(
    order: {
      id: string;
      accountId: string;
      side: string;
      type: string;
      status: string;
      volume: Prisma.Decimal | number;
      filledVolume: Prisma.Decimal | number;
      price: Prisma.Decimal | number | null;
      stopPrice: Prisma.Decimal | number | null;
      slPrice: Prisma.Decimal | number | null;
      tpPrice: Prisma.Decimal | number | null;
      avgFillPrice?: Prisma.Decimal | number | null;
      rejectReason?: string | null;
      positionId?: string | null;
      createdAt: Date;
      filledAt?: Date | null;
      triggeredAt?: Date | null;
      clientOrderId?: string | null;
    },
    symbol: string,
  ) {
    return {
      id: order.id,
      accountId: order.accountId,
      symbol,
      side: order.side as OrderSide,
      type: order.type as OrderType,
      status: order.status as ExecutionResult['status'],
      volume: d(order.volume),
      filledVolume: d(order.filledVolume),
      price: order.price != null ? d(order.price) : undefined,
      stopPrice: order.stopPrice != null ? d(order.stopPrice) : undefined,
      slPrice: order.slPrice != null ? d(order.slPrice) : undefined,
      tpPrice: order.tpPrice != null ? d(order.tpPrice) : undefined,
      avgFillPrice: order.avgFillPrice != null ? d(order.avgFillPrice) : undefined,
      rejectReason: order.rejectReason ?? undefined,
      positionId: order.positionId ?? undefined,
      createdAt: order.createdAt.toISOString(),
      filledAt: order.filledAt ? order.filledAt.toISOString() : undefined,
      triggeredAt: order.triggeredAt ? order.triggeredAt.toISOString() : undefined,
      clientOrderId: order.clientOrderId ?? undefined,
    };
  }

  /**
   * MT5 pending rules vs live Bid/Ask + stopsLevel (points × tick size).
   * Buy Limit below Ask, Buy Stop above Ask, Sell Limit above Bid, Sell Stop below Bid.
   */
  private assertPendingTrigger(
    tenantId: string,
    symbol: string,
    type: OrderType | string,
    side: OrderSide | string,
    triggerPrice: number,
    digits: number,
    stopsLevel: number,
  ): void {
    if (!(triggerPrice > 0)) throw new BtError(BtErrorCode.INVALID_PRICE, 'entry price must be positive');
    const bid = this.deps.prices.sellPrice(tenantId, symbol);
    const ask = this.deps.prices.buyPrice(tenantId, symbol);
    if (bid == null || ask == null) throw new BtError(BtErrorCode.NO_PRICE, 'no live price for pending order');

    const t = String(type).toUpperCase();
    const s = String(side).toUpperCase();
    const isBuy = t === 'BUY_LIMIT' || t === 'BUY_STOP' || (s === 'BUY' && (t === 'LIMIT' || t === 'STOP' || t === 'STOP_LIMIT'));
    const isSell = t === 'SELL_LIMIT' || t === 'SELL_STOP' || (s === 'SELL' && (t === 'LIMIT' || t === 'STOP' || t === 'STOP_LIMIT'));

    if (t === 'BUY_LIMIT' || (t === 'LIMIT' && isBuy)) {
      if (!(triggerPrice < ask)) {
        throw new BtError(BtErrorCode.INVALID_PRICE, `Buy Limit must be below Ask (${ask})`);
      }
    } else if (t === 'BUY_STOP' || (t === 'STOP' && isBuy) || (t === 'STOP_LIMIT' && isBuy)) {
      if (!(triggerPrice > ask)) {
        throw new BtError(BtErrorCode.INVALID_PRICE, `Buy Stop must be above Ask (${ask})`);
      }
    } else if (t === 'SELL_LIMIT' || (t === 'LIMIT' && isSell)) {
      if (!(triggerPrice > bid)) {
        throw new BtError(BtErrorCode.INVALID_PRICE, `Sell Limit must be above Bid (${bid})`);
      }
    } else if (t === 'SELL_STOP' || (t === 'STOP' && isSell) || (t === 'STOP_LIMIT' && isSell)) {
      if (!(triggerPrice < bid)) {
        throw new BtError(BtErrorCode.INVALID_PRICE, `Sell Stop must be below Bid (${bid})`);
      }
    }

    if (stopsLevel > 0) {
      const market = isBuy ? ask : bid;
      const minDist = stopsLevel * pointSize(digits);
      if (Math.abs(triggerPrice - market) < minDist) {
        throw new BtError(
          BtErrorCode.STOPS_TOO_CLOSE,
          `entry too close to market (min ${stopsLevel} points)`,
        );
      }
    }
  }

  private async placePending(
    tenantId: string,
    account: NonNullable<Awaited<ReturnType<typeof prisma.account.findFirst>>>,
    sym: NonNullable<SymbolRow>,
    spec: SymbolCalcSpec,
    req: PlaceOrderRequest,
    volume: number,
  ): Promise<ExecutionResult> {
    const accountId = account.id;
    const triggerPrice = req.stopPrice ?? req.price;
    if (triggerPrice == null) throw new BtError(BtErrorCode.INVALID_PRICE, 'pending order needs price');

    this.assertPendingTrigger(
      tenantId,
      req.symbol,
      req.type,
      req.side,
      triggerPrice,
      sym.digits,
      sym.stopsLevel,
    );

    const tif = (req.timeInForce ?? 'GTC').toUpperCase();
    let expiresAt = req.expiresAt ? new Date(req.expiresAt) : null;
    if (tif === 'DAY' && !expiresAt) {
      expiresAt = sessionClosesAt(
        sym.tradingSessions as unknown as SessionWindow[] | null,
        sym.class,
        new Date(),
      );
    }

    // Pre-check free margin at the pending trigger price so clients cannot park
    // orders they could never afford. Authoritative check still runs at fill.
    // Strict: reject at placement rather than mis-margin the order at trigger.
    const conv = this.quoteToAccountStrict(tenantId, account.currency, spec.quoteCurrency);
    const estMargin = requiredMargin(volume, spec, triggerPrice, account.leverage, conv);
    const agg = await this.aggregatesFor(tenantId, accountId);
    if (agg.freeMargin < estMargin) {
      throw new BtError(
        BtErrorCode.INSUFFICIENT_MARGIN,
        `insufficient free margin for pending order: need ~${estMargin}, available ${agg.freeMargin}`,
      );
    }

    const order = await prisma.order.create({
      data: {
        tenantId,
        accountId,
        symbolId: sym.id,
        side: req.side,
        type: req.type as OrderType,
        status: 'PENDING',
        timeInForce: req.timeInForce ?? 'GTC',
        volume,
        price: req.price ?? null,
        stopPrice: req.stopPrice ?? null,
        requestedPrice: req.price ?? req.stopPrice ?? null,
        slPrice: req.slPrice ?? null,
        tpPrice: req.tpPrice ?? null,
        expiresAt,
        slippagePoints: sym.slippagePoints,
        comment: req.comment,
        source: req.source ?? 'api',
        clientOrderId: req.clientOrderId ?? null,
        stopTriggered: false,
      },
    }).catch(async (e: { code?: string }) => {
      if (e?.code === 'P2002' && req.clientOrderId) {
        const dup = await prisma.order.findFirst({
          where: { tenantId, accountId, clientOrderId: req.clientOrderId },
        });
        if (dup) return dup;
      }
      throw e;
    });
    if (req.clientOrderId && order.clientOrderId === req.clientOrderId && order.status !== 'PENDING') {
      return this.existingToResult(order);
    }

    const bid = this.deps.prices.sellPrice(tenantId, req.symbol);
    const ask = this.deps.prices.buyPrice(tenantId, req.symbol);
    const action =
      bid != null && ask != null
        ? pendingFires({
            type: req.type,
            side: req.side,
            bid,
            ask,
            trigger: triggerPrice,
            stopPrice: req.stopPrice,
            limitPrice: req.price,
            stopTriggered: false,
          })
        : 'none';

    if ((tif === 'IOC' || tif === 'FOK') && action !== 'fill') {
      const cancelled = await prisma.order.update({
        where: { id: order.id },
        data: { status: tif === 'FOK' ? 'REJECTED' : 'CANCELLED', rejectReason: 'IOC/FOK not immediately marketable' },
      });
      counters.inc('order.ioc_cancelled');
      this.deps.emit?.({ kind: 'ORDER_UPDATE', tenantId, order: this.orderDto(cancelled, req.symbol) });
      return { accepted: false, orderId: cancelled.id, status: cancelled.status, reason: 'not immediately marketable' };
    }

    this.pendings.upsert(this.toPendingRow(order));
    this.deps.emit?.({ kind: 'ORDER_UPDATE', tenantId, order: this.orderDto(order, req.symbol) });
    return { accepted: true, orderId: order.id, status: 'PENDING' };
  }

  // ── CLOSE (full / partial) ──────────────────────────────────────────────
  async closePosition(
    tenantId: string,
    positionId: string,
    closeVolume?: number,
    opts?: {
      floorBalanceAtZero?: boolean;
      closePriceOverride?: number;
      /**
       * The SL/TP price that triggered this close.
       *
       * Caps the fill at that level so a stop can never fill BETTER than where
       * it was set. Without it a close prices at whatever the market is when
       * the engine gets round to acting, so a stop detected late - a slow tick
       * pass, a backed-up drain - fills wherever price has since travelled.
       * That is how a stop-loss ends up closing when the market comes back to
       * the entry line instead of at the stop.
       *
       * Deliberately NOT closePriceOverride: that is the dealer path and skips
       * the group markup and anti-HFT slippage. A protective stop must still be
       * slipped like any other close, so this clamps the market price and lets
       * the normal pricing run on top.
       */
      protectiveLevel?: number;
    },
  ): Promise<ExecutionResult> {
    const pos = await prisma.position.findFirst({
      where: { id: positionId, tenantId, status: 'OPEN' },
      include: { symbol: true, account: true },
    });
    if (!pos) throw new BtError(BtErrorCode.POSITION_NOT_FOUND);
    const sym = pos.symbol;
    const spec = specOf(sym);

    // A dealer (admin) close can override the fill price for slippage /
    // compensation; otherwise close at market — a BUY hits bid, a SELL hits ask.
    const override = opts?.closePriceOverride;
    const px = (override != null && override > 0)
      ? override
      : (pos.side === 'BUY'
          ? this.deps.prices.sellPrice(tenantId, sym.symbol)
          : this.deps.prices.buyPrice(tenantId, sym.symbol));
    if (px == null) throw new BtError(BtErrorCode.NO_PRICE);
    // Clamp to the stop level, in the direction that can only hurt the client.
    // A BUY exits on the bid, so it may fill AT or BELOW its stop but never
    // above it; a SELL exits on the ask and may fill at or above. A gap through
    // the level therefore still fills at the gapped market price - the client
    // wears the gap, which is correct - while a late detection after price has
    // recovered fills at the level rather than the recovered price.
    let px2 = px;
    const lvl = opts?.protectiveLevel;
    if (override == null && lvl != null && lvl > 0) {
      px2 = pos.side === 'BUY' ? Math.min(lvl, px) : Math.max(lvl, px);
    }
    // Group execution slippage (anti-HFT) worsens the close/SL/TP/stop-out fill
    // against the client. A dealer price override is exact — never slipped. The
    // closing trade is the opposite side of the position, so applyMarkup with
    // that side moves the price the adverse way (BUY position → sell lower;
    // SELL position → buy higher).
    let closePx = px2;
    if (override == null) {
      const pricing = await this.groupPricing(pos.account.groupId, sym, tenantId);
      // Apply mapping/group spread markup + anti-HFT slippage so close matches
      // the client-facing quote (BUY hits worsened bid, SELL hits worsened ask).
      const closeSide: OrderSide = pos.side === 'BUY' ? 'SELL' : 'BUY';
      const total = (pricing.markupPoints || 0) + (pricing.slippagePoints || 0);
      if (total !== 0) {
        closePx = applyMarkup(closeSide, px2, total, sym.digits);
      }
    }
    const closePrice = roundPrice(closePx, sym.digits);

    const conv = this.quoteToAccount(tenantId, pos.account.currency, spec.quoteCurrency);

    let vol = 0;
    let partial = false;
    let coverToClose = 0;
    let realized = 0;

    const snapshot = await prisma.$transaction(async (tx) => {
      // Lock account + position so concurrent partial closes cannot over-close
      // or double-realize P/L against the same lots.
      await tx.$queryRaw`SELECT id FROM accounts WHERE id = ${pos.accountId} FOR UPDATE`;
      await tx.$queryRaw`SELECT id FROM positions WHERE id = ${positionId} FOR UPDATE`;
      const fresh = await tx.position.findFirst({
        where: { id: positionId, tenantId, status: 'OPEN' },
      });
      if (!fresh) throw new BtError(BtErrorCode.POSITION_NOT_FOUND);
      const acct = await tx.account.findUniqueOrThrow({ where: { id: pos.accountId } });

      const openVol = d(fresh.volume);
      vol = closeVolume ? normalizeVolume(closeVolume, d(sym.minLot), openVol, d(sym.lotStep)) : openVol;
      if (vol > openVol) vol = openVol;
      if (!(vol > 0)) throw new BtError(BtErrorCode.INVALID_VOLUME, 'close volume must be positive');
      partial = vol < openVol;

      const coveredBefore = d(fresh.coveredVolume);
      coverToClose =
        openVol > 0 ? Math.min(coveredBefore, roundLots((coveredBefore * vol) / openVol, d(sym.lotStep))) : 0;
      const coveredAfter = Number(Math.max(0, coveredBefore - coverToClose).toFixed(4));

      // Swap/commission are realized pro-rata and REMOVED from the remainder
      // below — carrying them forward would re-bill the client on every
      // subsequent close.
      const charges = splitPositionCharges(d(fresh.swap), d(fresh.commission), vol, openVol);

      realized =
        positionProfit(fresh.side as OrderSide, vol, d(fresh.openPrice), closePrice, spec, conv) +
        charges.realizedSwap +
        charges.realizedCommission;

      // Negative Balance Protection: a stop-out-forced close (price gapped
      // through the client, e.g. a weekend/news spike) never charges more loss
      // than the account actually has — clip so balance floors at exactly 0.
      // Voluntary client closes are NEVER clipped here (opts is only set by
      // checkStopOut); a client always sees the true fill/loss on their own action.
      if (opts?.floorBalanceAtZero && d(acct.balance) + realized < 0) {
        realized = -d(acct.balance);
      }
      const newBalance = d(acct.balance) + realized;

      await tx.deal.create({
        data: {
          tenantId,
          accountId: pos.accountId,
          positionId: fresh.id,
          symbolId: sym.id,
          type: partial ? 'PARTIAL_CLOSE' : 'CLOSE',
          side: fresh.side,
          volume: vol,
          price: closePrice,
          profit: realized,
          balanceAfter: newBalance,
        },
      });

      if (partial) {
        const remaining = openVol - vol;
        const newMargin = requiredMargin(remaining, spec, d(fresh.openPrice), acct.leverage, conv);
        await tx.position.update({
          where: { id: fresh.id },
          data: {
            volume: remaining,
            marginUsed: newMargin,
            coveredVolume: coveredAfter,
            swap: charges.remainingSwap,
            commission: charges.remainingCommission,
          },
        });
      } else {
        await tx.position.update({
          where: { id: fresh.id },
          data: {
            status: 'CLOSED',
            volume: 0,
            coveredVolume: 0,
            closePrice,
            profit: realized,
            marginUsed: 0,
            closedAt: new Date(),
          },
        });
      }
      await tx.account.update({ where: { id: acct.id }, data: { balance: newBalance } });
      return acct.id;
    });

    // A-book: unwind the proportional slice of the LP cover (works for partial
    // and full closes of partial-A positions).
    if (coverToClose > 0) {
      await this.coverClose(tenantId, pos.id, coverToClose, closePrice).catch(() => undefined);
    }

    await this.syncBook(pos.id);
    const snap = await this.recomputeAccount(tenantId, pos.accountId);
    this.deps.emit?.({ kind: 'POSITION_UPDATE', tenantId, positionId: pos.id, accountId: pos.accountId });
    this.deps.emit?.({ kind: 'ACCOUNT_UPDATE', tenantId, account: snap });
    await this.deps.crmOutbox?.(tenantId, 'account.snapshot', {
      login: snap.login,
      balance: snap.balance,
      credit: snap.credit,
      equity: snap.equity,
      margin: snap.margin,
      freeMargin: snap.freeMargin,
      marginLevel: snap.marginLevel,
      floatingPL: snap.floatingPL,
      positionId: pos.id,
      profit: realized,
      reason: 'position.closed',
    });
    await this.deps.crmOutbox?.(tenantId, 'position.closed', {
      login: snap.login,
      positionId: pos.id,
      profit: realized,
    });
    void snapshot;

    return {
      accepted: true,
      positionId: pos.id,
      status: 'FILLED',
      fillPrice: closePrice,
      filledVolume: vol,
      account: snap,
    };
  }

  async closeAll(tenantId: string, accountId: string): Promise<number> {
    const open = await prisma.position.findMany({
      where: { tenantId, accountId, status: 'OPEN' },
      select: { id: true },
    });
    let closed = 0;
    for (const p of open) {
      try {
        await this.closePosition(tenantId, p.id);
        closed++;
      } catch {
        /* skip positions with no price; retried next call */
      }
    }
    return closed;
  }

  // ── MODIFY SL/TP ──────────────────────────────────────────────────────────
  async modifyPosition(
    tenantId: string,
    positionId: string,
    sl?: number | null,
    tp?: number | null,
  ): Promise<void> {
    const pos = await prisma.position.findFirst({
      where: { id: positionId, tenantId, status: 'OPEN' },
      include: { symbol: true },
    });
    if (!pos) throw new BtError(BtErrorCode.POSITION_NOT_FOUND);

    // Reject stops that are already through the market.
    //
    // This method used to write whatever it was handed. A take-profit placed
    // on the wrong side of the price is satisfied the moment it lands, so the
    // very next tick closes the position - the client asks to protect a trade
    // and the trade ends instead. Enforced here rather than in the apps because
    // this is the only path every client shares, and it is real money either
    // way.
    //
    // Compared against the price the position CLOSES on: the bid for a long,
    // the ask for a short - the same side the trigger itself uses, so a level
    // that passes this check cannot fire immediately.
    const isBuy = pos.side === 'BUY';
    const close = isBuy
      ? this.deps.prices.sellPrice(tenantId, pos.symbol.symbol)
      : this.deps.prices.buyPrice(tenantId, pos.symbol.symbol);
    if (close != null) {
      const px = (n: number) => n.toFixed(pos.symbol.digits);
      if (sl != null && (isBuy ? sl >= close : sl <= close)) {
        throw new BtError(
          BtErrorCode.INVALID_PRICE,
          `stop loss must be ${isBuy ? 'below' : 'above'} ${px(close)}`,
        );
      }
      if (tp != null && (isBuy ? tp <= close : tp >= close)) {
        throw new BtError(
          BtErrorCode.INVALID_PRICE,
          `take profit must be ${isBuy ? 'above' : 'below'} ${px(close)}`,
        );
      }
    }

    await prisma.position.update({
      where: { id: pos.id },
      data: { slPrice: sl === undefined ? pos.slPrice : sl, tpPrice: tp === undefined ? pos.tpPrice : tp },
    });
    await this.syncBook(pos.id);
    this.deps.emit?.({ kind: 'POSITION_UPDATE', tenantId, positionId: pos.id, accountId: pos.accountId });
  }

  // ── DEALER: EDIT OPEN PRICE (slippage / compensation, admin-only) ──────────
  /** Retroactively set an OPEN position's entry price. This is a dealer
   *  intervention (MT5-style) to compensate the client for slippage — it
   *  changes the position's floating P/L and required margin, then re-aggregates
   *  the account. Caller MUST enforce admin authorization + audit logging. */
  async setPositionOpenPrice(tenantId: string, positionId: string, newOpenPrice: number): Promise<void> {
    if (!(newOpenPrice > 0)) throw new BtError(BtErrorCode.INVALID_PRICE, 'open price must be positive');
    const pos = await prisma.position.findFirst({
      where: { id: positionId, tenantId, status: 'OPEN' },
      include: { symbol: true, account: true },
    });
    if (!pos) throw new BtError(BtErrorCode.POSITION_NOT_FOUND);
    const spec = specOf(pos.symbol);
    const conv = this.quoteToAccount(tenantId, pos.account.currency, spec.quoteCurrency);
    const open = roundPrice(newOpenPrice, pos.symbol.digits);
    const newMargin = requiredMargin(d(pos.volume), spec, open, pos.account.leverage, conv);
    await prisma.position.update({ where: { id: pos.id }, data: { openPrice: open, marginUsed: newMargin } });
    await this.syncBook(pos.id);
    const snap = await this.recomputeAccount(tenantId, pos.accountId);
    this.deps.emit?.({ kind: 'POSITION_UPDATE', tenantId, positionId: pos.id, accountId: pos.accountId });
    this.deps.emit?.({ kind: 'ACCOUNT_UPDATE', tenantId, account: snap });
  }

  async cancelOrder(tenantId: string, orderId: string): Promise<void> {
    const order = await prisma.order.findFirst({
      where: { id: orderId, tenantId, status: 'PENDING' },
      include: { symbol: { select: { symbol: true } } },
    });
    if (!order) throw new BtError(BtErrorCode.ORDER_NOT_FOUND);
    const updated = await prisma.order.update({
      where: { id: order.id },
      data: { status: 'CANCELLED' },
    });
    this.pendings.remove(order.id);
    this.deps.emit?.({
      kind: 'ORDER_UPDATE',
      tenantId,
      order: this.orderDto(updated, order.symbol.symbol),
    });
  }

  /** Modify a pending order's entry price and/or SL/TP (engine is source of truth). */
  async modifyOrder(
    tenantId: string,
    orderId: string,
    patch: { price?: number | null; stopPrice?: number | null; slPrice?: number | null; tpPrice?: number | null },
  ): Promise<void> {
    const order = await prisma.order.findFirst({
      where: { id: orderId, tenantId, status: 'PENDING' },
      include: { symbol: true },
    });
    if (!order) throw new BtError(BtErrorCode.ORDER_NOT_FOUND);
    const sym = order.symbol;

    const nextPrice = patch.price === undefined ? (order.price != null ? d(order.price) : null) : patch.price;
    const nextStop =
      patch.stopPrice === undefined ? (order.stopPrice != null ? d(order.stopPrice) : null) : patch.stopPrice;
    const trigger = nextStop ?? nextPrice;
    if (trigger == null) throw new BtError(BtErrorCode.INVALID_PRICE, 'pending order needs price');

    this.assertPendingTrigger(
      tenantId,
      sym.symbol,
      order.type,
      order.side,
      trigger,
      sym.digits,
      sym.stopsLevel,
    );

    const updated = await prisma.order.update({
      where: { id: order.id },
      data: {
        price: patch.price === undefined ? order.price : patch.price,
        stopPrice: patch.stopPrice === undefined ? order.stopPrice : patch.stopPrice,
        requestedPrice: trigger,
        slPrice: patch.slPrice === undefined ? order.slPrice : patch.slPrice,
        tpPrice: patch.tpPrice === undefined ? order.tpPrice : patch.tpPrice,
      },
    });
    this.pendings.upsert(this.toPendingRow(updated));
    this.deps.emit?.({
      kind: 'ORDER_UPDATE',
      tenantId,
      order: this.orderDto(updated, sym.symbol),
    });
  }

  // Throttle live broadcasts per tenant:symbol so 4 ticks/sec don't storm the DB/WS.
  private readonly liveThrottle = new Map<string, number>();

  // Short-TTL cache for the tick-path symbol lookup. Each onTick pass resolved
  // the same row four times, so a busy feed multiplied DB load until the Prisma
  // pool timed out and *every* tick-driven check (pending triggers, SL/TP,
  // stop-out) silently stopped working. Only the tick paths read this — order
  // placement still reads the row straight from the DB, since it needs exact
  // current specs. All tick callers use `id` only, which never changes.
  private readonly symbolRowCache = new Map<string, { row: SymbolRow; at: number }>();

  private async tickSymbol(tenantId: string, symbol: string): Promise<SymbolRow> {
    const key = `${tenantId}\u0000${symbol}`;
    const now = Date.now();
    const hit = this.symbolRowCache.get(key);
    if (hit && now - hit.at < SYMBOL_CACHE_TTL_MS) return hit.row;
    const row = await prisma.symbol.findFirst({ where: { tenantId, symbol } });
    this.symbolRowCache.set(key, { row, at: now });
    return row;
  }

  // ── TICK PROCESSING: pending triggers, SL/TP, stop-out, live P/L ────────────
  /** Open positions held in memory; see position-book.ts for the contract. */
  readonly book = new PositionBook();
  /** Working pending orders in RAM; see pending-book.ts. */
  readonly pendings = new PendingBook();

  /**
   * Fill the book from the database. Must complete before the first tick pass:
   * an unhydrated book reports every symbol as having no open positions, which
   * would silently skip every stop-loss until it filled.
   */
  async hydrateBook(): Promise<number> {
    const rows = await this.readOpenRows();
    this.book.load(rows);
    this.pendings.load(await this.readPendingRows());
    return rows.length;
  }

  /** Reload working orders from Postgres (gateway places them in another process). */
  async refreshPendings(): Promise<number> {
    const rows = await this.readPendingRows();
    this.pendings.load(rows);
    return rows.length;
  }

  async reconcileBook(): Promise<{ missing: number; stale: number; extra: number }> {
    const pos = this.book.reconcile(await this.readOpenRows());
    const pen = this.pendings.reconcile(await this.readPendingRows());
    return {
      missing: pos.missing + pen.missing,
      stale: pos.stale + pen.stale,
      extra: pos.extra + pen.extra,
    };
  }

  private toPendingRow(o: {
    id: string;
    tenantId: string;
    accountId: string;
    symbolId: string;
    side: string;
    type: string;
    status: string;
    volume: Prisma.Decimal | number;
    price: Prisma.Decimal | number | null;
    stopPrice: Prisma.Decimal | number | null;
    slPrice: Prisma.Decimal | number | null;
    tpPrice: Prisma.Decimal | number | null;
    expiresAt: Date | null;
    updatedAt: Date;
    stopTriggered?: boolean;
  }): PendingRow {
    return {
      id: o.id,
      tenantId: o.tenantId,
      accountId: o.accountId,
      symbolId: o.symbolId,
      side: o.side,
      type: o.type,
      status: o.status,
      volume: d(o.volume),
      price: o.price != null ? d(o.price) : null,
      stopPrice: o.stopPrice != null ? d(o.stopPrice) : null,
      slPrice: o.slPrice != null ? d(o.slPrice) : null,
      tpPrice: o.tpPrice != null ? d(o.tpPrice) : null,
      expiresAt: o.expiresAt,
      updatedAt: o.updatedAt,
      stopTriggered: !!o.stopTriggered,
    };
  }

  private async readPendingRows(): Promise<PendingRow[]> {
    const rows = await prisma.order.findMany({
      where: {
        OR: [
          { status: 'PENDING' },
          { status: 'PARTIAL', positionId: null, filledVolume: 0 },
        ],
      },
    });
    return rows.map((r) => this.toPendingRow(r));
  }

  private async readOpenRows(): Promise<BookRow[]> {
    const rows = await prisma.position.findMany({
      where: { status: 'OPEN' },
      include: { account: { select: { currency: true } } },
    });
    return rows.map((r) => toBookRow(r, r.account.currency));
  }

  /** Refresh one position in the book from the database, after a commit. */
  private async syncBook(positionId: string): Promise<void> {
    try {
      const row = await prisma.position.findUnique({
        where: { id: positionId },
        include: { account: { select: { currency: true } } },
      });
      if (row === null || row.status !== 'OPEN') {
        this.book.remove(positionId);
        return;
      }
      this.book.upsert(toBookRow(row, row.account.currency));
    } catch {
      // Never let book maintenance fail the trade that already committed. The
      // periodic reconcile is what makes this safe to swallow.
    }
  }

  async onTick(tenantId: string, symbol: string): Promise<void> {
    // Preserved as the single full pass for integration tests and any external
    // caller; the live engine drives the two halves on separate cadences below.
    await this.onTickFast(tenantId, symbol);
    await this.onTickSlow(tenantId, symbol);
  }

  /**
   * #2A latency fix — the money-critical, cheap half of a tick pass.
   *
   * Pending-order triggers and protective SL/TP are what a client feels as
   * "my stop fired late" / "my limit filled away from where I set it". Both are
   * cheap: protective stops read the in-memory book and touch the DB only when a
   * level is actually crossed, and the pending lookup is a single indexed query
   * that usually returns nothing. Splitting them onto a fast cadence cuts
   * detection latency from the full coalescing interval (250ms) to tens of ms,
   * without reintroducing the pool exhaustion that the coalescing drain exists
   * to prevent — the heavy stop-out / live-P&L work stays on the slow pass.
   */
  async onTickFast(tenantId: string, symbol: string): Promise<void> {
    await this.triggerPendingOrders(tenantId, symbol);
    await this.checkProtectiveStops(tenantId, symbol);
  }

  /** #2A — the heavier, less latency-sensitive half: stop-out + live P&L stream. */
  async onTickSlow(tenantId: string, symbol: string): Promise<void> {
    await this.checkStopOut(tenantId, symbol);
    await this.emitLiveUpdates(tenantId, symbol);
  }

  /**
   * Stream live floating P/L: on each (throttled) tick, recompute open positions'
   * profit at the current price and the holding accounts' equity, and emit
   * POSITION_UPDATE + ACCOUNT_UPDATE so the UI moves in real time without a trade.
   */
  private async emitLiveUpdates(tenantId: string, symbol: string): Promise<void> {
    const key = `${tenantId}:${symbol}`;
    const now = Date.now();
    if (now - (this.liveThrottle.get(key) ?? 0) < 500) return;
    this.liveThrottle.set(key, now);

    const sym = await this.tickSymbol(tenantId, symbol);
    if (!sym) return;
    const positions = this.book.forSymbol(tenantId, sym.id);
    if (!positions.length) return;

    const accounts = new Set<string>();
    for (const p of positions) {
      // `sym` is the symbol every row in this bucket was filtered on, so it is
      // the same object the dropped `include: { symbol: true }` used to fetch.
      const spec = specOf(sym);
      const current =
        (p.side === 'BUY'
          ? this.deps.prices.sellPrice(tenantId, symbol)
          : this.deps.prices.buyPrice(tenantId, symbol)) ?? d(p.openPrice);
      const conv = this.quoteToAccount(tenantId, p.accountCurrency, spec.quoteCurrency);
      const profit =
        positionProfit(p.side as OrderSide, d(p.volume), d(p.openPrice), current, spec, conv) +
        d(p.swap) +
        d(p.commission);
      this.deps.emit?.({
        kind: 'POSITION_UPDATE',
        tenantId,
        position: {
          id: p.id,
          accountId: p.accountId,
          symbol,
          side: p.side,
          status: 'OPEN',
          volume: d(p.volume),
          openPrice: d(p.openPrice),
          currentPrice: current,
          slPrice: p.slPrice ? d(p.slPrice) : undefined,
          tpPrice: p.tpPrice ? d(p.tpPrice) : undefined,
          marginUsed: d(p.marginUsed),
          swap: d(p.swap),
          commission: d(p.commission),
          profit,
          openedAt: p.openedAt.toISOString(),
        },
      });
      accounts.add(p.accountId);
      // Cache floating P/L for readers that cannot see the tick stream (CRM
      // reporting, admin views). Coalesced and flushed below, not per tick.
      this.profitDirty.set(p.id, profit);
    }
    await this.flushProfits();
    for (const accountId of accounts) {
      const snap = await this.recomputeAccount(tenantId, accountId);
      this.deps.emit?.({ kind: 'ACCOUNT_UPDATE', tenantId, account: snap });
    }
  }

  // ── Floating-P/L cache ────────────────────────────────────────────────────
  // `Position.profit` is documented as "floating while open (cache)" but had no
  // writer for open rows — every reader outside the WebSocket stream saw 0.
  // That is what let the withdrawal check treat losing accounts as flat and
  // made the CRM report every open position as breakeven.
  //
  // Writing it on every tick would be a row update per position per tick, so
  // updates are coalesced and flushed at most once per PROFIT_PERSIST_MS in a
  // single statement. The cache is therefore correct to within that window —
  // fine for reporting, and never load-bearing for a money decision (see
  // `withdrawable`, which reads live prices).
  private readonly profitDirty = new Map<string, number>();
  private lastProfitFlush = 0;

  private async flushProfits(force = false): Promise<void> {
    const now = Date.now();
    if (!force && now - this.lastProfitFlush < PROFIT_PERSIST_MS) return;
    if (this.profitDirty.size === 0) return;
    this.lastProfitFlush = now;
    const rows = [...this.profitDirty.entries()];
    this.profitDirty.clear();
    try {
      const values = rows.map(([id, profit]) => Prisma.sql`(${id}::text, ${profit}::numeric)`);
      await prisma.$executeRaw`
        UPDATE positions AS p
        SET profit = v.profit
        FROM (VALUES ${Prisma.join(values)}) AS v(id, profit)
        WHERE p.id = v.id AND p.status = 'OPEN'
      `;
      // status = 'OPEN' matters: a position that closed between the tick and
      // this flush already has its REALIZED profit written, and must not be
      // overwritten with a stale floating value.
    } catch {
      // A cache refresh must never break tick processing.
    }
  }

  private async triggerPendingOrders(tenantId: string, symbol: string): Promise<void> {
    const sym = await this.tickSymbol(tenantId, symbol);
    if (!sym) return;
    const bid = this.deps.prices.sellPrice(tenantId, symbol);
    const ask = this.deps.prices.buyPrice(tenantId, symbol);
    if (bid == null || ask == null) return;

    const fromBook = this.pendings.forSymbol(tenantId, sym.id);
    let working = fromBook;
    if (working.length === 0) {
      // Gateway in-process placeOrder cannot write this process's book. Pull once.
      const rows = await prisma.order.findMany({
        where: {
          tenantId,
          symbolId: sym.id,
          OR: [
            { status: 'PENDING' },
            { status: 'PARTIAL', positionId: null, filledVolume: 0 },
          ],
        },
      });
      for (const r of rows) this.pendings.upsert(this.toPendingRow(r));
      working = this.pendings.forSymbol(tenantId, sym.id);
    }

    const now = new Date();
    const staleCutoff = new Date(Date.now() - STALE_CLAIM_MS);

    for (const o of working) {
      if (o.status === 'PARTIAL' && o.updatedAt > staleCutoff) continue;

      if (o.expiresAt && o.expiresAt < now) {
        const expired = await prisma.order.update({ where: { id: o.id }, data: { status: 'EXPIRED' } });
        this.pendings.remove(o.id);
        this.deps.emit?.({ kind: 'ORDER_UPDATE', tenantId, order: this.orderDto(expired, symbol) });
        continue;
      }

      const trigger = o.stopPrice ?? o.price;
      if (trigger == null) continue;
      const action = pendingFires({
        type: o.type,
        side: o.side,
        bid,
        ask,
        trigger,
        stopPrice: o.stopPrice,
        limitPrice: o.price,
        stopTriggered: o.stopTriggered,
      });

      if (action === 'arm_stop_limit') {
        const armed = await prisma.order.updateMany({
          where: { id: o.id, status: 'PENDING', stopTriggered: false },
          data: { stopTriggered: true, triggeredAt: now },
        });
        if (armed.count > 0) {
          this.pendings.patch(o.id, { stopTriggered: true });
          counters.inc('order.stop_limit_armed');
        }
        continue;
      }

      if (action !== 'fill') {
        if (o.status === 'PARTIAL') {
          const released = await prisma.order.updateMany({
            where: { id: o.id, status: 'PARTIAL' },
            data: { status: 'PENDING' },
          });
          if (released.count > 0) this.pendings.patch(o.id, { status: 'PENDING' });
        }
        continue;
      }

      const claimed = await prisma.order.updateMany({
        where: { id: o.id, status: { in: ['PENDING', 'PARTIAL'] } },
        data: { status: 'PARTIAL', triggeredAt: now },
      });
      if (claimed.count === 0) continue;
      this.pendings.patch(o.id, { status: 'PARTIAL' });

      const pendingAcct = await prisma.account.findFirst({ where: { id: o.accountId, tenantId } });
      if (!pendingAcct) {
        const rejected = await prisma.order.update({ where: { id: o.id }, data: { status: 'REJECTED' } });
        this.pendings.remove(o.id);
        this.deps.emit?.({ kind: 'ORDER_UPDATE', tenantId, order: this.orderDto(rejected, symbol) });
        continue;
      }

      const clampPrice = isLimitFillType(o.type) && o.price != null ? o.price : undefined;
      try {
        const fill = await this.executeMarket(
          tenantId,
          pendingAcct,
          sym,
          specOf(sym),
          {
            accountId: o.accountId,
            symbol,
            side: o.side as OrderSide,
            type: 'MARKET',
            volume: o.volume,
            slPrice: o.slPrice ?? undefined,
            tpPrice: o.tpPrice ?? undefined,
            source: 'api',
          },
          o.volume,
          clampPrice,
        );
        const filled = await prisma.order.update({
          where: { id: o.id },
          data: {
            status: 'FILLED',
            filledAt: now,
            triggeredAt: now,
            filledVolume: o.volume,
            avgFillPrice: fill.fillPrice ?? null,
            positionId: fill.positionId ?? null,
          },
        });
        this.pendings.remove(o.id);
        counters.inc('order.pending_filled');
        this.deps.emit?.({ kind: 'ORDER_UPDATE', tenantId, order: this.orderDto(filled, symbol) });
      } catch (err) {
        const reject =
          err instanceof BtError &&
          (err.code === BtErrorCode.INSUFFICIENT_MARGIN ||
            err.code === BtErrorCode.TRADING_DISABLED ||
            err.code === BtErrorCode.INVALID_VOLUME);
        try {
          const restored = await prisma.order.update({
            where: { id: o.id },
            data: { status: reject ? 'REJECTED' : 'PENDING' },
          });
          if (reject) this.pendings.remove(o.id);
          else this.pendings.patch(o.id, { status: 'PENDING' });
          this.deps.emit?.({
            kind: 'ORDER_UPDATE',
            tenantId,
            order: this.orderDto(restored, symbol),
          });
        } catch (restoreErr) {
          console.error(
            `[engine] could not release claim on order ${o.id}:`,
            (restoreErr as Error).message,
          );
        }
      }
    }
  }

  private async checkProtectiveStops(tenantId: string, symbol: string): Promise<void> {
    const sym = await this.tickSymbol(tenantId, symbol);
    if (!sym) return;
    const bid = this.deps.prices.sellPrice(tenantId, symbol);
    const ask = this.deps.prices.buyPrice(tenantId, symbol);
    if (bid == null || ask == null) return;

    const open = this.book.forSymbol(tenantId, sym.id);
    for (const p of open) {
      const hit = protectiveHit({
        side: p.side,
        bid,
        ask,
        sl: p.slPrice ? d(p.slPrice) : null,
        tp: p.tpPrice ? d(p.tpPrice) : null,
      });
      if (hit.hit) {
        counters.inc(hit.hit === 'SL' ? 'order.sl_fired' : 'order.tp_fired');
        await this.closePosition(tenantId, p.id, undefined, {
          protectiveLevel: hit.level == null ? undefined : Number(hit.level),
        }).catch(() => undefined);
      }
    }
  }

  private async checkStopOut(tenantId: string, symbol: string): Promise<void> {
    // Find accounts holding this symbol and re-evaluate margin level.
    const sym = await this.tickSymbol(tenantId, symbol);
    if (!sym) return;
    const accounts = this.book.accountsForSymbol(tenantId, sym.id);
    for (const accountId of accounts) {
      await this.enforceStopOut(tenantId, accountId);
    }
  }

  /**
   * Liquidate an account back above its stop-out level.
   *
   * MT5 semantics: close the most-losing position, re-evaluate, repeat until
   * margin level recovers. Two things this used to get wrong:
   *
   *  - The victim was chosen with `orderBy: { profit: 'asc' }`, but
   *    `Position.profit` is only written when a position CLOSES. Every open row
   *    holds the 0 default, so that was an all-ties sort returning an arbitrary
   *    row — a winning position could be liquidated while the loser stayed
   *    open. Selection now runs on live floating P/L via `worstPosition`.
   *
   *  - Only one position was closed per tick, so an account that gapped far
   *    through stop-out stayed under water until the next tick arrived — and if
   *    the feed stalled, indefinitely. It now cascades within the one call.
   */
  private async enforceStopOut(tenantId: string, accountId: string): Promise<void> {
    // Can never need more closes than there are positions; also bounds the loop
    // if something below starts failing.
    let guard = await prisma.position.count({ where: { tenantId, accountId, status: 'OPEN' } });
    // Positions that would not close (e.g. no price on their symbol). Skipped so
    // one stuck position cannot stall liquidation of the rest.
    const unclosable = new Set<string>();

    while (guard-- > 0) {
      // Re-read every pass: each close moves balance, margin and equity.
      const acct = await prisma.account.findUnique({ where: { id: accountId } });
      if (!acct) return;
      const views = await this.openViews(tenantId, accountId, acct.currency);
      const agg = computeAggregates(d(acct.balance), d(acct.credit), views);
      if (agg.margin <= 0) return;

      if (agg.marginLevel > acct.stopOutLevel) {
        // Above stop-out. Margin call is a notification only — no liquidation.
        if (agg.marginLevel <= acct.marginCallLevel) {
          this.deps.emit?.({ kind: 'MARGIN_CALL', tenantId, accountId, marginLevel: agg.marginLevel });
          await this.deps.crmOutbox?.(tenantId, 'margin.call', {
            login: acct.login,
            accountId,
            marginLevel: agg.marginLevel,
            freeMargin: agg.freeMargin,
            equity: agg.equity,
            balance: d(acct.balance),
          });
        }
        return;
      }

      const worst = worstPosition(views, unclosable);
      if (!worst?.id) return; // nothing left we are able to close

      this.deps.emit?.({ kind: 'STOP_OUT', tenantId, accountId, positionId: worst.id });
      await this.deps.crmOutbox?.(tenantId, 'stop.out', {
        login: acct.login,
        accountId,
        positionId: worst.id,
        marginLevel: agg.marginLevel,
      });
      try {
        await this.closePosition(tenantId, worst.id, undefined, { floorBalanceAtZero: true });
      } catch {
        unclosable.add(worst.id);
      }
    }
  }

  // ── FX conversion (quote currency → account currency) ─────────────────────
  /** Mid price for a symbol from the live source, or null. */
  private mid(tenantId: string, symbol: string): number | null {
    const b = this.deps.prices.buyPrice(tenantId, symbol);
    const s = this.deps.prices.sellPrice(tenantId, symbol);
    if (b != null && s != null) return (b + s) / 2;
    return b ?? s ?? null;
  }

  /**
   * Factor converting one unit of the symbol's QUOTE currency into the account
   * currency (1 when they match), or null when the feed carries no conversion
   * pair. This is what makes JPY/cross pairs margin and P/L correctly: e.g.
   * USDJPY's quote is JPY, so margin/profit computed in JPY must be divided by
   * ~157 to land in USD. Tries quote+acct (GBPUSD) direct, then acct+quote
   * (USDJPY) inverse.
   */
  private fxFactor(tenantId: string, accountCcy: string, quoteCcy: string): number | null {
    return resolveFxFactor(accountCcy, quoteCcy, (s) => this.mid(tenantId, s));
  }

  /** Throttle the missing-pair warning to once a minute per tenant+pair. */
  private readonly fxWarned = new Map<string, number>();

  private warnMissingFx(tenantId: string, accountCcy: string, quoteCcy: string): void {
    const key = `${tenantId}:${quoteCcy}:${accountCcy}`;
    const now = Date.now();
    const last = this.fxWarned.get(key) ?? 0;
    if (now - last < 60_000) return;
    this.fxWarned.set(key, now);
    // eslint-disable-next-line no-console
    console.error(
      `[engine] FX_RATE_UNAVAILABLE no ${quoteCcy}->${accountCcy} conversion pair in the feed ` +
        `(tenant ${tenantId}); values for existing positions are being reported UNCONVERTED. ` +
        `Add ${quoteCcy}${accountCcy} or ${accountCcy}${quoteCcy} to the symbol list.`,
    );
  }

  /**
   * Conversion factor for valuing an EXISTING position (tick, close, snapshot).
   *
   * Falls back to 1 when no pair is available, because an exit must never be
   * blocked by a missing quote — but it now logs loudly instead of silently
   * mis-booking. Use `quoteToAccountStrict` anywhere new risk is taken.
   */
  private quoteToAccount(tenantId: string, accountCcy: string, quoteCcy: string): number {
    const f = this.fxFactor(tenantId, accountCcy, quoteCcy);
    if (f != null) return f;
    this.warnMissingFx(tenantId, accountCcy, quoteCcy);
    return 1;
  }

  /**
   * Conversion factor for OPENING a position. Refuses rather than guessing: a
   * silent fallback to 1 books margin and P/L in the wrong currency (a USD
   * account trading EURGBP with no GBPUSD in the feed was off by ~27%), and the
   * error compounds for as long as the position stays open.
   */
  private quoteToAccountStrict(tenantId: string, accountCcy: string, quoteCcy: string): number {
    const f = this.fxFactor(tenantId, accountCcy, quoteCcy);
    if (f != null) return f;
    this.warnMissingFx(tenantId, accountCcy, quoteCcy);
    throw new BtError(
      BtErrorCode.FX_RATE_UNAVAILABLE,
      `no ${quoteCcy}->${accountCcy} conversion pair available; refusing to open a position that cannot be valued`,
    );
  }

  // ── Aggregates & snapshot ─────────────────────────────────────────────────
  private mapOpenViews(
    tenantId: string,
    accountCcy: string,
    positions: Array<{
      id: string;
      side: string;
      volume: Prisma.Decimal | number | string;
      openPrice: Prisma.Decimal | number | string;
      marginUsed: Prisma.Decimal | number | string;
      swap: Prisma.Decimal | number | string;
      commission: Prisma.Decimal | number | string;
      symbol: NonNullable<SymbolRow>;
    }>,
  ): OpenPositionView[] {
    return positions.map((p) => {
      const spec = specOf(p.symbol);
      const current =
        (p.side === 'BUY'
          ? this.deps.prices.sellPrice(tenantId, p.symbol.symbol)
          : this.deps.prices.buyPrice(tenantId, p.symbol.symbol)) ?? d(p.openPrice);
      return {
        id: p.id,
        side: p.side as OrderSide,
        volume: d(p.volume),
        openPrice: d(p.openPrice),
        currentPrice: current,
        marginUsed: d(p.marginUsed),
        swap: d(p.swap),
        commission: d(p.commission),
        spec,
        quoteToAcct: this.quoteToAccount(tenantId, accountCcy, p.symbol.quoteCurrency),
      };
    });
  }

  private async openViews(tenantId: string, accountId: string, accountCcy: string): Promise<OpenPositionView[]> {
    const positions = await prisma.position.findMany({
      where: { tenantId, accountId, status: 'OPEN' },
      include: { symbol: true },
      // Stable order so stop-out victim selection is deterministic on ties.
      orderBy: { openedAt: 'asc' },
    });
    return this.mapOpenViews(tenantId, accountCcy, positions);
  }

  /** Same as openViews but reads inside an open Prisma transaction (after FOR UPDATE). */
  private async openViewsTx(
    tx: Prisma.TransactionClient,
    tenantId: string,
    accountId: string,
    accountCcy: string,
  ): Promise<OpenPositionView[]> {
    const positions = await tx.position.findMany({
      where: { tenantId, accountId, status: 'OPEN' },
      include: { symbol: true },
    });
    return this.mapOpenViews(tenantId, accountCcy, positions);
  }

  private async aggregatesFor(tenantId: string, accountId: string) {
    const acct = await prisma.account.findUniqueOrThrow({ where: { id: accountId } });
    const views = await this.openViews(tenantId, accountId, acct.currency);
    return computeAggregates(d(acct.balance), d(acct.credit), views);
  }

  /** Recompute and persist live aggregates; return the snapshot for WS/CRM. */
  async recomputeAccount(tenantId: string, accountId: string): Promise<AccountSnapshot> {
    const acct = await prisma.account.findUniqueOrThrow({ where: { id: accountId } });
    const views = await this.openViews(tenantId, accountId, acct.currency);
    const agg = computeAggregates(d(acct.balance), d(acct.credit), views);
    await prisma.account.update({
      where: { id: accountId },
      data: {
        equity: agg.equity,
        margin: agg.margin,
        freeMargin: agg.freeMargin,
        marginLevel: agg.marginLevel,
        floatingPL: agg.floatingPL,
      },
    });
    return {
      accountId: acct.id,
      login: acct.login,
      currency: acct.currency,
      leverage: acct.leverage,
      balance: d(acct.balance),
      credit: d(acct.credit),
      equity: agg.equity,
      margin: agg.margin,
      freeMargin: agg.freeMargin,
      marginLevel: agg.marginLevel,
      floatingPL: agg.floatingPL,
      closedPL: 0,
      bonus: d(acct.credit),
      dividend: 0,
      ts: Date.now(),
    };
  }

  /**
   * Cash a client may actually withdraw, computed from LIVE prices.
   *
   * Do not compute this from `Account.freeMargin` or from `Position.profit`:
   * that column is only written when a position closes, so summing it treats
   * every open position as flat. An account 8,000 down on a 10,000 balance then
   * reports ~9,000 free instead of ~1,000, and the client can withdraw money
   * that an open loss has already consumed — leaving the balance negative when
   * the position finally closes.
   *
   * `stale` lists symbols with no live quote. Their P/L falls back to the open
   * price (i.e. zero), which understates a loss, so a caller moving money OUT
   * must refuse rather than pay against incomplete data.
   */
  async withdrawable(
    tenantId: string,
    accountId: string,
  ): Promise<{
    balance: number;
    credit: number;
    equity: number;
    freeMargin: number;
    available: number;
    stale: string[];
  }> {
    const acct = await prisma.account.findUniqueOrThrow({ where: { id: accountId } });
    const positions = await prisma.position.findMany({
      where: { tenantId, accountId, status: 'OPEN' },
      include: { symbol: true },
      orderBy: { openedAt: 'asc' },
    });

    const stale: string[] = [];
    for (const p of positions) {
      // Closing side: a BUY exits at bid, a SELL at ask.
      const px =
        p.side === 'BUY'
          ? this.deps.prices.sellPrice(tenantId, p.symbol.symbol)
          : this.deps.prices.buyPrice(tenantId, p.symbol.symbol);
      if (px == null && !stale.includes(p.symbol.symbol)) stale.push(p.symbol.symbol);
    }

    const views = this.mapOpenViews(tenantId, acct.currency, positions);
    const agg = computeAggregates(d(acct.balance), d(acct.credit), views);
    const available = withdrawableCash(d(acct.balance), agg.freeMargin);

    return {
      balance: d(acct.balance),
      credit: d(acct.credit),
      equity: agg.equity,
      freeMargin: agg.freeMargin,
      available,
      stale,
    };
  }

  // ── Risk enforcement ──────────────────────────────────────────────────────
  private async enforceRisk(
    tenantId: string,
    accountId: string,
    symbol: string,
    volume: number,
  ): Promise<void> {
    const limits = await prisma.riskLimit.findMany({
      where: { tenantId, enabled: true, scope: { in: ['tenant', `account:${accountId}`] } },
    });
    for (const l of limits) {
      if (l.maxLotPerOrder != null && volume > d(l.maxLotPerOrder))
        throw new BtError(BtErrorCode.RISK_LIMIT_BREACH, 'max lot per order exceeded');
      if (l.maxOpenPositions != null) {
        const count = await prisma.position.count({ where: { tenantId, accountId, status: 'OPEN' } });
        if (count >= l.maxOpenPositions)
          throw new BtError(BtErrorCode.RISK_LIMIT_BREACH, 'max open positions reached');
      }
      if (l.maxOpenLots != null) {
        const agg = await prisma.position.aggregate({
          where: { tenantId, accountId, status: 'OPEN' },
          _sum: { volume: true },
        });
        if (d(agg._sum.volume) + volume > d(l.maxOpenLots))
          throw new BtError(BtErrorCode.RISK_LIMIT_BREACH, 'max open lots exceeded');
      }
    }
  }
}
