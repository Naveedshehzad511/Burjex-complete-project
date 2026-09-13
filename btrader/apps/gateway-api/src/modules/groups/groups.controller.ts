import { Body, Controller, Delete, Get, Param, Patch, Post, Put, UseGuards } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation } from '@nestjs/swagger';
import Redis from 'ioredis';
import { prisma } from '@btrader/db';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { Roles, CurrentTenant, CurrentUser } from '../../common/decorators';
import { AuditService } from '../audit/audit.service';
import { Channels } from '@btrader/shared';
import { MappingInput, replaceMappings, syncTradingGroupFromPack } from './mapping.util';

const EXECUTION_APPLY_KEYS = [
  'marketBuy',
  'marketSell',
  'buyLimit',
  'sellLimit',
  'buyStop',
  'sellStop',
  'sl',
  'tp',
  'manualClose',
  'closeAll',
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

/**
 * Client trading groups (Standard / Raw / ECN / STP …). Assign one Symbols
 * Group (alias pack) — do not add feed symbols here. CRM account types still map
 * to the trading group by name.
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
        clientSymbolGroup: { select: { id: true, name: true, enabled: true } },
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
  @ApiOperation({ summary: 'Create a trading group (assign clientSymbolGroupId — no inline mappings)' })
  async create(@CurrentTenant() t: any, @CurrentUser() u: any, @Body() body: any) {
    const packId = await this.resolvePackId(t.id, body.clientSymbolGroupId);
    if (packId && typeof packId === 'object' && (packId as any).error) return packId;
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
        clientSymbolGroupId: (packId as string | null) ?? null,
      },
    });
    if (g.clientSymbolGroupId) {
      const mapResult = await syncTradingGroupFromPack(t.id, g.id, g.clientSymbolGroupId);
      if ((mapResult as any).error) return mapResult;
    }
    await this.audit.log(t.id, u.id, 'CREATE', 'tradingGroup', g.id, { after: { name: g.name } });
    void this.redis.publish(`bt:${Channels.ENGINE_CFG}`, JSON.stringify({ type: 'group', id: g.id, tenantId: t.id }));
    return prisma.tradingGroup.findUnique({
      where: { id: g.id },
      include: {
        clientSymbolGroup: { select: { id: true, name: true, enabled: true } },
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
    if (body.clientSymbolGroupId !== undefined) {
      const packId = await this.resolvePackId(t.id, body.clientSymbolGroupId);
      if (packId && typeof packId === 'object' && (packId as any).error) return packId;
      data.clientSymbolGroupId = (packId as string | null) ?? null;
    }
    const g = await prisma.tradingGroup.updateMany({ where: { id, tenantId: t.id }, data });
    if (g.count && body.clientSymbolGroupId !== undefined) {
      const mapResult = await syncTradingGroupFromPack(t.id, id, data.clientSymbolGroupId ?? null);
      if ((mapResult as any).error) return mapResult;
    }
    await this.audit.log(t.id, u.id, 'TENANT_CHANGE', 'tradingGroup', id, { after: data });
    void this.redis.publish(`bt:${Channels.ENGINE_CFG}`, JSON.stringify({ type: 'group', id, tenantId: t.id }));
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
    const group = await prisma.tradingGroup.findFirst({
      where: { id, tenantId: t.id },
      select: { id: true, clientSymbolGroupId: true },
    });
    if (!group) return { error: 'group not found' };
    if (group.clientSymbolGroupId) {
      return { error: 'Edit aliases on the assigned Symbols Group, not on the trading group' };
    }
    const result = await replaceMappings(t.id, id, body.mappings ?? []);
    await this.audit.log(t.id, u.id, 'TENANT_CHANGE', 'tradingGroup', id, {
      after: { symbolMappings: (result as any).count },
    });
    return result;
  }

  /** Empty / missing / null → unassign. Invalid id → error object. */
  private async resolvePackId(tenantId: string, raw: unknown): Promise<string | null | { error: string }> {
    if (raw === undefined || raw === null || raw === '') return null;
    const id = String(raw).trim();
    if (!id) return null;
    const pack = await prisma.clientSymbolGroup.findFirst({
      where: { id, tenantId },
      select: { id: true },
    });
    if (!pack) return { error: 'symbols group not found' };
    return pack.id;
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
