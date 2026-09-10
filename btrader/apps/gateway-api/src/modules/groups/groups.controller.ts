import { Body, Controller, Delete, Get, Param, Patch, Post, Put, UseGuards } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation } from '@nestjs/swagger';
import Redis from 'ioredis';
import { prisma } from '@btrader/db';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { Roles, CurrentTenant, CurrentUser } from '../../common/decorators';
import { AuditService } from '../audit/audit.service';

const PRICING_METHODS = new Set(['SPREAD_ONLY', 'COMMISSION_ONLY', 'SPREAD_AND_COMMISSION']);
const COMMISSION_TYPES = new Set(['NONE', 'PER_LOT', 'PER_SIDE', 'ROUND_TURN', 'PERCENT']);
const EXECUTION_APPLY_KEYS = [
  'marketBuy',
  'marketSell',
  'buyLimit',
  'sellLimit',
  'buyStop',
  'sellStop',
  'sl',
  'tp',
] as const;

/** Normalize admin body → Prisma JSON for TradingGroup.executionApplyTo. */
function normalizeExecutionApplyTo(raw: unknown): Record<string, boolean> {
  const src = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
  const out: Record<string, boolean> = {};
  for (const k of EXECUTION_APPLY_KEYS) {
    // Missing key ⇒ true (apply to all by default) so upgrades stay safe.
    out[k] = src[k] === undefined ? true : !!src[k];
  }
  return out;
}

type MappingInput = {
  lpSymbol?: string;
  clientSymbol?: string;
  pricingMethod?: string;
  minSpreadPoints?: number;
  maxSpreadPoints?: number;
  commissionType?: string;
  commissionValue?: number;
  enabled?: boolean;
  sortOrder?: number;
};

function normalizeMapping(raw: MappingInput, index: number) {
  const lpSymbol = String(raw.lpSymbol ?? '').trim().toUpperCase();
  const clientSymbol = String(raw.clientSymbol ?? '').trim();
  if (!lpSymbol || !clientSymbol) return null;
  const pricingMethod = PRICING_METHODS.has(String(raw.pricingMethod))
    ? String(raw.pricingMethod)
    : 'SPREAD_ONLY';
  let commissionType = COMMISSION_TYPES.has(String(raw.commissionType))
    ? String(raw.commissionType)
    : 'NONE';
  if (pricingMethod === 'SPREAD_ONLY') commissionType = 'NONE';
  if (pricingMethod === 'COMMISSION_ONLY' && commissionType === 'NONE') commissionType = 'PER_LOT';
  const minSpreadPoints = Math.max(0, Math.round(Number(raw.minSpreadPoints) || 0));
  let maxSpreadPoints = Math.max(0, Math.round(Number(raw.maxSpreadPoints) || 0));
  if (maxSpreadPoints > 0 && maxSpreadPoints < minSpreadPoints) maxSpreadPoints = minSpreadPoints;
  return {
    lpSymbol,
    clientSymbol,
    pricingMethod: pricingMethod as any,
    minSpreadPoints,
    maxSpreadPoints,
    commissionType: commissionType as any,
    commissionValue: Number(raw.commissionValue) || 0,
    enabled: raw.enabled !== false,
    sortOrder: Number.isFinite(Number(raw.sortOrder)) ? Number(raw.sortOrder) : index,
  };
}

/**
 * Client trading groups (Standard / Raw / ECN / STP …). A broker admin creates
 * a group with Symbol Mappings (LP → Client + per-symbol pricing) and default
 * leverage/book, then CRM account types map to the group by name so provisioned
 * accounts inherit that symbol universe automatically.
 */
@ApiTags('groups')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Roles('TENANT_ADMIN', 'SUPER_ADMIN', 'TENANT_STAFF')
@Controller('admin/groups')
export class GroupsController {
  private readonly redis = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6380');

  constructor(private readonly audit: AuditService) {}

  @Get()
  @ApiOperation({ summary: 'List trading groups (with rules, mappings + account counts)' })
  async list(@CurrentTenant() t: any) {
    const groups = await prisma.tradingGroup.findMany({
      where: { tenantId: t.id },
      include: {
        rules: { include: { symbol: { select: { symbol: true } } } },
        symbolMappings: {
          include: { symbol: { select: { id: true, symbol: true, class: true } } },
          orderBy: [{ sortOrder: 'asc' }, { lpSymbol: 'asc' }],
        },
        _count: { select: { accounts: true, symbolMappings: true } },
      },
      orderBy: { name: 'asc' },
    });
    return groups;
  }

