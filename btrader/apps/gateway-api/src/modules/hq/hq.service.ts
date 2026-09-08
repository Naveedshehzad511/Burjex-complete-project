import { Injectable } from '@nestjs/common';
import { prisma } from '@btrader/db';

export interface TenantOverview {
  tenantId: string;
  slug: string;
  name: string;
  status: string;
  clients: number;
  accounts: number;
  balanceSum: string;
  openPositions: number;
  pendingCovers: number;
  dealsToday: number;
  volumeToday: string;
  enabledSymbols: number;
}

export interface ServerOverview {
  generatedAt: string;
  tenants: TenantOverview[];
}

/**
 * Read-only stats for the central HQ dashboard. Everything here is an
 * aggregate over this deployment's own DB — no secrets, no PII beyond counts,
 * and no mutation paths.
 */
@Injectable()
export class HqService {
  async overview(): Promise<ServerOverview> {
    const tenants = await prisma.tenant.findMany({
      where: { status: { not: 'DELETED' } },
      select: { id: true, slug: true, name: true, status: true },
      orderBy: { createdAt: 'asc' },
    });

    const startOfDay = new Date();
    startOfDay.setUTCHours(0, 0, 0, 0);

    const out: TenantOverview[] = [];
    for (const t of tenants) {
      const [clients, accounts, balance, openPositions, pendingCovers, deals, symbols] = await Promise.all([
        prisma.user.count({ where: { tenantId: t.id, role: 'TRADER' } }),
        prisma.account.count({ where: { tenantId: t.id } }),
        prisma.account.aggregate({ where: { tenantId: t.id }, _sum: { balance: true } }),
        prisma.position.count({ where: { tenantId: t.id, status: 'OPEN' } }),
        prisma.hedgeOrder.count({ where: { tenantId: t.id, status: { in: ['PENDING', 'CLOSE_PENDING'] } } }),
        prisma.deal.aggregate({
          where: { tenantId: t.id, createdAt: { gte: startOfDay } },
          _count: { _all: true },
          _sum: { volume: true },
        }),
        prisma.symbol.count({ where: { tenantId: t.id, enabled: true } }),
      ]);

      out.push({
        tenantId: t.id,
        slug: t.slug,
        name: t.name,
        status: t.status,
        clients,
        accounts,
        balanceSum: (balance._sum.balance ?? 0).toString(),
        openPositions,
        pendingCovers,
        dealsToday: deals._count._all,
        volumeToday: (deals._sum.volume ?? 0).toString(),
        enabledSymbols: symbols,
      });
    }

    return { generatedAt: new Date().toISOString(), tenants: out };
  }
}
