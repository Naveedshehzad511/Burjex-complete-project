import { Body, Controller, Delete, Get, Param, Patch, Post, Put, Query, UseGuards } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation } from '@nestjs/swagger';
import { prisma, Prisma } from '@btrader/db';
import {
  BookType, ExposureSummary, SymbolExposure, HedgeOrderDTO, LpConfigDTO,
  LpExecDriver, InstrumentClass, RoutingRuleDTO, RoutingRuleInput, RoutingTestResult, VenueMode,
} from '@btrader/shared';
import { notionalQuote, positionProfit, SymbolCalcSpec, resolveRouting, RoutingRuleLike, venueKeyFor } from '@btrader/engine-core';

const isVenueMode = (v: unknown): v is VenueMode => v === 'FIXED' || v === 'BEST_PRICE';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { Roles, CurrentTenant, CurrentUser } from '../../common/decorators';
import { EngineProvider } from '../trading/engine.provider';
import { AuditService } from '../audit/audit.service';

const d = (v: Prisma.Decimal | number | string | null | undefined): number =>
  v == null ? 0 : typeof v === 'number' ? v : Number(v);

function isBook(v: unknown): v is BookType {
  return v === 'A' || v === 'B';
}

const LP_DRIVERS: LpExecDriver[] = ['MOCK', 'PRIMEXM', 'CENTROID', 'ONEZERO', 'MT5'];
function isDriver(v: unknown): v is LpExecDriver {
  return typeof v === 'string' && (LP_DRIVERS as string[]).includes(v);
}

const INSTRUMENT_CLASSES: InstrumentClass[] = [
  'FOREX', 'METALS', 'STOCKS', 'INDICES', 'CRYPTO', 'COMMODITIES', 'CUSTOM',
];
function isClass(v: unknown): v is InstrumentClass {
  return typeof v === 'string' && (INSTRUMENT_CLASSES as string[]).includes(v);
}

/**
 * Dealing desk / book management. Tenant admins assign clients (and symbols /
 * groups) to the A or B book, monitor net warehouse exposure, watch the A-book
 * cover blotter, and configure the LP execution bridge.
 */
@ApiTags('book')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Roles('TENANT_ADMIN', 'SUPER_ADMIN', 'TENANT_STAFF')
@Controller('admin/book')
export class BookController {
  constructor(
    private readonly eng: EngineProvider,
    private readonly audit: AuditService,
  ) {}

  // ── Assignment ──────────────────────────────────────────────────────────
  @Patch('accounts/:id')
  @ApiOperation({ summary: "Set a client account's book (A | B | null=inherit group)" })
  async setAccountBook(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Param('id') id: string,
    @Body() body: { book: BookType | null },
  ) {
    const book = body.book === null ? null : isBook(body.book) ? body.book : undefined;
    if (book === undefined) return { error: 'book must be A, B, or null' };
    const before = await prisma.account.findFirst({ where: { id, tenantId: t.id }, select: { book: true } });
    const acct = await prisma.account.update({ where: { id }, data: { book } });
    await this.audit.log(t.id, u.id, 'BOOK_CHANGE', 'account', id, { before, after: { book } });
    return { id: acct.id, book: acct.book };
  }

  @Patch('symbols/:id/force')
  @ApiOperation({ summary: 'Force a symbol to A-book (or clear with null)' })
  async setSymbolForce(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Param('id') id: string,
    @Body() body: { forceBook: BookType | null },
  ) {
    const forceBook = body.forceBook === null ? null : isBook(body.forceBook) ? body.forceBook : undefined;
    if (forceBook === undefined) return { error: 'forceBook must be A, B, or null' };
    const sym = await prisma.symbol.update({ where: { id }, data: { forceBook } });
    await this.audit.log(t.id, u.id, 'BOOK_CHANGE', 'symbol', id, { after: { forceBook } });
    return { id: sym.id, forceBook: sym.forceBook };
  }

  @Patch('groups/:id/default')
  @ApiOperation({ summary: "Set a symbol group's default book" })
  async setGroupDefault(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Param('id') id: string,
    @Body() body: { defaultBook: BookType },
  ) {
    if (!isBook(body.defaultBook)) return { error: 'defaultBook must be A or B' };
    const g = await prisma.symbolGroup.update({ where: { id }, data: { defaultBook: body.defaultBook } });
    await this.audit.log(t.id, u.id, 'BOOK_CHANGE', 'group', id, { after: { defaultBook: g.defaultBook } });
    return { id: g.id, defaultBook: g.defaultBook };
  }

