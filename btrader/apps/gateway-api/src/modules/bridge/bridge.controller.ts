import { Body, Controller, Get, Param, Post, Query, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation } from '@nestjs/swagger';
import { prisma, Prisma } from '@btrader/db';
import { BridgeGuard } from '../../common/bridge.guard';
import { CurrentTenant } from '../../common/decorators';

const CLASSES = ['FOREX', 'METALS', 'STOCKS', 'INDICES', 'CRYPTO', 'COMMODITIES', 'CUSTOM'] as const;
type Cls = (typeof CLASSES)[number];

/**
 * Endpoints the MT5 Manager bridge calls. Auth: X-Bridge-Token + X-BT-Tenant
 * (see BridgeGuard). Three jobs:
 *   1. Symbol auto-sync   — upsert MT5 symbols (new pairs created disabled).
 *   2. Group reconcile    — create B-Trader trading groups missing vs MT5.
 *   3. A-book covers       — hand pending hedges to the bridge + record fills.
 */
@ApiTags('bridge')
@UseGuards(BridgeGuard)
@Controller('bridge')
export class BridgeController {
  // ── 1. SYMBOL AUTO-SYNC ────────────────────────────────────────────────────
  @Post('symbols/reconcile')
  @ApiOperation({ summary: 'Upsert MT5 symbols. New pairs created disabled unless their class is in enabledClasses.' })
  async reconcileSymbols(
    @CurrentTenant() t: any,
    @Body() body: { symbols: any[]; enabledClasses?: string[]; updateSpecs?: boolean },
  ) {
    const enabledClasses = new Set((body.enabledClasses ?? []).map((c) => String(c).toUpperCase()));
    const updateSpecs = body.updateSpecs !== false; // default: keep specs fresh
    const groupCache = new Map<string, string>(); // groupName -> id
    let created = 0;
    let updated = 0;
    let skipped = 0;

    for (const raw of body.symbols ?? []) {
      const symbol = String(raw.symbol ?? '').trim().toUpperCase();
      if (!symbol) continue;
      const cls: Cls = (CLASSES as readonly string[]).includes(String(raw.class).toUpperCase())
        ? (String(raw.class).toUpperCase() as Cls)
        : 'CUSTOM';

      // Ensure the class symbol-group bucket exists (cache within this call).
      let groupId: string | undefined;
      const groupName = String(raw.groupName ?? '').trim();
      if (groupName) {
        groupId = groupCache.get(groupName);
        if (!groupId) {
          const g = await prisma.symbolGroup.upsert({
            where: { tenantId_name: { tenantId: t.id, name: groupName } },
            update: {},
            create: { tenantId: t.id, name: groupName },
            select: { id: true },
          });
          groupId = g.id;
          groupCache.set(groupName, groupId);
        }
      }

      const existing = await prisma.symbol.findUnique({
        where: { tenantId_symbol: { tenantId: t.id, symbol } },
        select: { id: true },
      });

      if (!existing) {
        await prisma.symbol.create({
          data: {
            tenantId: t.id,
            symbol,
            description: raw.description ?? symbol,
            class: cls as any,
            baseCurrency: raw.baseCurrency ?? symbol.slice(0, 3),
            quoteCurrency: raw.quoteCurrency ?? 'USD',
            digits: raw.digits ?? 5,
            pipSize: raw.pipSize ?? 0.0001,
            contractSize: raw.contractSize ?? (cls === 'FOREX' ? 100000 : 1),
            minLot: raw.minLot ?? 0.01,
            maxLot: raw.maxLot ?? 100,
            lotStep: raw.lotStep ?? 0.01,
            marginCurrency: raw.marginCurrency ?? 'USD',
            slippagePoints: 0,
            enabled: enabledClasses.has(cls), // hidden unless the class is opted-in
            groupId: groupId ?? null,
          },
        });
        created++;
      } else if (updateSpecs) {
        // Refresh contract specs but NEVER flip `enabled` — that's the admin's call.
        await prisma.symbol.update({
          where: { id: existing.id },
          data: {
            class: cls as any,
            digits: raw.digits ?? undefined,
            pipSize: raw.pipSize ?? undefined,
            contractSize: raw.contractSize ?? undefined,
            minLot: raw.minLot ?? undefined,
            maxLot: raw.maxLot ?? undefined,
            lotStep: raw.lotStep ?? undefined,
            marginCurrency: raw.marginCurrency ?? undefined,
            ...(groupId ? { groupId } : {}),
          },
        });
        updated++;
      } else {
        skipped++;
      }
    }
    return { ok: true, created, updated, skipped };
  }

  @Get('sync-requested')
  @ApiOperation({ summary: 'Latest admin "sync now" request time (bridge polls this to reconcile on demand).' })
  async syncRequested(@CurrentTenant() t: any) {
    const tenant = await prisma.tenant.findUnique({
      where: { id: t.id },
      select: { bridgeSyncRequestedAt: true },
    });
    return { requestedAt: tenant?.bridgeSyncRequestedAt?.toISOString() ?? null };
  }

