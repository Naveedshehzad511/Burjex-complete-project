import { Injectable } from '@nestjs/common';
import { prisma } from '@btrader/db';

/** Symbol management — full contract spec, admin-driven (no hardcoded instruments). */
@Injectable()
export class SymbolsService {
  /**
   * List symbols for a tenant.
   *
   * When `accountId` is supplied (trader app), the result is restricted to the
   * trading group's Symbol Mappings / instrument picks / symbol-group access.
   * Each row is enriched with `displaySymbol` (client name) and per-mapping
   * pricing fields so Quotes can apply min/max spread without a second round-trip.
   */
  async list(tenantId: string, onlyEnabled = false, accountId?: string, requireUserId?: string) {
    const where: any = { tenantId, ...(onlyEnabled ? { enabled: true } : {}) };

    type MappingRow = {
      symbolId: string | null;
      lpSymbol: string;
      clientSymbol: string;
      pricingMethod: string;
      minSpreadPoints: number;
      maxSpreadPoints: number;
      commissionType: string;
      commissionValue: unknown;
      enabled: boolean;
    };
    type TgWithRules = NonNullable<
      Awaited<ReturnType<typeof prisma.tradingGroup.findUnique>>
    > & {
      rules: Array<{
        symbolId: string | null;
        instrumentClass: string | null;
        markupPoints: unknown;
        commissionType: string | null;
        commissionValue: unknown;
      }>;
      symbolMappings: MappingRow[];
    };
    let tradingGroup: TgWithRules | null = null;

    if (accountId) {
      const account = await prisma.account.findFirst({
        where: { id: accountId, tenantId, ...(requireUserId ? { userId: requireUserId } : {}) },
        select: { groupId: true },
      });
      if (account?.groupId) {
        tradingGroup = (await prisma.tradingGroup.findUnique({
          where: { id: account.groupId },
          include: { rules: true, symbolMappings: true },
        })) as TgWithRules | null;

        // Precedence: Symbol Mappings > per-symbol picks > symbol-group buckets.
        const enabledMaps = (tradingGroup?.symbolMappings ?? []).filter((m) => m.enabled);
        if (enabledMaps.length > 0) {
          const ids = enabledMaps.map((m) => m.symbolId).filter((id): id is string => !!id);
          // Also resolve by lpSymbol when symbolId was null at save time.
          const unresolved = enabledMaps.filter((m) => !m.symbolId).map((m) => m.lpSymbol);
          if (unresolved.length) {
            const found = await prisma.symbol.findMany({
              where: { tenantId, symbol: { in: unresolved } },
              select: { id: true },
            });
            for (const f of found) ids.push(f.id);
          }
          where.id = { in: [...new Set(ids)] };
        } else {
          const picks = await prisma.tradingGroupSymbol.findMany({
            where: { tradingGroupId: account.groupId },
            select: { symbolId: true },
          });
          if (picks.length > 0) {
            where.id = { in: picks.map((p) => p.symbolId) };
          } else {
            const access = await prisma.tradingGroupSymbolAccess.findMany({
              where: { tradingGroupId: account.groupId },
              select: { symbolGroupId: true },
            });
            if (access.length > 0) {
              where.groupId = { in: access.map((a) => a.symbolGroupId) };
            } else {
              // Group exists but no instruments / mappings yet → empty book.
              where.id = { in: [] };
            }
          }
        }
      }
    }

    const rows = await prisma.symbol.findMany({
      where,
      include: { group: true },
      orderBy: [{ sortOrder: 'asc' }, { symbol: 'asc' }],
    });

    if (!tradingGroup) return rows;

    const sfx = tradingGroup.clientSymbolSuffix?.trim() || '';
    const groupMarkup = Number(tradingGroup.markupPoints ?? 0);
    const mapsBySymbolId = new Map<string, MappingRow>();
    const mapsByLp = new Map<string, MappingRow>();
    for (const m of tradingGroup.symbolMappings ?? []) {
      if (!m.enabled) continue;
      if (m.symbolId) mapsBySymbolId.set(m.symbolId, m);
      mapsByLp.set(m.lpSymbol.toUpperCase(), m);
    }

    return rows.map((s) => {
      const mapping = mapsBySymbolId.get(s.id) ?? mapsByLp.get(s.symbol.toUpperCase()) ?? null;
      const symRule = tradingGroup!.rules.find((r) => r.symbolId === s.id);
      const classRule = tradingGroup!.rules.find(
        (r) => r.symbolId == null && r.instrumentClass === s.class,
      );
      const legacyMarkup = Number(
        symRule?.markupPoints ?? classRule?.markupPoints ?? groupMarkup,
      );

      const displaySymbol = mapping?.clientSymbol
        ? mapping.clientSymbol
        : sfx
          ? `${s.symbol}${sfx}`
          : s.symbol;

      const pricingMethod = mapping?.pricingMethod ?? null;
      const minSpreadPoints = mapping?.minSpreadPoints ?? 0;
      const maxSpreadPoints = mapping?.maxSpreadPoints ?? 0;
      // Mapping owns pricing — never seed legacy group/rule markup alongside it.
      let markupPoints = 0;
      if (!mapping) {
        markupPoints = legacyMarkup;
      } else if (pricingMethod === 'COMMISSION_ONLY') {
        markupPoints = 0;
      } else if (minSpreadPoints === 0 && maxSpreadPoints === 0) {
        markupPoints = 0;
      }
      // else: client applies live Spread Markup band from min/max

      return {
        ...s,
        displaySymbol,
        markupPoints,
        pricingMethod,
        minSpreadPoints,
        maxSpreadPoints,
        commissionType:
          pricingMethod === 'SPREAD_ONLY'
            ? 'NONE'
            : mapping?.commissionType ?? tradingGroup!.commissionType,
        commissionValue:
          pricingMethod === 'SPREAD_ONLY'
            ? 0
            : Number(mapping?.commissionValue ?? tradingGroup!.commissionValue ?? 0),
        lpSymbol: mapping?.lpSymbol ?? s.symbol,
        clientSymbol: displaySymbol,
      };
    });
  }