  // ── Exposure monitor ──────────────────────────────────────────────────────
  @Get('exposure')
  @ApiOperation({ summary: 'Net B-book (warehouse) exposure per symbol + A-book coverage summary' })
  async exposure(@CurrentTenant() t: any): Promise<ExposureSummary> {
    const positions = await prisma.position.findMany({
      where: { tenantId: t.id, status: 'OPEN' },
      include: { symbol: true },
    });
    // Filled A-book covers per symbol (informational).
    const hedges = await prisma.hedgeOrder.groupBy({
      by: ['symbolName'],
      where: { tenantId: t.id, status: 'FILLED' },
      _sum: { volume: true },
    });
    const hedgedBySymbol = new Map<string, number>();
    for (const h of hedges) hedgedBySymbol.set(h.symbolName, d(h._sum.volume));

    const bySymbol = new Map<string, SymbolExposure>();
    let aBookPositions = 0;
    let bBookPositions = 0;
    let totalNetNotional = 0;
    let totalFloatingPL = 0;

    for (const p of positions) {
      const covered = d(p.coveredVolume);
      const warehoused = Math.max(0, d(p.volume) - covered);
      if (p.book === 'A' && warehoused <= 0) {
        aBookPositions++; // fully covered — no warehouse risk
      } else {
        if (p.book === 'A') aBookPositions++;
        else bBookPositions++;
      }
      const sym = p.symbol;

      // Always surface the symbol row so covered lots are visible even when fully hedged.
      let e = bySymbol.get(sym.symbol);
      if (!e) {
        e = {
          symbol: sym.symbol,
          digits: sym.digits,
          longLots: 0,
          shortLots: 0,
          netLots: 0,
          netNotional: 0,
          floatingPL: 0,
          positions: 0,
          aHedgedLots: hedgedBySymbol.get(sym.symbol) ?? 0,
          coveredLots: 0,
          warehousedLots: 0,
        };
        bySymbol.set(sym.symbol, e);
      }
      e.coveredLots += covered;
      if (warehoused <= 0) continue; // no uncovered (warehouse) risk on this position

      const spec: SymbolCalcSpec = {
        digits: sym.digits,
        pipSize: d(sym.pipSize),
        contractSize: d(sym.contractSize),
        marginRate: d(sym.marginRate),
        quoteCurrency: sym.quoteCurrency,
        baseCurrency: sym.baseCurrency,
      };
      const exitPx =
        (p.side === 'BUY'
          ? this.eng.prices.sellPrice(t.id, sym.symbol)
          : this.eng.prices.buyPrice(t.id, sym.symbol)) ?? d(p.openPrice);
      // Risk math uses only the UNCOVERED (warehoused) lots.
      const clientPL = positionProfit(p.side as any, warehoused, d(p.openPrice), exitPx, spec);
      const notional = notionalQuote(warehoused, spec, exitPx);

      if (p.side === 'BUY') {
        e.longLots += warehoused;
        e.netNotional += notional;
      } else {
        e.shortLots += warehoused;
        e.netNotional -= notional;
      }
      e.netLots = e.longLots - e.shortLots;
      e.warehousedLots = e.longLots + e.shortLots; // gross warehoused on this symbol
      // Broker (house) P/L is the inverse of the client's floating P/L.
      e.floatingPL += -clientPL;
      e.positions++;
      totalNetNotional += p.side === 'BUY' ? notional : -notional;
      totalFloatingPL += -clientPL;
    }

    const [hedgePending, hedgeRejected] = await Promise.all([
      prisma.hedgeOrder.count({ where: { tenantId: t.id, status: 'PENDING' } }),
      prisma.hedgeOrder.count({ where: { tenantId: t.id, status: 'REJECTED' } }),
    ]);

    return {
      asOf: Date.now(),
      symbols: [...bySymbol.values()].sort((a, b) => Math.abs(b.netNotional) - Math.abs(a.netNotional)),
      totalNetNotional,
      totalFloatingPL,
      aBookPositions,
      bBookPositions,
      hedgePending,
      hedgeRejected,
    };
  }