  // ── 2. GROUP RECONCILE ─────────────────────────────────────────────────────
  @Post('groups/reconcile')
  @ApiOperation({ summary: 'Create B-Trader trading groups for any MT5 group names that are missing.' })
  async reconcileGroups(@CurrentTenant() t: any, @Body() body: { groups: string[] }) {
    const names = [...new Set((body.groups ?? []).map((g) => String(g).trim()).filter(Boolean))];
    const existing = await prisma.tradingGroup.findMany({
      where: { tenantId: t.id, name: { in: names } },
      select: { name: true },
    });
    const have = new Set(existing.map((g) => g.name));
    const toCreate = names.filter((n) => !have.has(n));
    for (const name of toCreate) {
      await prisma.tradingGroup.create({ data: { tenantId: t.id, name } });
    }
    return { ok: true, created: toCreate, existing: [...have] };
  }

  // ── 3. A-BOOK COVERS ───────────────────────────────────────────────────────
  @Get('hedges/pending')
  @ApiOperation({ summary: 'Pending MT5 covers for the bridge: opens (PENDING) and closes (CLOSE_PENDING).' })
  async pendingHedges(@CurrentTenant() t: any, @Query('limit') limit?: string, @Query('provider') provider?: string) {
    const take = Math.min(Math.max(parseInt(limit ?? '200', 10) || 200, 1), 1000);
    // Per-provider scoping (Phase 3 multi-MT5): a bridge passes ?provider=<code>
    // and only sees that provider's covers. No provider param = legacy behaviour
    // (covers with NO provider, i.e. the single-bridge path) so the existing
    // bridge keeps working untouched while per-LP bridges roll out.
    const code = (provider ?? '').trim();
    let providerFilter: Prisma.HedgeOrderWhereInput;
    if (code) {
      const prov = await prisma.liquidityProvider.findFirst({
        where: { tenantId: t.id, code }, select: { id: true },
      });
      // Unknown code → match nothing (don't fall through to legacy/global covers).
      providerFilter = { lpProviderId: prov ? prov.id : '__none__' };
    } else {
      providerFilter = { lpProviderId: null };
    }
    const base = { tenantId: t.id, driver: 'MT5' as const, ...providerFilter };
    const [opens, closes] = await Promise.all([
      prisma.hedgeOrder.findMany({
        where: { ...base, status: 'PENDING' },
        orderBy: { openedAt: 'asc' },
        take,
        select: { id: true, symbolName: true, side: true, volume: true, requestPrice: true, positionId: true },
      }),
      prisma.hedgeOrder.findMany({
        where: { ...base, status: 'CLOSE_PENDING' },
        orderBy: { updatedAt: 'asc' },
        take,
        select: { id: true, symbolName: true, side: true, volume: true, externalRef: true, positionId: true },
      }),
    ]);
    return { opens, closes };
  }

  @Post('hedges/:id/fill')
  @ApiOperation({ summary: 'Bridge confirms a cover filled on MT5.' })
  async fillHedge(
    @CurrentTenant() t: any,
    @Param('id') id: string,
    @Body() body: { fillPrice: number; externalRef?: string },
  ) {
    const h = await prisma.hedgeOrder.findFirst({ where: { id, tenantId: t.id, driver: 'MT5' } });
    if (!h) return { error: 'hedge not found' };
    const fill = Number(body.fillPrice);
    const req = h.requestPrice ? Number(h.requestPrice) : fill;
    await prisma.hedgeOrder.update({
      where: { id },
      data: {
        status: 'FILLED',
        fillPrice: fill,
        externalRef: body.externalRef ?? null,
        slippage: fill - req,
      },
    });
    return { ok: true };
  }

  @Post('hedges/:id/reject')
  @ApiOperation({ summary: 'Bridge reports a cover was rejected on MT5 (broker now exposed).' })
  async rejectHedge(@CurrentTenant() t: any, @Param('id') id: string, @Body() body: { reason?: string }) {
    const h = await prisma.hedgeOrder.findFirst({ where: { id, tenantId: t.id, driver: 'MT5' } });
    if (!h) return { error: 'hedge not found' };
    await prisma.hedgeOrder.update({
      where: { id },
      data: { status: 'REJECTED', rejectReason: body.reason ?? 'mt5 rejected' },
    });
    return { ok: true };
  }

  @Post('hedges/:id/closed')
  @ApiOperation({ summary: 'Bridge confirms a cover was closed on MT5.' })
  async closedHedge(@CurrentTenant() t: any, @Param('id') id: string, @Body() body: { closePrice: number }) {
    const h = await prisma.hedgeOrder.findFirst({ where: { id, tenantId: t.id, driver: 'MT5' } });
    if (!h) return { error: 'hedge not found' };
    await prisma.hedgeOrder.update({
      where: { id },
      data: { status: 'CLOSED', closePrice: Number(body.closePrice), closedAt: new Date() },
    });
    return { ok: true };
  }
}