  create(tenantId: string, body: any) {
    return prisma.symbol.create({
      data: {
        tenantId,
        groupId: body.groupId,
        symbol: body.symbol,
        description: body.description,
        class: body.class ?? 'FOREX',
        baseCurrency: body.baseCurrency,
        quoteCurrency: body.quoteCurrency,
        digits: body.digits ?? 5,
        pipSize: body.pipSize ?? 0.0001,
        contractSize: body.contractSize ?? 100000,
        minLot: body.minLot ?? 0.01,
        maxLot: body.maxLot ?? 100,
        lotStep: body.lotStep ?? 0.01,
        marginCurrency: body.marginCurrency ?? 'USD',
        marginRate: body.marginRate ?? 1,
        // #14: optional per-symbol margin % (crypto/metals); null = leverage-based.
        marginPercent: body.marginPercent ?? null,
        leverageCap: body.leverageCap,
        slippagePoints: body.slippagePoints ?? 0,
        spreadMarkup: body.spreadMarkup ?? 0,
        stopsLevel: body.stopsLevel ?? 0,
        swapType: body.swapType ?? 'POINTS',
        swapLong: body.swapLong ?? 0,
        swapShort: body.swapShort ?? 0,
        tradingSessions: body.tradingSessions ?? undefined,
        enabled: body.enabled ?? true,
      },
    });
  }

  update(tenantId: string, id: string, body: any) {
    return prisma.symbol.updateMany({ where: { tenantId, id }, data: body });
  }

  setEnabled(tenantId: string, id: string, enabled: boolean) {
    return prisma.symbol.updateMany({ where: { tenantId, id }, data: { enabled } });
  }

  remove(tenantId: string, id: string) {
    return prisma.symbol.deleteMany({ where: { tenantId, id } });
  }

  groups(tenantId: string) {
    return prisma.symbolGroup.findMany({ where: { tenantId } });
  }
  createGroup(tenantId: string, body: any) {
    return prisma.symbolGroup.create({
      data: { tenantId, name: body.name, markupBid: body.markupBid ?? 0, markupAsk: body.markupAsk ?? 0 },
    });
  }
}