  // ── A-book cover blotter ────────────────────────────────────────────────
  @Get('hedges')
  @ApiOperation({ summary: 'A-book cover (hedge) order blotter' })
  async hedges(@CurrentTenant() t: any, @Query('status') status?: string): Promise<HedgeOrderDTO[]> {
    const rows = await prisma.hedgeOrder.findMany({
      where: { tenantId: t.id, ...(status ? { status: status as any } : {}) },
      include: { lpProvider: { select: { code: true } } },
      orderBy: { openedAt: 'desc' },
      take: 500,
    });
    return rows.map((h) => ({
      id: h.id,
      positionId: h.positionId,
      accountId: h.accountId,
      symbol: h.symbolName,
      side: h.side as any,
      volume: d(h.volume),
      status: h.status as any,
      driver: h.driver as any,
      lpProviderId: h.lpProviderId,
      lpProviderCode: h.lpProvider?.code ?? null,
      requestPrice: h.requestPrice == null ? null : d(h.requestPrice),
      fillPrice: h.fillPrice == null ? null : d(h.fillPrice),
      closePrice: h.closePrice == null ? null : d(h.closePrice),
      slippage: d(h.slippage),
      externalRef: h.externalRef,
      rejectReason: h.rejectReason,
      openedAt: h.openedAt.toISOString(),
      closedAt: h.closedAt ? h.closedAt.toISOString() : null,
    }));
  }

  // ── LP execution venues (multi-venue; optionally tied to a provider) ──────
  private lpVenueDTO(c: {
    id: string; driver: string; enabled: boolean; isDefault: boolean; label: string | null;
    lpProviderId: string | null; coverLogin: string | null;
    endpoint: string | null; senderCompId: string | null; targetCompId: string | null;
    credentialRef: string | null; simSlippageBps: number; simRejectPct: number; status: string | null;
    lpProvider?: { code: string } | null;
  }): LpConfigDTO & { id: string } {
    return {
      id: c.id,
      driver: c.driver as LpExecDriver,
      enabled: c.enabled,
      isDefault: c.isDefault,
      label: c.label,
      lpProviderId: c.lpProviderId,
      lpProviderCode: c.lpProvider?.code ?? null,
      coverLogin: c.coverLogin,
      endpoint: c.endpoint,
      senderCompId: c.senderCompId,
      targetCompId: c.targetCompId,
      credentialRef: c.credentialRef,
      simSlippageBps: c.simSlippageBps,
      simRejectPct: c.simRejectPct,
      status: c.status,
    };
  }

  @Get('lp-venues')
  @ApiOperation({ summary: 'List the tenant A-book LP execution venues (per driver / per provider)' })
  async listLpVenues(@CurrentTenant() t: any): Promise<(LpConfigDTO & { id: string })[]> {
    const rows = await prisma.lpExecutionConfig.findMany({
      where: { tenantId: t.id },
      include: { lpProvider: { select: { code: true } } },
      orderBy: [{ isDefault: 'desc' }, { driver: 'asc' }],
    });
    return rows.map((c) => this.lpVenueDTO(c));
  }

  /** Back-compat: the tenant's default (or first enabled) venue as a single object. */
  @Get('lp-config')
  @ApiOperation({ summary: "Get the tenant's default A-book LP venue (back-compat single-venue view)" })
  async getLpConfig(@CurrentTenant() t: any): Promise<LpConfigDTO> {
    const c = await prisma.lpExecutionConfig.findFirst({
      where: { tenantId: t.id },
      include: { lpProvider: { select: { code: true } } },
      orderBy: [{ isDefault: 'desc' }, { enabled: 'desc' }, { createdAt: 'asc' }],
    });
    if (!c) {
      return {
        driver: 'MOCK', enabled: false, isDefault: false, label: null, lpProviderId: null,
        lpProviderCode: null, coverLogin: null, endpoint: null,
        senderCompId: null, targetCompId: null, credentialRef: null,
        simSlippageBps: 0, simRejectPct: 0, status: null,
      };
    }
    return this.lpVenueDTO(c);
  }

