import { Injectable } from '@nestjs/common';
import { prisma } from '@btrader/db';

/** Super-admin tenant lifecycle: create / suspend / delete + branding. */
@Injectable()
export class TenantsService {
  list() {
    return prisma.tenant.findMany({ include: { branding: true }, orderBy: { createdAt: 'desc' } });
  }

  async create(body: any) {
    return prisma.tenant.create({
      data: {
        name: body.name,
        slug: body.slug,
        domain: body.domain,
        adminDomain: body.adminDomain,
        appDomain: body.appDomain,
        baseCurrency: body.baseCurrency ?? 'USD',
        status: 'ACTIVE',
        branding: {
          create: {
            appName: body.appName ?? body.name,
            logoUrl: body.logoUrl,
            primaryColor: body.primaryColor ?? '#1652F0',
            accentColor: body.accentColor ?? '#0BB07B',
            iosBundleId: body.iosBundleId,
            androidPackage: body.androidPackage,
          },
        },
      },
      include: { branding: true },
    });
  }

  updateBranding(id: string, body: any) {
    return prisma.tenantBranding.update({ where: { tenantId: id }, data: body });
  }

  suspend(id: string, reason?: string) {
    return prisma.tenant.update({
      where: { id },
      data: { status: 'SUSPENDED', suspendedAt: new Date(), suspendReason: reason },
    });
  }

  activate(id: string) {
    return prisma.tenant.update({ where: { id }, data: { status: 'ACTIVE', suspendedAt: null } });
  }

  remove(id: string) {
    return prisma.tenant.update({ where: { id }, data: { status: 'DELETED', deletedAt: new Date() } });
  }
}
