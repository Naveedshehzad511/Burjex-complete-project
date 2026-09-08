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
    if (!t) return { appName: 'B-Trader', primaryColor: '#1652F0', accentColor: '#0BB07B' };
    const b = await prisma.tenantBranding.findUnique({ where: { tenantId: t.id } });
    return {
      appName: b?.appName ?? 'B-Trader',
      logoUrl: b?.logoUrl ?? null,
      primaryColor: b?.primaryColor ?? '#1652F0',
      accentColor: b?.accentColor ?? '#0BB07B',
      baseCurrency: t.baseCurrency,
    };
  }
}