  @Put('lp-venues')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Create/update an LP execution venue (per provider, or legacy per driver)' })
  async setLpVenue(@CurrentTenant() t: any, @CurrentUser() u: any, @Body() body: Partial<LpConfigDTO> & { id?: string }) {
    if (!isDriver(body.driver)) return { error: `driver must be one of ${LP_DRIVERS.join(', ')}` };
    const driver = body.driver;
    const lpProviderId = body.lpProviderId ?? null;
    if (lpProviderId) {
      const prov = await prisma.liquidityProvider.findFirst({ where: { id: lpProviderId, tenantId: t.id }, select: { id: true } });
      if (!prov) return { error: 'liquidity provider not found' };
    }
    const data = {
      driver,
      enabled: body.enabled ?? false,
      isDefault: body.isDefault ?? false,
      label: body.label ?? null,
      coverLogin: body.coverLogin ?? null,
      endpoint: body.endpoint ?? null,
      senderCompId: body.senderCompId ?? null,
      targetCompId: body.targetCompId ?? null,
      credentialRef: body.credentialRef ?? null,
      simSlippageBps: body.simSlippageBps ?? 0,
      simRejectPct: body.simRejectPct ?? 0,
    };
    // At most one default venue per tenant.
    if (data.isDefault) {
      await prisma.lpExecutionConfig.updateMany({ where: { tenantId: t.id }, data: { isDefault: false } });
    }
    // Locate the row: explicit id > provider link > legacy (tenant+driver, no provider).
    let existing = body.id
      ? await prisma.lpExecutionConfig.findFirst({ where: { id: body.id, tenantId: t.id }, select: { id: true } })
      : lpProviderId
        ? await prisma.lpExecutionConfig.findUnique({ where: { lpProviderId }, select: { id: true } })
        : await prisma.lpExecutionConfig.findFirst({ where: { tenantId: t.id, lpProviderId: null, driver }, select: { id: true } });
    if (existing) {
      await prisma.lpExecutionConfig.update({ where: { id: existing.id }, data: { ...data, lpProviderId } });
    } else {
      await prisma.lpExecutionConfig.create({ data: { tenantId: t.id, lpProviderId, ...data } });
    }
    await this.eng.reloadLpConfig(t.id);
    await this.audit.log(t.id, u.id, 'LP_CONFIG_CHANGE', 'lpConfig', lpProviderId ?? `${t.id}:${driver}`, {
      after: { driver, lpProviderId, enabled: data.enabled, isDefault: data.isDefault },
    });
    return { ok: true, driver, bridgeActive: this.eng.lp.hasBridge(venueKeyFor(t.id, lpProviderId, driver)) };
  }

  /** Back-compat alias for the old single-venue PUT. */
  @Put('lp-config')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Create/update an LP venue (back-compat alias of PUT lp-venues)' })
  async setLpConfig(@CurrentTenant() t: any, @CurrentUser() u: any, @Body() body: Partial<LpConfigDTO>) {
    return this.setLpVenue(t, u, body);
  }

  @Delete('lp-venues/:id')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Remove an LP venue (by row id, or legacy by driver) and reload the bridges' })
  async deleteLpVenue(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') idOrDriver: string) {
    // Accept a row id or, for back-compat, a driver name (legacy null-provider rows).
    const where = isDriver(idOrDriver)
      ? { tenantId: t.id, lpProviderId: null, driver: idOrDriver as LpExecDriver }
      : { id: idOrDriver, tenantId: t.id };
    const r = await prisma.lpExecutionConfig.deleteMany({ where });
    if (!r.count) return { error: 'venue not found' };
    await this.eng.reloadLpConfig(t.id);
    await this.audit.log(t.id, u.id, 'LP_CONFIG_CHANGE', 'lpConfig', idOrDriver, { after: { deleted: true } });
    return { ok: true };
  }

