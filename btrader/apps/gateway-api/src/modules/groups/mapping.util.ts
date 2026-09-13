import { prisma } from '@btrader/db';

const PRICING_METHODS = new Set(['SPREAD_ONLY', 'COMMISSION_ONLY', 'SPREAD_AND_COMMISSION']);
const COMMISSION_TYPES = new Set(['NONE', 'PER_LOT', 'PER_SIDE', 'ROUND_TURN', 'PERCENT']);

export type MappingInput = {
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

export function normalizeMapping(raw: MappingInput, index: number) {
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
    pricingMethod: pricingMethod as 'SPREAD_ONLY' | 'COMMISSION_ONLY' | 'SPREAD_AND_COMMISSION',
    minSpreadPoints,
    maxSpreadPoints,
    commissionType: commissionType as 'NONE' | 'PER_LOT' | 'PER_SIDE' | 'ROUND_TURN' | 'PERCENT',
    commissionValue: Number(raw.commissionValue) || 0,
    enabled: raw.enabled !== false,
    sortOrder: Number.isFinite(Number(raw.sortOrder)) ? Number(raw.sortOrder) : index,
  };
}

export type NormalizedMapping = NonNullable<ReturnType<typeof normalizeMapping>>;

/**
 * Replace TradingGroupSymbolMapping rows for one trading group.
 * Alias uniqueness is per trading group (the same pack can be assigned to many
 * groups, so XAUUSD.s may exist on Standard and Nano at once).
 */
export async function replaceMappings(tenantId: string, groupId: string, raw: MappingInput[]) {
  const normalized = (raw ?? [])
    .map((r, i) => normalizeMapping(r, i))
    .filter((m): m is NormalizedMapping => !!m);

  const clientNames = normalized.map((m) => m.clientSymbol);
  const dupInPayload = clientNames.filter((n, i) => clientNames.indexOf(n) !== i);
  if (dupInPayload.length) {
    return { error: `duplicate trading symbol in payload: ${dupInPayload[0]}` };
  }

  const lpCodes = [...new Set(normalized.map((m) => m.lpSymbol))];
  const symbols = lpCodes.length
    ? await prisma.symbol.findMany({
        where: { tenantId, symbol: { in: lpCodes } },
        select: { id: true, symbol: true },
      })
    : [];
  const byLp = new Map(symbols.map((s) => [s.symbol.toUpperCase(), s.id]));

  const byKey = new Map<string, NormalizedMapping>();
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
    const symbolIds = rows.map((m) => byLp.get(m.lpSymbol)).filter((id): id is string => !!id);
    await tx.tradingGroupSymbol.deleteMany({ where: { tradingGroupId: groupId } });
    for (const symbolId of [...new Set(symbolIds)]) {
      await tx.tradingGroupSymbol.create({ data: { tradingGroupId: groupId, symbolId } });
    }
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
  return { ok: true as const, count: mappings.length, mappings };
}

/** Copy a Symbols Group pack onto a trading group's runtime mappings (engine path). */
export async function syncTradingGroupFromPack(
  tenantId: string,
  tradingGroupId: string,
  packId: string | null,
) {
  if (!packId) {
    return replaceMappings(tenantId, tradingGroupId, []);
  }
  const items = await prisma.clientSymbolGroupItem.findMany({
    where: { groupId: packId },
    orderBy: [{ sortOrder: 'asc' }, { lpSymbol: 'asc' }],
  });
  return replaceMappings(
    tenantId,
    tradingGroupId,
    items.map((m) => ({
      lpSymbol: m.lpSymbol,
      clientSymbol: m.clientSymbol,
      pricingMethod: m.pricingMethod,
      minSpreadPoints: m.minSpreadPoints,
      maxSpreadPoints: m.maxSpreadPoints,
      commissionType: m.commissionType,
      commissionValue: Number(m.commissionValue),
      enabled: m.enabled,
      sortOrder: m.sortOrder,
    })),
  );
}

export async function syncAllGroupsForPack(tenantId: string, packId: string) {
  const groups = await prisma.tradingGroup.findMany({
    where: { tenantId, clientSymbolGroupId: packId },
    select: { id: true },
  });
  const groupIds: string[] = [];
  for (const g of groups) {
    const result = await syncTradingGroupFromPack(tenantId, g.id, packId);
    if ((result as { error?: string }).error) return result;
    groupIds.push(g.id);
  }
  return { ok: true as const, groupIds };
}
