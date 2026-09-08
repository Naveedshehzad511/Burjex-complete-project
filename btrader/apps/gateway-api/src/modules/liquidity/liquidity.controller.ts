import { randomBytes } from 'crypto';
import { Body, Controller, Delete, Get, Param, Post, Put, UseGuards } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation } from '@nestjs/swagger';
import Redis from 'ioredis';
import { prisma } from '@btrader/db';
import {
  LiquidityProviderDTO, LiquidityProviderInput, LiquidityMonitor, LiquiditySymbolQuotes,
  LpQuote, FeedTransport, LpExecDriver, PricingMode, TenantPricingDTO,
  InstrumentClass, ProviderSymbolMapDTO, ProviderSymbolMapInput, UnmappedSymbol,
} from '@btrader/shared';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { Roles, CurrentTenant, CurrentUser } from '../../common/decorators';
import { AuditService } from '../audit/audit.service';

const TRANSPORTS: FeedTransport[] = ['MT5_PUSH', 'WS_PULL', 'FIX_PULL'];
const DRIVERS: LpExecDriver[] = ['MOCK', 'PRIMEXM', 'CENTROID', 'ONEZERO', 'MT5'];
const CLASSES: InstrumentClass[] = ['FOREX', 'METALS', 'STOCKS', 'INDICES', 'CRYPTO', 'COMMODITIES', 'CUSTOM'];
const isTransport = (v: unknown): v is FeedTransport => typeof v === 'string' && (TRANSPORTS as string[]).includes(v);
const isDriver = (v: unknown): v is LpExecDriver => typeof v === 'string' && (DRIVERS as string[]).includes(v);
const isClass = (v: unknown): v is InstrumentClass => typeof v === 'string' && (CLASSES as string[]).includes(v);

/**
 * Liquidity providers (multi-source feed). A provider = one "company" supplying a
 * price feed (and, later, an execution venue). market-data keeps each provider's
 * quotes separate; the monitor endpoint exposes them side-by-side so the desk can
 * compare spreads (the foundation for best-spread routing).
 */
@ApiTags('liquidity')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Roles('TENANT_ADMIN', 'SUPER_ADMIN', 'TENANT_STAFF')
@Controller('admin/liquidity')
export class LiquidityController {
  private readonly redis = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6380');
  constructor(private readonly audit: AuditService) {}

  private dto(p: {
    id: string; name: string; code: string; transport: string; driver: string;
    enabled: boolean; isPrimaryFeed: boolean; staleMs: number; feedToken: string | null;
    symbolSuffix: string | null; suffixByClass: unknown;
    feedEndpoint: string | null; senderCompId: string | null; targetCompId: string | null;
    credentialRef: string | null; status: string | null; createdAt: Date; updatedAt: Date;
  }): LiquidityProviderDTO {
    return {
      id: p.id,
      name: p.name,
      code: p.code,
      transport: p.transport as FeedTransport,
      driver: p.driver as LpExecDriver,
      enabled: p.enabled,
      isPrimaryFeed: p.isPrimaryFeed,
      staleMs: p.staleMs,
      symbolSuffix: p.symbolSuffix,
      suffixByClass: (p.suffixByClass as Record<string, string> | null) ?? null,
      hasFeedToken: !!p.feedToken,
      feedToken: p.feedToken,
      feedEndpoint: p.feedEndpoint,
      senderCompId: p.senderCompId,
      targetCompId: p.targetCompId,
      credentialRef: p.credentialRef,
      status: p.status,
      createdAt: p.createdAt.toISOString(),
      updatedAt: p.updatedAt.toISOString(),
    };
  }

  @Get()
  @ApiOperation({ summary: 'List liquidity providers for this tenant' })
  async list(@CurrentTenant() t: any): Promise<LiquidityProviderDTO[]> {
    const rows = await prisma.liquidityProvider.findMany({
      where: { tenantId: t.id },
      orderBy: [{ isPrimaryFeed: 'desc' }, { code: 'asc' }],
    });
    return rows.map((r) => this.dto(r));
  }

