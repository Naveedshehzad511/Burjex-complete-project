import { Controller, Get } from '@nestjs/common';
import { ApiTags, ApiOperation } from '@nestjs/swagger';
import { prisma } from '@btrader/db';
import { CurrentTenant } from '../../common/decorators';

/**
 * Unauthenticated, tenant-scoped endpoints the mobile app needs at launch
 * (before login) to render the correct white-label brand. Tenant is resolved
 * from the request host by TenantMiddleware.
 */
@ApiTags('public')
@Controller('public')
export class PublicController {
  @Get('branding')
  @ApiOperation({ summary: 'Tenant branding for white-label app launch' })
  async branding(@CurrentTenant() t: any) {
    if (!t) return { appName: 'Burjex Prime', primaryColor: '#002D58', accentColor: '#0BB07B' };
    const b = await prisma.tenantBranding.findUnique({ where: { tenantId: t.id } });
    return {
      appName: b?.appName || t.name || 'Burjex Prime',
      logoUrl: b?.logoUrl ?? null,
      primaryColor: b?.primaryColor ?? '#002D58',
      accentColor: b?.accentColor ?? '#0BB07B',
      baseCurrency: t.baseCurrency,
    };
  }
}