  /** Live Market Watch / LP symbols for Symbol Mapping autocomplete. */
  @Get('lp-symbols')
  @ApiOperation({ summary: 'List LP / Market Watch symbols (live ticks ∪ enabled symbols)' })
  async lpSymbols(@CurrentTenant() t: any) {
    const [symbols, rawTicks] = await Promise.all([
      prisma.symbol.findMany({
        where: { tenantId: t.id, enabled: true },
        select: { id: true, symbol: true, class: true, description: true },
        orderBy: [{ class: 'asc' }, { symbol: 'asc' }],
      }),
      this.redis.hgetall(`bt:${t.id}:lastticks`).catch(() => ({} as Record<string, string>)),
    ]);
    const byCode = new Map(symbols.map((s) => [s.symbol.toUpperCase(), s]));
    const live = new Set(Object.keys(rawTicks || {}).map((s) => s.toUpperCase()));
    // Include any live tick symbols not yet in the Symbol table (still useful for mapping).
    for (const code of live) {
      if (!byCode.has(code)) {
        byCode.set(code, { id: '', symbol: code, class: 'CUSTOM' as any, description: 'Live feed' });
      }
    }
    return [...byCode.values()]
      .map((s) => ({
        id: s.id || null,
        symbol: s.symbol,
        class: s.class,
        description: s.description,
        live: live.has(s.symbol.toUpperCase()),
      }))
      .sort((a, b) => {
        if (a.live !== b.live) return a.live ? -1 : 1;
        return a.symbol.localeCompare(b.symbol);
      });
  }

  @Post()
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Create a trading group (optional symbolMappings in body)' })
  async create(@CurrentTenant() t: any, @CurrentUser() u: any, @Body() body: any) {
    const g = await prisma.tradingGroup.create({
      data: {
        tenantId: t.id,
        name: String(body.name).trim(),
        description: body.description ?? null,
        enabled: body.enabled ?? true,
        defaultLeverage: body.defaultLeverage ?? 100,
        defaultBook: body.defaultBook === 'A' ? 'A' : 'B',
        swapFree: !!body.swapFree,
        markupPoints: body.markupPoints ?? 0,
        slippagePoints: body.slippagePoints ?? 0,
        commissionType: body.commissionType ?? 'NONE',
        commissionValue: body.commissionValue ?? 0,
        // #2B: execution model (MARKET default; INSTANT honours click price 100%).
        executionMode: body.executionMode === 'INSTANT' ? 'INSTANT' : 'MARKET',
        instantDeviationPoints:
          body.instantDeviationPoints != null ? Math.max(0, Number(body.instantDeviationPoints) | 0) : 0,
        executionDelayMs:
          body.executionDelayMs != null ? Math.max(0, Number(body.executionDelayMs) | 0) : 0,
        executionApplyTo: normalizeExecutionApplyTo(body.executionApplyTo),
        clientSymbolSuffix: body.clientSymbolSuffix?.trim() ? body.clientSymbolSuffix.trim() : null,
      },
    });
    if (Array.isArray(body.symbolMappings)) {
      const mapResult = await this.replaceMappings(t.id, g.id, body.symbolMappings);
      if ((mapResult as any).error) return mapResult;
    }
    await this.audit.log(t.id, u.id, 'CREATE', 'tradingGroup', g.id, { after: { name: g.name } });
    return prisma.tradingGroup.findUnique({
      where: { id: g.id },
      include: {
        symbolMappings: { orderBy: [{ sortOrder: 'asc' }, { lpSymbol: 'asc' }] },
        _count: { select: { accounts: true, symbolMappings: true } },
      },
    });
  }

  @Patch(':id')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Update a trading group (markup, commission, defaults, optional mappings)' })
  async update(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string, @Body() body: any) {
    const data: any = {};
    for (const k of ['name', 'description', 'enabled', 'defaultLeverage', 'swapFree', 'markupPoints', 'slippagePoints', 'commissionType', 'commissionValue']) {
      if (body[k] !== undefined) data[k] = k === 'name' ? String(body[k]).trim() : body[k];
    }
    if (body.clientSymbolSuffix !== undefined) {
      data.clientSymbolSuffix = body.clientSymbolSuffix?.trim() ? body.clientSymbolSuffix.trim() : null;
    }
    if (body.defaultBook !== undefined) data.defaultBook = body.defaultBook === 'A' ? 'A' : 'B';
    // #2B: execution model + Instant honour / Market delay + per-kind apply flags.
    if (body.executionMode !== undefined) data.executionMode = body.executionMode === 'INSTANT' ? 'INSTANT' : 'MARKET';
    if (body.instantDeviationPoints !== undefined) {
      data.instantDeviationPoints = Math.max(0, Number(body.instantDeviationPoints) | 0);
    }
    if (body.executionDelayMs !== undefined) {
      data.executionDelayMs = Math.max(0, Number(body.executionDelayMs) | 0);
    }
    if (body.executionApplyTo !== undefined) {
      data.executionApplyTo = normalizeExecutionApplyTo(body.executionApplyTo);
    }
    const g = await prisma.tradingGroup.updateMany({ where: { id, tenantId: t.id }, data });
    if (g.count && Array.isArray(body.symbolMappings)) {
      const mapResult = await this.replaceMappings(t.id, id, body.symbolMappings);
      if ((mapResult as any).error) return mapResult;
    }
    await this.audit.log(t.id, u.id, 'TENANT_CHANGE', 'tradingGroup', id, { after: data });
    return { updated: g.count };
  }