  // ── Tenant pricing policy (declared before :id routes) ────────────────────
  @Get('pricing')
  @ApiOperation({ summary: 'Get the tenant client-pricing policy (PRIMARY vs BEST_SPREAD)' })
  async getPricing(@CurrentTenant() t: any): Promise<TenantPricingDTO> {
    const row = await prisma.tenant.findUnique({
      where: { id: t.id },
      select: { pricingMode: true, bestSpreadMarginPoints: true },
    });
    return {
      pricingMode: (row?.pricingMode ?? 'PRIMARY') as PricingMode,
      bestSpreadMarginPoints: row?.bestSpreadMarginPoints ?? 0,
    };
  }

  @Put('pricing')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Set the client-pricing policy (best-spread selection + hysteresis margin)' })
  async setPricing(@CurrentTenant() t: any, @CurrentUser() u: any, @Body() body: Partial<TenantPricingDTO>) {
    const mode = body.pricingMode;
    if (mode != null && mode !== 'PRIMARY' && mode !== 'BEST_SPREAD') return { error: 'pricingMode must be PRIMARY or BEST_SPREAD' };
    const margin = Number(body.bestSpreadMarginPoints);
    const data: any = {};
    if (mode != null) data.pricingMode = mode;
    if (Number.isFinite(margin)) data.bestSpreadMarginPoints = Math.max(0, Math.trunc(margin));
    await prisma.tenant.update({ where: { id: t.id }, data });
    await this.audit.log(t.id, u.id, 'LP_CONFIG_CHANGE', 'tenantPricing', t.id, { after: data });
    return { ok: true };
  }

  private clean(t: any, body: LiquidityProviderInput): { error: string } | { data: any } {
    const name = String(body.name ?? '').trim();
    const code = String(body.code ?? '').trim().toUpperCase();
    if (!name) return { error: 'name required' };
    if (!/^[A-Z0-9_-]{2,16}$/.test(code)) return { error: 'code must be 2–16 chars [A-Z0-9_-]' };
    if (body.transport != null && !isTransport(body.transport)) return { error: 'invalid transport' };
    if (body.driver != null && !isDriver(body.driver)) return { error: 'invalid driver' };
    const transport: FeedTransport = (body.transport as FeedTransport) ?? 'MT5_PUSH';
    // Normalise per-class suffixes: keep only valid classes with non-empty values.
    let suffixByClass: Record<string, string> | null = null;
    if (body.suffixByClass && typeof body.suffixByClass === 'object') {
      const out: Record<string, string> = {};
      for (const [cls, sfx] of Object.entries(body.suffixByClass)) {
        if (isClass(cls) && typeof sfx === 'string' && sfx.trim()) out[cls] = sfx.trim();
      }
      suffixByClass = Object.keys(out).length ? out : null;
    }
    return {
      data: {
        name,
        code,
        transport,
        driver: (body.driver as LpExecDriver) ?? 'MT5',
        enabled: body.enabled ?? true,
        isPrimaryFeed: body.isPrimaryFeed ?? false,
        staleMs: Number.isFinite(body.staleMs) ? Math.max(200, Math.trunc(body.staleMs as number)) : 2000,
        symbolSuffix: body.symbolSuffix?.trim() ? body.symbolSuffix.trim() : null,
        suffixByClass: suffixByClass ?? undefined,
        feedToken: body.feedToken ?? null,
        feedEndpoint: body.feedEndpoint ?? null,
        senderCompId: body.senderCompId ?? null,
        targetCompId: body.targetCompId ?? null,
        credentialRef: body.credentialRef ?? null,
      },
    };
  }

  @Post()
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Create a liquidity provider (auto-generates a feed token for MT5_PUSH)' })
  async create(@CurrentTenant() t: any, @CurrentUser() u: any, @Body() body: LiquidityProviderInput) {
    const v = this.clean(t, body);
    if ('error' in v) return v;
    // MT5_PUSH needs a token the bridge sends; generate one if not supplied.
    if (v.data.transport === 'MT5_PUSH' && !v.data.feedToken) {
      v.data.feedToken = `bt_feed_${randomBytes(16).toString('hex')}`;
    }
    if (v.data.isPrimaryFeed) {
      await prisma.liquidityProvider.updateMany({ where: { tenantId: t.id }, data: { isPrimaryFeed: false } });
    }
    try {
      const p = await prisma.liquidityProvider.create({ data: { tenantId: t.id, ...v.data } });
      await this.audit.log(t.id, u.id, 'LP_CONFIG_CHANGE', 'liquidityProvider', p.id, { after: { code: p.code, transport: p.transport } });
      return { ok: true, id: p.id, feedToken: p.feedToken };
    } catch (e: any) {
      if (e?.code === 'P2002') return { error: 'a provider with that code or feed token already exists' };
      throw e;
    }
  }

