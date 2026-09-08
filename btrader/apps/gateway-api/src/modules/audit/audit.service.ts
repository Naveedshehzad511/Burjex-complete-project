import { Injectable } from '@nestjs/common';
import { prisma } from '@btrader/db';

@Injectable()
export class AuditService {
  /** Append an audit record. Never throws into the caller's path. */
  async log(
    tenantId: string | null,
    actorId: string | null,
    action: string,
    entity?: string,
    entityId?: string,
    extra?: { before?: unknown; after?: unknown; meta?: unknown; ip?: string; actorType?: string },
  ) {
    try {
      await prisma.auditLog.create({
        data: {
          tenantId: tenantId ?? undefined,
          actorId: actorId ?? undefined,
          actorType: extra?.actorType ?? 'user',
          action: action as any,
          entity,
          entityId,
          before: (extra?.before as any) ?? undefined,
          after: (extra?.after as any) ?? undefined,
          meta: (extra?.meta as any) ?? undefined,
          ip: extra?.ip,
        },
      });
    } catch {
      /* swallow — auditing must not break the request */
    }
  }

  list(tenantId: string, filter: { action?: string; entity?: string; take?: number }) {
    return prisma.auditLog.findMany({
      where: {
        tenantId,
        ...(filter.action ? { action: filter.action as any } : {}),
        ...(filter.entity ? { entity: filter.entity } : {}),
      },
      orderBy: { createdAt: 'desc' },
      take: filter.take ?? 200,
    });
  }
}
