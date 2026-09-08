import { Injectable } from '@nestjs/common';
import { prisma } from '@btrader/db';

/** Risk-limit CRUD + live net-exposure / margin dashboards. */
@Injectable()
export class RiskService {
  limits(tenantId: string) {
    return prisma.riskLimit.findMany({ where: { tenantId } });
  }

  upsert(tenantId: string, body: any) {
    return prisma.riskLimit.upsert({
      where: { tenantId_scope: { tenantId, scope: body.scope } },
      update: {
        maxLotPerOrder: body.maxLotPerOrder,
        maxOpenLots: body.maxOpenLots,
        maxOpenPositions: body.maxOpenPositions,
        maxNetExposure: body.maxNetExposure,
        maxDailyLossPct: body.maxDailyLossPct,
        enabled: body.enabled ?? true,
      },
      create: {
        tenantId,
        scope: body.scope,
        maxLotPerOrder: body.maxLotPerOrder,
        maxOpenLots: body.maxOpenLots,
        maxOpenPositions: body.maxOpenPositions,
        maxNetExposure: body.maxNetExposure,
        maxDailyLossPct: body.maxDailyLossPct,
        enabled: body.enabled ?? true,
      },
    });
  }

  remove(tenantId: string, scope: string) {
    return prisma.riskLimit.deleteMany({ where: { tenantId, scope } });
  }

  /** Accounts at or near margin call / stop-out. */
  async marginAlerts(tenantId: string) {
    const accts = await prisma.account.findMany({
      where: { tenantId, status: { in: ['ACTIVE', 'TRADING_DISABLED'] }, margin: { gt: 0 } },
      select: { id: true, login: true, marginLevel: true, marginCallLevel: true, stopOutLevel: true, equity: true, margin: true },
    });
    return accts.filter((a) => Number(a.marginLevel) <= a.marginCallLevel);
  }
}
