import { Body, Controller, Delete, Get, Param, Post, Put, UseGuards } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation } from '@nestjs/swagger';
import * as crypto from 'crypto';
import { prisma } from '@btrader/db';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { Roles, CurrentTenant, CurrentUser } from '../../common/decorators';
import { AuditService } from '../audit/audit.service';

/**
 * Per-tenant CRM integration settings (admin). A broker configures THEIR CRM's
 * webhook here and mints the inbound API key their CRM uses to call B-Trader.
 * Each tenant is fully isolated — different companies plug in different CRMs.
 */
@ApiTags('crm-admin')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Roles('TENANT_ADMIN', 'SUPER_ADMIN')
@Controller('admin/crm')
export class CrmAdminController {
  constructor(private readonly audit: AuditService) {}

  // ── Outbound webhook config ─────────────────────────────────────────────
  @Get('config')
  @ApiOperation({ summary: 'Get this tenant CRM webhook config' })
  async getConfig(@CurrentTenant() t: any) {
    const c = await prisma.crmConfig.findUnique({ where: { tenantId: t.id } });
    return {
      webhookUrl: c?.webhookUrl ?? null,
      hasSecret: !!c?.webhookSecret,
      enabled: c?.enabled ?? false,
      events: c?.events ?? [],
    };
  }

  @Put('config')
  @ApiOperation({ summary: 'Set CRM webhook URL/secret/enabled (per tenant)' })
  async setConfig(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Body() body: { webhookUrl?: string | null; webhookSecret?: string | null; enabled?: boolean; events?: string[] },
  ) {
    const data = {
      webhookUrl: body.webhookUrl ?? null,
      // Only overwrite the secret if a new one is sent (lets the UI hide it).
      ...(body.webhookSecret ? { webhookSecret: body.webhookSecret } : {}),
      enabled: body.enabled ?? false,
      events: body.events ?? [],
    };
    await prisma.crmConfig.upsert({
      where: { tenantId: t.id },
      create: { tenantId: t.id, webhookSecret: body.webhookSecret ?? null, ...data },
      update: data,
    });
    await this.audit.log(t.id, u.id, 'TENANT_CHANGE', 'crmConfig', t.id, { after: { webhookUrl: data.webhookUrl, enabled: data.enabled } });
    return { ok: true };
  }

  // ── Inbound API keys (CRM → B-Trader) ───────────────────────────────────
  @Get('keys')
  @ApiOperation({ summary: 'List this tenant inbound API keys (no secrets)' })
  async listKeys(@CurrentTenant() t: any) {
    const keys = await prisma.apiKey.findMany({
      where: { tenantId: t.id },
      select: { id: true, name: true, keyId: true, scopes: true, ipAllowlist: true, lastUsedAt: true, revokedAt: true, createdAt: true },
      orderBy: { createdAt: 'desc' },
    });
    return keys;
  }

  @Post('keys')
  @ApiOperation({ summary: 'Create an inbound API key — returns the secret ONCE' })
  async createKey(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Body() body: { name?: string; scopes?: string[]; ipAllowlist?: string[] },
  ) {
    const keyId = 'bt_' + crypto.randomBytes(9).toString('hex');
    const secret = crypto.randomBytes(24).toString('hex');
    const secretHash = crypto.createHash('sha256').update(secret).digest('hex');
    await prisma.apiKey.create({
      data: {
        tenantId: t.id,
        name: body.name ?? 'CRM key',
        keyId,
        secret, // raw secret needed for HMAC verify; encrypt at rest in prod
        secretHash,
        scopes: body.scopes ?? ['crm.read', 'crm.write', 'balance.adjust'],
        ipAllowlist: body.ipAllowlist ?? [],
      },
    });
    await this.audit.log(t.id, u.id, 'CREATE', 'apiKey', keyId, { after: { name: body.name } });
    // Secret is shown only here — the CRM stores it; B-Trader never returns it again.
    return { keyId, secret, scopes: body.scopes ?? ['crm.read', 'crm.write', 'balance.adjust'] };
  }

  @Delete('keys/:keyId')
  @ApiOperation({ summary: 'Revoke an inbound API key' })
  async revokeKey(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('keyId') keyId: string) {
    await prisma.apiKey.updateMany({ where: { keyId, tenantId: t.id }, data: { revokedAt: new Date() } });
    await this.audit.log(t.id, u.id, 'DELETE', 'apiKey', keyId);
    return { ok: true };
  }
}
