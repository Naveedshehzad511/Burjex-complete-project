import { Body, Controller, Delete, Get, Param, Patch, Post, Put, UseGuards } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation } from '@nestjs/swagger';
import Redis from 'ioredis';
import { prisma } from '@btrader/db';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { Roles, CurrentTenant, CurrentUser } from '../../common/decorators';
import { AuditService } from '../audit/audit.service';
import { Channels } from '@btrader/shared';
import {
  MappingInput,
  normalizeMapping,
  syncAllGroupsForPack,
  syncTradingGroupFromPack,
} from '../groups/mapping.util';

const packInclude = {
  items: { orderBy: [{ sortOrder: 'asc' as const }, { lpSymbol: 'asc' as const }] },
  tradingGroups: { select: { id: true, name: true } },
  _count: { select: { items: true, tradingGroups: true } },
};

@ApiTags('symbol-groups')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Roles('TENANT_ADMIN', 'SUPER_ADMIN', 'TENANT_STAFF')
@Controller('admin/symbol-groups')
export class SymbolGroupsController {
  private readonly redis = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6380');

  constructor(private readonly audit: AuditService) {}

  @Get()
  @ApiOperation({ summary: 'List reusable Symbols Groups (alias packs)' })
  list(@CurrentTenant() t: any) {
    return prisma.clientSymbolGroup.findMany({
      where: { tenantId: t.id },
      include: packInclude,
      orderBy: { name: 'asc' },
    });
  }

  @Get(':id')
  @ApiOperation({ summary: 'Get one Symbols Group with items' })
  async getOne(@CurrentTenant() t: any, @Param('id') id: string) {
    const pack = await prisma.clientSymbolGroup.findFirst({
      where: { id, tenantId: t.id },
      include: packInclude,
    });
    return pack ?? { error: 'symbols group not found' };
  }

  @Post()
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Create a Symbols Group (optional items in body)' })
  async create(@CurrentTenant() t: any, @CurrentUser() u: any, @Body() body: any) {
    const name = String(body.name ?? '').trim();
    if (!name) return { error: 'name is required' };
    try {
      const pack = await prisma.clientSymbolGroup.create({
        data: {
          tenantId: t.id,
          name,
          description: body.description ?? null,
          enabled: body.enabled !== false,
        },
      });
      if (Array.isArray(body.items) || Array.isArray(body.symbolMappings)) {
        const result = await this.replaceItems(t.id, pack.id, body.items ?? body.symbolMappings);
        if ((result as any).error) return result;
      }
      await this.audit.log(t.id, u.id, 'CREATE', 'clientSymbolGroup', pack.id, { after: { name } });
      return prisma.clientSymbolGroup.findUnique({ where: { id: pack.id }, include: packInclude });
    } catch (e: any) {
      if (String(e?.code) === 'P2002') return { error: `symbols group "${name}" already exists` };
      throw e;
    }
  }

  @Patch(':id')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Rename / enable a Symbols Group' })
  async update(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string, @Body() body: any) {
    const existing = await prisma.clientSymbolGroup.findFirst({ where: { id, tenantId: t.id }, select: { id: true } });
    if (!existing) return { error: 'symbols group not found' };
    const data: any = {};
    if (body.name !== undefined) data.name = String(body.name).trim();
    if (body.description !== undefined) data.description = body.description;
    if (body.enabled !== undefined) data.enabled = !!body.enabled;
    try {
      await prisma.clientSymbolGroup.update({ where: { id }, data });
    } catch (e: any) {
      if (String(e?.code) === 'P2002') return { error: `symbols group "${data.name}" already exists` };
      throw e;
    }
    if (Array.isArray(body.items) || Array.isArray(body.symbolMappings)) {
      const result = await this.replaceItems(t.id, id, body.items ?? body.symbolMappings);
      if ((result as any).error) return result;
    }
    await this.audit.log(t.id, u.id, 'TENANT_CHANGE', 'clientSymbolGroup', id, { after: data });
    return prisma.clientSymbolGroup.findUnique({ where: { id }, include: packInclude });
  }

  @Delete(':id')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Delete a Symbols Group (attached trading groups lose the pack + mappings)' })
  async remove(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string) {
    const pack = await prisma.clientSymbolGroup.findFirst({
      where: { id, tenantId: t.id },
      select: { id: true, tradingGroups: { select: { id: true } } },
    });
    if (!pack) return { error: 'symbols group not found' };
    const groupIds = pack.tradingGroups.map((g) => g.id);
    for (const gid of groupIds) {
      await syncTradingGroupFromPack(t.id, gid, null);
    }
    await prisma.clientSymbolGroup.delete({ where: { id } });
    await this.audit.log(t.id, u.id, 'DELETE', 'clientSymbolGroup', id);
    this.notifyEngine(t.id, groupIds);
    return { ok: true };
  }

  @Put(':id/items')
  @Roles('TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Replace alias symbols (feed → client + spread/commission) and sync attached trading groups' })
  async setItems(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Param('id') id: string,
    @Body() body: { items?: MappingInput[]; mappings?: MappingInput[] },
  ) {
    const pack = await prisma.clientSymbolGroup.findFirst({ where: { id, tenantId: t.id }, select: { id: true } });
    if (!pack) return { error: 'symbols group not found' };
    const result = await this.replaceItems(t.id, id, body.items ?? body.mappings ?? []);
    if ((result as any).error) return result;
    await this.audit.log(t.id, u.id, 'TENANT_CHANGE', 'clientSymbolGroup', id, {
      after: { items: (result as any).count },
    });
    return result;
  }

  private async replaceItems(tenantId: string, packId: string, raw: MappingInput[]) {
    const normalized = (raw ?? [])
      .map((r, i) => normalizeMapping(r, i))
      .filter((m): m is NonNullable<typeof m> => !!m);

    const clientNames = normalized.map((m) => m.clientSymbol);
    const dupClient = clientNames.filter((n, i) => clientNames.indexOf(n) !== i);
    if (dupClient.length) return { error: `duplicate client symbol: ${dupClient[0]}` };
    const lpNames = normalized.map((m) => m.lpSymbol);
    const dupLp = lpNames.filter((n, i) => lpNames.indexOf(n) !== i);
    if (dupLp.length) return { error: `duplicate feed symbol: ${dupLp[0]}` };

    const lpCodes = [...new Set(normalized.map((m) => m.lpSymbol))];
    const symbols = lpCodes.length
      ? await prisma.symbol.findMany({
          where: { tenantId, symbol: { in: lpCodes } },
          select: { id: true, symbol: true },
        })
      : [];
    const byLp = new Map(symbols.map((s) => [s.symbol.toUpperCase(), s.id]));

    await prisma.$transaction(async (tx) => {
      await tx.clientSymbolGroupItem.deleteMany({ where: { groupId: packId } });
      for (const m of normalized) {
        await tx.clientSymbolGroupItem.create({
          data: {
            groupId: packId,
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
    });

    const synced = await syncAllGroupsForPack(tenantId, packId);
    if ((synced as any).error) return synced;
    this.notifyEngine(tenantId, (synced as { groupIds: string[] }).groupIds ?? []);

    const pack = await prisma.clientSymbolGroup.findUnique({ where: { id: packId }, include: packInclude });
    return { ok: true, count: normalized.length, pack };
  }

  private notifyEngine(tenantId: string, groupIds: string[]) {
    for (const id of groupIds) {
      void this.redis.publish(
        `bt:${Channels.ENGINE_CFG}`,
        JSON.stringify({ type: 'group', id, tenantId }),
      );
    }
  }
}
