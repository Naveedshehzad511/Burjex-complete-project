import { Injectable, NestMiddleware } from '@nestjs/common';
import { Request, Response, NextFunction } from 'express';
import { prisma } from '@btrader/db';

export interface TenantRequest extends Request {
  tenant?: { id: string; slug: string; status: string; baseCurrency: string };
}

/**
 * Resolves the active tenant for each request, in priority order:
 *   1. X-BT-Tenant header (platform/service callers)
 *   2. Host match against tenant.domain / adminDomain / appDomain
 *      (app./admin./api./client./portal./www. subdomains stripped, mirroring the CRM's resolver)
 *   3. ?tenant=slug query (dev)
 * Result is attached to req.tenant and consumed by guards + services.
 */
@Injectable()
export class TenantMiddleware implements NestMiddleware {
  private cache = new Map<string, any>();

  async use(req: TenantRequest, _res: Response, next: NextFunction) {
    const explicit = req.header('x-bt-tenant');
    const host = (req.header('x-forwarded-host') ?? req.headers.host ?? '').split(':')[0];
    const slugQuery = (req.query.tenant as string) ?? '';

    let tenant: any = null;
    if (explicit) {
      tenant = await this.byKey('id:' + explicit, () =>
        prisma.tenant.findFirst({ where: { OR: [{ id: explicit }, { slug: explicit }] } }),
      );
    }
    if (!tenant && host) {
      const registrable = host.replace(/^(app|admin|api|client|portal|www)\./, '');
      tenant = await this.byKey('host:' + host, () =>
        prisma.tenant.findFirst({
          where: {
            OR: [
              { domain: registrable },
              { adminDomain: host },
              { appDomain: host },
            ],
          },
        }),
      );
    }
    if (!tenant && slugQuery) {
      tenant = await this.byKey('slug:' + slugQuery, () =>
        prisma.tenant.findFirst({ where: { slug: slugQuery } }),
      );
    }

    if (tenant) {
      req.tenant = {
        id: tenant.id,
        slug: tenant.slug,
        status: tenant.status,
        baseCurrency: tenant.baseCurrency,
      };
    }
    next();
  }

  private async byKey(key: string, fn: () => Promise<any>) {
    if (this.cache.has(key)) return this.cache.get(key);
    const v = await fn();
    if (v) {
      this.cache.set(key, v);
      setTimeout(() => this.cache.delete(key), 60_000); // 60s TTL
    }
    return v;
  }
}