  @Put(':id')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Update a liquidity provider' })
  async update(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string, @Body() body: LiquidityProviderInput) {
    const existing = await prisma.liquidityProvider.findFirst({ where: { id, tenantId: t.id }, select: { id: true } });
    if (!existing) return { error: 'provider not found' };
    const v = this.clean(t, body);
    if ('error' in v) return v;
    if (v.data.transport === 'MT5_PUSH' && !v.data.feedToken) {
      v.data.feedToken = `bt_feed_${randomBytes(16).toString('hex')}`;
    }
    if (v.data.isPrimaryFeed) {
      await prisma.liquidityProvider.updateMany({ where: { tenantId: t.id, id: { not: id } }, data: { isPrimaryFeed: false } });
    }
    try {
      await prisma.liquidityProvider.update({ where: { id }, data: v.data });
      await this.audit.log(t.id, u.id, 'LP_CONFIG_CHANGE', 'liquidityProvider', id, { after: { code: v.data.code } });
      return { ok: true };
    } catch (e: any) {
      if (e?.code === 'P2002') return { error: 'a provider with that code or feed token already exists' };
      throw e;
    }
  }

  @Delete(':id')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Delete a liquidity provider' })
  async remove(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string) {
    const r = await prisma.liquidityProvider.deleteMany({ where: { id, tenantId: t.id } });
    if (!r.count) return { error: 'provider not found' };
    await this.audit.log(t.id, u.id, 'LP_CONFIG_CHANGE', 'liquidityProvider', id, { after: { deleted: true } });
    return { ok: true };
  }

  // ── Explicit symbol maps (feed name → B-Trader symbol) ────────────────────
  @Get(':id/symbol-maps')
  @ApiOperation({ summary: 'List a provider\'s explicit symbol mappings' })
  async listSymbolMaps(@CurrentTenant() t: any, @Param('id') id: string): Promise<ProviderSymbolMapDTO[]> {
    const rows = await prisma.providerSymbolMap.findMany({
      where: { tenantId: t.id, lpProviderId: id },
      include: { symbol: { select: { symbol: true } } },
      orderBy: { rawSymbol: 'asc' },
    });
    return rows.map((m) => ({
      id: m.id, lpProviderId: m.lpProviderId, rawSymbol: m.rawSymbol, symbolId: m.symbolId,
      symbolName: m.symbol?.symbol ?? null,
    }));
  }

  @Post(':id/symbol-maps')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Add/replace an explicit symbol mapping for a provider' })
  async addSymbolMap(
    @CurrentTenant() t: any, @CurrentUser() u: any,
    @Param('id') id: string, @Body() body: ProviderSymbolMapInput,
  ) {
    const prov = await prisma.liquidityProvider.findFirst({ where: { id, tenantId: t.id }, select: { id: true } });
    if (!prov) return { error: 'provider not found' };
    const rawSymbol = String(body.rawSymbol ?? '').trim().toUpperCase();
    if (!rawSymbol) return { error: 'rawSymbol required' };
    const sym = await prisma.symbol.findFirst({ where: { id: body.symbolId, tenantId: t.id }, select: { id: true } });
    if (!sym) return { error: 'symbol not found' };
    await prisma.providerSymbolMap.upsert({
      where: { lpProviderId_rawSymbol: { lpProviderId: id, rawSymbol } },
      create: { tenantId: t.id, lpProviderId: id, rawSymbol, symbolId: sym.id },
      update: { symbolId: sym.id },
    });
    // Clear it from the "unmapped seen" helper for this provider.
    const prv = await prisma.liquidityProvider.findUnique({ where: { id }, select: { code: true } });
    if (prv) await this.redis.hdel(`bt:unmapped:${t.id}`, `${prv.code}|${rawSymbol}`);
    await this.audit.log(t.id, u.id, 'SYMBOL_CHANGE', 'providerSymbolMap', id, { after: { rawSymbol, symbolId: sym.id } });
    return { ok: true };
  }