  // ── Manual desk hedge (cover B-book exposure on demand) ───────────────────
  @Put('hedge')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Send a manual cover to the MT5 venue (any symbol/side/lots the desk chooses)' })
  async manualHedge(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Body() body: { symbol: string; side: 'BUY' | 'SELL'; volume: number },
  ) {
    const symbol = String(body.symbol ?? '').trim().toUpperCase();
    const side = body.side === 'SELL' ? 'SELL' : 'BUY';
    const volume = Number(body.volume);
    if (!symbol || !(volume > 0)) return { error: 'symbol and positive volume required' };

    const cfg = await prisma.lpExecutionConfig.findFirst({
      where: { tenantId: t.id, driver: 'MT5', enabled: true },
      orderBy: [{ isDefault: 'desc' }, { createdAt: 'asc' }],
      select: { lpProviderId: true },
    });
    if (!cfg)
      return { error: 'MT5 LP bridge is not enabled — add an MT5 venue and enable it first' };

    const sym = await prisma.symbol.findFirst({ where: { tenantId: t.id, symbol }, select: { id: true } });
    if (!sym) return { error: 'symbol not found' };

    const bid = this.eng.prices.sellPrice(t.id, symbol);
    const ask = this.eng.prices.buyPrice(t.id, symbol);
    const mid = bid != null && ask != null ? (bid + ask) / 2 : (bid ?? ask ?? null);

    const hedge = await prisma.hedgeOrder.create({
      data: {
        tenantId: t.id,
        symbolId: sym.id,
        symbolName: symbol,
        lpProviderId: cfg.lpProviderId,
        side: side as any,
        volume,
        status: 'PENDING',
        kind: 'BROKER_MANUAL',
        driver: 'MT5',
        requestPrice: mid,
      },
    });
    await this.audit.log(t.id, u.id, 'ORDER_PLACE', 'hedgeOrder', hedge.id, { after: { manual: true, symbol, side, volume } });
    return { ok: true, hedgeId: hedge.id, status: 'PENDING' };
  }

  @Patch('hedge/:id/close')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Close a filled broker hedge on MT5 (bridge executes the close)' })
  async closeHedge(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string) {
    const h = await prisma.hedgeOrder.findFirst({ where: { id, tenantId: t.id } });
    if (!h) return { error: 'hedge not found' };
    if (h.status !== 'FILLED') return { error: `hedge is ${h.status}, only FILLED can be closed` };
    await prisma.hedgeOrder.update({ where: { id }, data: { status: 'CLOSE_PENDING' } });
    await this.audit.log(t.id, u.id, 'POSITION_CLOSE', 'hedgeOrder', id);
    return { ok: true, status: 'CLOSE_PENDING' };
  }

  @Get('broker-hedges')
  @ApiOperation({ summary: 'Broker hedge blotter (manual + auto), most recent first' })
  async brokerHedges(@CurrentTenant() t: any) {
    const rows = await prisma.hedgeOrder.findMany({
      where: { tenantId: t.id, kind: { in: ['BROKER_MANUAL', 'BROKER_AUTO'] } },
      orderBy: { openedAt: 'desc' },
      take: 300,
    });
    return rows.map((h) => ({
      id: h.id,
      kind: h.kind,
      symbol: h.symbolName,
      side: h.side,
      volume: d(h.volume),
      status: h.status,
      requestPrice: h.requestPrice == null ? null : d(h.requestPrice),
      fillPrice: h.fillPrice == null ? null : d(h.fillPrice),
      externalRef: h.externalRef,
      rejectReason: h.rejectReason,
      openedAt: h.openedAt.toISOString(),
    }));
  }

  // ── Auto net-hedge rules ──────────────────────────────────────────────────
  @Get('autohedge')
  @ApiOperation({ summary: 'List per-symbol auto net-hedge rules' })
  async listAutoHedge(@CurrentTenant() t: any) {
    const rows = await prisma.autoHedgeRule.findMany({ where: { tenantId: t.id }, orderBy: { symbolName: 'asc' } });
    return rows.map((r) => ({
      symbol: r.symbolName,
      enabled: r.enabled,
      thresholdLots: d(r.thresholdLots),
      minClipLots: d(r.minClipLots),
      maxClipLots: r.maxClipLots == null ? null : d(r.maxClipLots),
    }));
  }

  @Put('autohedge')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Create/update an auto net-hedge rule for a symbol (empty/disabled = off)' })
  async setAutoHedge(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Body() body: { symbol: string; enabled?: boolean; thresholdLots?: number; minClipLots?: number; maxClipLots?: number | null },
  ) {
    const symbol = String(body.symbol ?? '').trim().toUpperCase();
    if (!symbol) return { error: 'symbol required' };
    const data = {
      enabled: body.enabled ?? false,
      thresholdLots: Math.max(0, Number(body.thresholdLots ?? 0)),
      minClipLots: Math.max(0.0001, Number(body.minClipLots ?? 0.01)),
      maxClipLots: body.maxClipLots == null ? null : Math.max(0, Number(body.maxClipLots)),
    };
    await prisma.autoHedgeRule.upsert({
      where: { tenantId_symbolName: { tenantId: t.id, symbolName: symbol } },
      create: { tenantId: t.id, symbolName: symbol, ...data },
      update: data,
    });
    await this.audit.log(t.id, u.id, 'TENANT_CHANGE', 'autoHedgeRule', symbol, { after: data });
    return { ok: true };
  }