  @Delete(':id')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Delete a trading group (accounts fall back to no group)' })
  async remove(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string) {
    await prisma.account.updateMany({ where: { groupId: id, tenantId: t.id }, data: { groupId: null } });
    await prisma.tradingGroup.deleteMany({ where: { id, tenantId: t.id } });
    await this.audit.log(t.id, u.id, 'DELETE', 'tradingGroup', id);
    return { ok: true };
  }

  // ── Symbol Mapping (LP → Client + per-symbol pricing) ─────────────────────
  @Get(':id/mappings')
  @ApiOperation({ summary: 'List Symbol Mappings for a trading group' })
  async getMappings(@CurrentTenant() t: any, @Param('id') id: string) {
    const group = await prisma.tradingGroup.findFirst({ where: { id, tenantId: t.id }, select: { id: true } });
    if (!group) return { error: 'group not found' };
    const mappings = await prisma.tradingGroupSymbolMapping.findMany({
      where: { tradingGroupId: id },
      include: { symbol: { select: { id: true, symbol: true, class: true } } },
      orderBy: [{ sortOrder: 'asc' }, { lpSymbol: 'asc' }],
    });
    return { mappings };
  }

  @Put(':id/mappings')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Replace Symbol Mappings for a trading group (also syncs instrument allowlist)' })
  async setMappings(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Param('id') id: string,
    @Body() body: { mappings: MappingInput[] },
  ) {
    const group = await prisma.tradingGroup.findFirst({ where: { id, tenantId: t.id }, select: { id: true } });
    if (!group) return { error: 'group not found' };
    const result = await this.replaceMappings(t.id, id, body.mappings ?? []);
    await this.audit.log(t.id, u.id, 'TENANT_CHANGE', 'tradingGroup', id, {
      after: { symbolMappings: result.count },
    });
    return result;
  }