  @Delete('symbol-maps/:mapId')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Remove an explicit symbol mapping' })
  async deleteSymbolMap(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('mapId') mapId: string) {
    const r = await prisma.providerSymbolMap.deleteMany({ where: { id: mapId, tenantId: t.id } });
    if (!r.count) return { error: 'mapping not found' };
    await this.audit.log(t.id, u.id, 'SYMBOL_CHANGE', 'providerSymbolMap', mapId, { after: { deleted: true } });
    return { ok: true };
  }

  @Get('unmapped')
  @ApiOperation({ summary: 'Feed symbols seen recently that matched no B-Trader symbol (mapping helper)' })
  async unmapped(@CurrentTenant() t: any): Promise<UnmappedSymbol[]> {
    const raw = await this.redis.hgetall(`bt:unmapped:${t.id}`);
    const out: UnmappedSymbol[] = [];
    for (const [field, ts] of Object.entries(raw)) {
      const sep = field.indexOf('|');
      if (sep < 0) continue;
      out.push({ code: field.slice(0, sep), rawSymbol: field.slice(sep + 1), lastSeen: Number(ts) || 0 });
    }
    out.sort((a, b) => b.lastSeen - a.lastSeen);
    return out;
  }

  @Get('monitor')
  @ApiOperation({ summary: 'Live per-provider quotes + spreads per symbol (narrowest highlighted)' })
  async monitor(@CurrentTenant() t: any): Promise<LiquidityMonitor> {
    const now = Date.now();
    const [providers, symbols, raw, active] = await Promise.all([
      prisma.liquidityProvider.findMany({ where: { tenantId: t.id }, select: { code: true, staleMs: true } }),
      prisma.symbol.findMany({ where: { tenantId: t.id }, select: { symbol: true, digits: true } }),
      this.redis.hgetall(`bt:liq:${t.id}`),
      this.redis.hgetall(`bt:bestsrc:${t.id}`), // symbol -> active source code
    ]);
    const staleByCode = new Map(providers.map((p) => [p.code, p.staleMs]));
    const digitsBySymbol = new Map(symbols.map((s) => [s.symbol, s.digits]));

    // field key = "{code}|{symbol}" -> { bid, ask, ts }
    const bySymbol = new Map<string, LpQuote[]>();
    for (const [field, val] of Object.entries(raw)) {
      const sep = field.indexOf('|');
      if (sep < 0) continue;
      const code = field.slice(0, sep);
      const symbol = field.slice(sep + 1);
      let q: { bid: number; ask: number; ts: number };
      try {
        q = JSON.parse(val);
      } catch {
        continue;
      }
      const ageMs = now - q.ts;
      const quote: LpQuote = {
        code,
        bid: q.bid,
        ask: q.ask,
        spread: q.ask - q.bid,
        ts: q.ts,
        ageMs,
        stale: ageMs > (staleByCode.get(code) ?? 2000),
      };
      const arr = bySymbol.get(symbol) ?? [];
      arr.push(quote);
      bySymbol.set(symbol, arr);
    }

    const out: LiquiditySymbolQuotes[] = [];
    for (const [symbol, quotes] of bySymbol) {
      quotes.sort((a, b) => a.code.localeCompare(b.code));
      let bestCode: string | null = null;
      let bestSpread = Infinity;
      for (const q of quotes) {
        if (q.stale) continue;
        if (q.spread < bestSpread) {
          bestSpread = q.spread;
          bestCode = q.code;
        }
      }
      out.push({ symbol, digits: digitsBySymbol.get(symbol) ?? 5, quotes, bestCode, activeCode: active[symbol] ?? null });
    }
    out.sort((a, b) => a.symbol.localeCompare(b.symbol));
    return { asOf: now, symbols: out };
  }
}