  // ── Routing Rules (Group × Symbol/Class → book + LP venue) ────────────────
  private routingRuleDTO(r: {
    id: string; tradingGroupId: string | null; symbolId: string | null;
    instrumentClass: InstrumentClass | null; book: BookType; venueMode: string;
    lpProviderId: string | null; lpDriver: LpExecDriver | null; coverageRatio: number;
    priority: number; enabled: boolean; description: string | null;
    createdAt: Date; updatedAt: Date;
    tradingGroup?: { name: string } | null; symbol?: { symbol: string } | null;
    lpProvider?: { code: string } | null;
  }): RoutingRuleDTO {
    return {
      id: r.id,
      tradingGroupId: r.tradingGroupId,
      tradingGroupName: r.tradingGroup?.name ?? null,
      symbolId: r.symbolId,
      symbolName: r.symbol?.symbol ?? null,
      instrumentClass: r.instrumentClass,
      book: r.book,
      venueMode: r.venueMode as VenueMode,
      lpProviderId: r.lpProviderId,
      lpProviderCode: r.lpProvider?.code ?? null,
      lpDriver: r.lpDriver,
      coverageRatio: r.coverageRatio,
      priority: r.priority,
      enabled: r.enabled,
      description: r.description,
      createdAt: r.createdAt.toISOString(),
      updatedAt: r.updatedAt.toISOString(),
    };
  }

  @Get('routing-rules')
  @ApiOperation({ summary: 'List routing rules (most-specific first) for this tenant' })
  async listRoutingRules(@CurrentTenant() t: any): Promise<RoutingRuleDTO[]> {
    const rows = await prisma.routingRule.findMany({
      where: { tenantId: t.id },
      include: {
        tradingGroup: { select: { name: true } },
        symbol: { select: { symbol: true } },
        lpProvider: { select: { code: true } },
      },
      orderBy: [{ priority: 'desc' }, { createdAt: 'asc' }],
    });
    return rows.map((r) => this.routingRuleDTO(r));
  }

  /** Validate + normalise a rule payload. Returns an error string or clean data. */
  private async validateRule(tenantId: string, body: RoutingRuleInput): Promise<{ error: string } | { data: any }> {
    if (!isBook(body.book)) return { error: 'book must be A or B' };
    if (body.venueMode != null && !isVenueMode(body.venueMode)) return { error: 'venueMode invalid' };
    if (body.lpDriver != null && !isDriver(body.lpDriver)) return { error: 'lpDriver invalid' };
    if (body.instrumentClass != null && !isClass(body.instrumentClass)) return { error: 'instrumentClass invalid' };
    // A rule may target a specific symbol OR a class, not both (a symbol implies its class).
    if (body.symbolId && body.instrumentClass) return { error: 'set either symbolId or instrumentClass, not both' };
    if (body.tradingGroupId) {
      const g = await prisma.tradingGroup.findFirst({ where: { id: body.tradingGroupId, tenantId }, select: { id: true } });
      if (!g) return { error: 'tradingGroup not found' };
    }
    if (body.symbolId) {
      const s = await prisma.symbol.findFirst({ where: { id: body.symbolId, tenantId }, select: { id: true } });
      if (!s) return { error: 'symbol not found' };
    }
    const venueMode: VenueMode = (body.venueMode as VenueMode) ?? 'FIXED';
    let lpProviderId = body.book === 'A' && venueMode === 'FIXED' ? (body.lpProviderId ?? null) : null;
    if (lpProviderId) {
      const p = await prisma.liquidityProvider.findFirst({ where: { id: lpProviderId, tenantId }, select: { id: true } });
      if (!p) return { error: 'liquidity provider not found' };
    }
    return {
      data: {
        tradingGroupId: body.tradingGroupId ?? null,
        symbolId: body.symbolId ?? null,
        instrumentClass: body.symbolId ? null : (body.instrumentClass ?? null),
        book: body.book,
        venueMode: body.book === 'A' ? venueMode : 'FIXED',
        lpProviderId,
        lpDriver: body.book === 'A' && venueMode === 'FIXED' && !lpProviderId ? (body.lpDriver ?? null) : null,
        coverageRatio: body.book === 'A' && Number.isFinite(body.coverageRatio)
          ? Math.max(0, Math.min(100, Math.trunc(body.coverageRatio as number)))
          : 100,
        priority: Number.isFinite(body.priority) ? Math.trunc(body.priority as number) : 0,
        enabled: body.enabled ?? true,
        description: body.description ?? null,
      },
    };
  }