  /** Replace mappings and sync TradingGroupSymbol allowlist from resolved symbolIds. */
  private async replaceMappings(tenantId: string, groupId: string, raw: MappingInput[]) {
    const normalized = (raw ?? [])
      .map((r, i) => normalizeMapping(r, i))
      .filter((m): m is NonNullable<typeof m> => !!m);

    // Spec §5: Trading Symbol name must be unique system-wide (across all groups).
    const clientNames = normalized.map((m) => m.clientSymbol);
    const dupInPayload = clientNames.filter((n, i) => clientNames.indexOf(n) !== i);
    if (dupInPayload.length) {
      return { error: `duplicate trading symbol in payload: ${dupInPayload[0]}` };
    }
    if (clientNames.length) {
      const taken = await prisma.tradingGroupSymbolMapping.findMany({
        where: {
          clientSymbol: { in: clientNames },
          tradingGroup: { tenantId },
          NOT: { tradingGroupId: groupId },
        },
        select: { clientSymbol: true, tradingGroup: { select: { name: true } } },
        take: 5,
      });
      if (taken.length) {
        const t = taken[0];
        return {
          error: `trading symbol "${t.clientSymbol}" already used in group "${t.tradingGroup.name}" (must be unique system-wide)`,
        };
      }
    }

    // Resolve lpSymbol → Symbol.id within this tenant.
    const lpCodes = [...new Set(normalized.map((m) => m.lpSymbol))];
    const symbols = lpCodes.length
      ? await prisma.symbol.findMany({
          where: { tenantId, symbol: { in: lpCodes } },
          select: { id: true, symbol: true },
        })
      : [];
    const byLp = new Map(symbols.map((s) => [s.symbol.toUpperCase(), s.id]));

    // Dedupe by lpSymbol (last wins). Client symbols already uniqueness-checked.
    const byKey = new Map<string, (typeof normalized)[0]>();
    for (const m of normalized) byKey.set(m.lpSymbol, m);
    const rows = [...byKey.values()];

    await prisma.$transaction(async (tx) => {
      await tx.tradingGroupSymbolMapping.deleteMany({ where: { tradingGroupId: groupId } });
      for (const m of rows) {
        await tx.tradingGroupSymbolMapping.create({
          data: {
            tradingGroupId: groupId,
            lpSymbol: m.lpSymbol,
            clientSymbol: m.clientSymbol,
            symbolId: byLp.get(m.lpSymbol) ?? null,
            pricingMethod: m.pricingMethod,
            minSpreadPoints: m.minSpreadPoints,
            maxSpreadPoints: m.maxSpreadPoints,
            commissionType: m.commissionType,
            commissionValue: m.commissionValue,
            enabled: m.enabled,
            sortOrder: m.sortOrder,
          },
        });
      }
      // Keep per-symbol allowlist in sync so traders auto-see mapped instruments.
      const symbolIds = rows
        .map((m) => byLp.get(m.lpSymbol))
        .filter((id): id is string => !!id);
      await tx.tradingGroupSymbol.deleteMany({ where: { tradingGroupId: groupId } });
      for (const symbolId of [...new Set(symbolIds)]) {
        await tx.tradingGroupSymbol.create({ data: { tradingGroupId: groupId, symbolId } });
      }
      // Spec: Symbol Mapping is the sole pricing path — clear legacy override rules
      // so markup cannot double-apply via GroupMarkupRule.
      if (rows.length > 0) {
        await tx.groupMarkupRule.deleteMany({ where: { groupId } });
        await tx.tradingGroup.update({
          where: { id: groupId },
          data: { markupPoints: 0 },
        });
      }
    });

    const mappings = await prisma.tradingGroupSymbolMapping.findMany({
      where: { tradingGroupId: groupId },
      include: { symbol: { select: { id: true, symbol: true, class: true } } },
      orderBy: [{ sortOrder: 'asc' }, { lpSymbol: 'asc' }],
    });
    return { ok: true, count: mappings.length, mappings };
  }

  // ── Layered markup/commission rules (per instrument-class or per symbol) ───
  @Put(':id/rules')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Replace a group\'s override rules (class/symbol) — disabled when Symbol Mappings exist' })
  async setRules(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Param('id') id: string,
    @Body() body: { rules: Array<{ instrumentClass?: string | null; symbolId?: string | null; markupPoints?: number; commissionType?: string | null; commissionValue?: number | null }> },
  ) {
    const group = await prisma.tradingGroup.findFirst({
      where: { id, tenantId: t.id },
      select: { id: true, _count: { select: { symbolMappings: true } } },
    });
    if (!group) return { error: 'group not found' };
    if (group._count.symbolMappings > 0) {
      return {
        error:
          'Symbol Mappings are configured — legacy overrides are disabled to prevent double markup. Edit Symbol Mapping instead.',
      };
    }
    await prisma.$transaction([
      prisma.groupMarkupRule.deleteMany({ where: { groupId: id } }),
      ...(body.rules ?? []).map((r) =>
        prisma.groupMarkupRule.create({
          data: {
            groupId: id,
            instrumentClass: (r.symbolId ? null : (r.instrumentClass as any)) ?? null,
            symbolId: r.symbolId ?? null,
            markupPoints: r.markupPoints ?? 0,
            commissionType: (r.commissionType as any) ?? null,
            commissionValue: r.commissionValue ?? null,
          },
        }),
      ),
    ]);
    await this.audit.log(t.id, u.id, 'TENANT_CHANGE', 'tradingGroup', id, { after: { rules: body.rules?.length ?? 0 } });
    return { ok: true };
  }

  // ── Instrument visibility (which symbol groups this client group can see) ──
  @Get(':id/symbol-access')
  @ApiOperation({ summary: "List symbol groups with an `allowed` flag for this trading group" })
  async getSymbolAccess(@CurrentTenant() t: any, @Param('id') id: string) {
    const [group, symbolGroups, access] = await Promise.all([
      prisma.tradingGroup.findFirst({ where: { id, tenantId: t.id }, select: { id: true } }),
      prisma.symbolGroup.findMany({ where: { tenantId: t.id }, select: { id: true, name: true }, orderBy: { name: 'asc' } }),
      prisma.tradingGroupSymbolAccess.findMany({ where: { tradingGroupId: id }, select: { symbolGroupId: true } }),
    ]);
    if (!group) return { error: 'group not found' };
    const allowed = new Set(access.map((a) => a.symbolGroupId));
    return {
      restricted: allowed.size > 0,
      groups: symbolGroups.map((g) => ({ ...g, allowed: allowed.has(g.id) })),
    };
  }

  @Put(':id/symbol-access')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Set which symbol groups this trading group can see (empty = all enabled)' })
  async setSymbolAccess(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Param('id') id: string,
    @Body() body: { symbolGroupIds: string[] },
  ) {
    const group = await prisma.tradingGroup.findFirst({ where: { id, tenantId: t.id }, select: { id: true } });
    if (!group) return { error: 'group not found' };
    const requested = Array.isArray(body.symbolGroupIds) ? [...new Set(body.symbolGroupIds)] : [];
    const valid = requested.length
      ? await prisma.symbolGroup.findMany({ where: { tenantId: t.id, id: { in: requested } }, select: { id: true } })
      : [];
    const validIds = valid.map((v) => v.id);
    await prisma.$transaction([
      prisma.tradingGroupSymbolAccess.deleteMany({ where: { tradingGroupId: id } }),
      ...validIds.map((symbolGroupId) =>
        prisma.tradingGroupSymbolAccess.create({ data: { tradingGroupId: id, symbolGroupId } }),
      ),
    ]);
    await this.audit.log(t.id, u.id, 'TENANT_CHANGE', 'tradingGroup', id, { after: { symbolGroups: validIds.length } });
    return { ok: true, restricted: validIds.length > 0, allowed: validIds };
  }

  // ── Per-symbol instrument access (hand-pick exact symbols) ────────────────
  @Get(':id/symbols')
  @ApiOperation({ summary: 'List all enabled symbols with an `allowed` flag for this trading group' })
  async getSymbolPicks(@CurrentTenant() t: any, @Param('id') id: string) {
    const [group, symbols, picks] = await Promise.all([
      prisma.tradingGroup.findFirst({ where: { id, tenantId: t.id }, select: { id: true } }),
      prisma.symbol.findMany({
        where: { tenantId: t.id, enabled: true },
        select: { id: true, symbol: true, class: true },
        orderBy: [{ class: 'asc' }, { symbol: 'asc' }],
      }),
      prisma.tradingGroupSymbol.findMany({ where: { tradingGroupId: id }, select: { symbolId: true } }),
    ]);
    if (!group) return { error: 'group not found' };
    const allowed = new Set(picks.map((p) => p.symbolId));
    return {
      restricted: allowed.size > 0,
      symbols: symbols.map((s) => ({ id: s.id, symbol: s.symbol, class: s.class, allowed: allowed.has(s.id) })),
    };
  }

  @Put(':id/symbols')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Set the exact symbols this trading group can trade (empty = fall back to buckets/all)' })
  async setSymbolPicks(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Param('id') id: string,
    @Body() body: { symbolIds: string[] },
  ) {
    const group = await prisma.tradingGroup.findFirst({ where: { id, tenantId: t.id }, select: { id: true } });
    if (!group) return { error: 'group not found' };
    const requested = Array.isArray(body.symbolIds) ? [...new Set(body.symbolIds)] : [];
    const valid = requested.length
      ? await prisma.symbol.findMany({ where: { tenantId: t.id, id: { in: requested } }, select: { id: true } })
      : [];
    const validIds = valid.map((v) => v.id);
    await prisma.$transaction([
      prisma.tradingGroupSymbol.deleteMany({ where: { tradingGroupId: id } }),
      ...validIds.map((symbolId) => prisma.tradingGroupSymbol.create({ data: { tradingGroupId: id, symbolId } })),
    ]);
    await this.audit.log(t.id, u.id, 'TENANT_CHANGE', 'tradingGroup', id, { after: { symbols: validIds.length } });
    return { ok: true, restricted: validIds.length > 0, count: validIds.length };
  }

  // ── Assignment ────────────────────────────────────────────────────────────
  @Patch('accounts/:accountId')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: "Assign an account to a trading group (null = none)" })
  async assign(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Param('accountId') accountId: string,
    @Body() body: { groupId: string | null },
  ) {
    if (body.groupId) {
      const g = await prisma.tradingGroup.findFirst({ where: { id: body.groupId, tenantId: t.id }, select: { id: true } });
      if (!g) return { error: 'group not found' };
    }
    await prisma.account.updateMany({ where: { id: accountId, tenantId: t.id }, data: { groupId: body.groupId ?? null } });
    await this.audit.log(t.id, u.id, 'TENANT_CHANGE', 'account', accountId, { after: { groupId: body.groupId } });
    return { ok: true };
  }
}