  @Post('routing-rules')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Create a routing rule' })
  async createRoutingRule(@CurrentTenant() t: any, @CurrentUser() u: any, @Body() body: RoutingRuleInput) {
    const v = await this.validateRule(t.id, body);
    if ('error' in v) return v;
    const r = await prisma.routingRule.create({ data: { tenantId: t.id, ...v.data } });
    await this.audit.log(t.id, u.id, 'LP_CONFIG_CHANGE', 'routingRule', r.id, { after: v.data });
    return { ok: true, id: r.id };
  }

  @Put('routing-rules/:id')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Update a routing rule' })
  async updateRoutingRule(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Param('id') id: string,
    @Body() body: RoutingRuleInput,
  ) {
    const existing = await prisma.routingRule.findFirst({ where: { id, tenantId: t.id }, select: { id: true } });
    if (!existing) return { error: 'routing rule not found' };
    const v = await this.validateRule(t.id, body);
    if ('error' in v) return v;
    await prisma.routingRule.update({ where: { id }, data: v.data });
    await this.audit.log(t.id, u.id, 'LP_CONFIG_CHANGE', 'routingRule', id, { after: v.data });
    return { ok: true };
  }

  @Delete('routing-rules/:id')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Delete a routing rule' })
  async deleteRoutingRule(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string) {
    const r = await prisma.routingRule.deleteMany({ where: { id, tenantId: t.id } });
    if (!r.count) return { error: 'routing rule not found' };
    await this.audit.log(t.id, u.id, 'LP_CONFIG_CHANGE', 'routingRule', id, { after: { deleted: true } });
    return { ok: true };
  }

  @Post('routing-rules/test')
  @ApiOperation({ summary: 'Preview which rule applies to a Group × Symbol order (resolved book + venue)' })
  async testRouting(
    @CurrentTenant() t: any,
    @Body() body: { tradingGroupId?: string | null; symbolId?: string | null },
  ): Promise<RoutingTestResult | { error: string }> {
    if (!body.symbolId) return { error: 'symbolId required for a routing preview' };
    const sym = await prisma.symbol.findFirst({
      where: { id: body.symbolId, tenantId: t.id },
      select: { id: true, class: true, forceBook: true, groupId: true },
    });
    if (!sym) return { error: 'symbol not found' };
    const sg = sym.groupId
      ? await prisma.symbolGroup.findUnique({ where: { id: sym.groupId }, select: { defaultBook: true } })
      : null;
    const rules = await prisma.routingRule.findMany({
      where: { tenantId: t.id, enabled: true },
      select: {
        id: true, tradingGroupId: true, symbolId: true, instrumentClass: true,
        book: true, venueMode: true, lpProviderId: true, lpDriver: true, priority: true, createdAt: true,
      },
    });
    const routing = resolveRouting(rules as RoutingRuleLike[], {
      accountGroupId: body.tradingGroupId ?? null,
      symbolId: sym.id,
      symbolClass: sym.class,
      accountBook: null, // group-level preview: no specific account override
      symbolForceBook: sym.forceBook,
      symbolGroupDefaultBook: sg?.defaultBook,
    });

    // Resolve the concrete execution venue the way coverOpen would.
    let lpProviderId: string | null = null;
    let lpProviderCode: string | null = null;
    let lpDriver: LpExecDriver | null = null;
    let reason = routing.reason;

    if (routing.book === 'A') {
      const symbolRow = await prisma.symbol.findFirst({ where: { id: sym.id }, select: { symbol: true } });
      if (routing.venueMode === 'BEST_PRICE') {
        const code = symbolRow ? await this.eng.activeSourceCode(t.id, symbolRow.symbol) : null;
        if (code) {
          const prov = await prisma.liquidityProvider.findFirst({ where: { tenantId: t.id, code }, select: { id: true, code: true } });
          lpProviderId = prov?.id ?? null;
          lpProviderCode = prov?.code ?? null;
        }
        reason += lpProviderCode ? ` → active source ${lpProviderCode}` : ' → no active source yet';
      } else {
        lpProviderId = routing.lpProviderId ?? null;
      }

      // Load the venue config (by provider, else rule driver, else tenant default).
      let cfg = lpProviderId
        ? await prisma.lpExecutionConfig.findUnique({ where: { lpProviderId }, select: { driver: true, lpProviderId: true, lpProvider: { select: { code: true } } } })
        : null;
      if (!cfg && routing.lpDriver) {
        cfg = await prisma.lpExecutionConfig.findFirst({ where: { tenantId: t.id, lpProviderId: null, driver: routing.lpDriver }, select: { driver: true, lpProviderId: true, lpProvider: { select: { code: true } } } });
      }
      if (!cfg) {
        cfg = await prisma.lpExecutionConfig.findFirst({
          where: { tenantId: t.id, enabled: true },
          orderBy: [{ isDefault: 'desc' }, { createdAt: 'asc' }],
          select: { driver: true, lpProviderId: true, lpProvider: { select: { code: true } } },
        });
        if (cfg) reason += ` → tenant default venue`;
      }
      lpDriver = (cfg?.driver as LpExecDriver) ?? null;
      lpProviderId = cfg?.lpProviderId ?? lpProviderId;
      lpProviderCode = cfg?.lpProvider?.code ?? lpProviderCode;
      if (!cfg) reason += ' → NO enabled venue (broker exposed)';
    }

    return {
      book: routing.book,
      lpDriver,
      venueMode: routing.book === 'A' ? routing.venueMode : undefined,
      lpProviderId,
      lpProviderCode,
      coverageRatio: routing.book === 'A' ? routing.coverageRatio : undefined,
      matchedRuleId: routing.matchedRuleId,
      reason,
    };
  }

  // ── Manual cover-more (move warehoused B-book lots of a position to A) ────
  @Put('positions/:id/cover')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Cover more lots of a position to the LP (partial A-book: B → A)' })
  async coverMore(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Param('id') id: string,
    @Body() body: { lots: number },
  ) {
    const pos = await prisma.position.findFirst({ where: { id, tenantId: t.id, status: 'OPEN' }, select: { id: true } });
    if (!pos) return { error: 'position not found' };
    const lots = Number(body.lots);
    if (!(lots > 0)) return { error: 'lots must be > 0' };
    const res = await this.eng.engine.coverMore(t.id, id, lots);
    await this.audit.log(t.id, u.id, 'ORDER_PLACE', 'position', id, { after: { coverMore: lots, ...res } });
    return { ok: true, ...res };
  }

  // ── News mode (disclosed volatility control: widen spread + pause opens) ───
  @Get('news')
  @ApiOperation({ summary: 'Per-symbol news-mode state (widen spread + pause new opens)' })
  async listNews(@CurrentTenant() t: any) {
    const rows = await prisma.symbol.findMany({
      where: { tenantId: t.id, enabled: true },
      select: { id: true, symbol: true, digits: true, class: true, newsMode: true, newsSpreadPoints: true, newsHaltOpens: true },
      orderBy: [{ class: 'asc' }, { symbol: 'asc' }],
    });
    return rows;
  }

  @Put('news')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN', 'TENANT_STAFF')
  @ApiOperation({ summary: 'Toggle news mode for a symbol (real prices — widen + pause opens, NOT price faking)' })
  async setNews(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Body() body: { symbolId: string; newsMode?: boolean; newsSpreadPoints?: number; newsHaltOpens?: boolean },
  ) {
    const sym = await prisma.symbol.findFirst({ where: { id: body.symbolId, tenantId: t.id }, select: { id: true } });
    if (!sym) return { error: 'symbol not found' };
    const data: any = {};
    if (body.newsMode != null) data.newsMode = !!body.newsMode;
    if (Number.isFinite(body.newsSpreadPoints)) data.newsSpreadPoints = Math.max(0, Math.trunc(body.newsSpreadPoints as number));
    if (body.newsHaltOpens != null) data.newsHaltOpens = !!body.newsHaltOpens;
    await prisma.symbol.update({ where: { id: sym.id }, data });
    await this.audit.log(t.id, u.id, 'SYMBOL_CHANGE', 'symbol', sym.id, { after: { news: data } });
    return { ok: true };
  }
}
