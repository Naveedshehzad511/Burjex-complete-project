import { Body, Controller, Delete, Get, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation } from '@nestjs/swagger';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { Roles, CurrentTenant, CurrentUser } from '../../common/decorators';
import { SymbolsService } from './symbols.service';
import { AuditService } from '../audit/audit.service';
import { prisma } from '@btrader/db';

@ApiTags('symbols')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Controller('symbols')
export class SymbolsController {
  constructor(private readonly svc: SymbolsService, private readonly audit: AuditService) {}

  // Traders read enabled symbols; admins read all. When the client app passes
  // ?accountId, the list is filtered to the instruments that account's trading
  // group is allowed to see. Traders may only scope by their own accounts.
  @Get() @ApiOperation({ summary: 'List symbols (?enabled=true and ?accountId=<id> for client app)' })
  list(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Query('enabled') enabled?: string,
    @Query('accountId') accountId?: string,
  ) {
    const isAdmin = u?.role === 'SUPER_ADMIN' || u?.role === 'TENANT_ADMIN' || u?.role === 'TENANT_STAFF';
    const requireUserId = isAdmin ? undefined : u?.id;
    return this.svc.list(t.id, enabled === 'true', accountId, requireUserId);
  }

  @Post() @Roles('SUPER_ADMIN', 'TENANT_ADMIN') @ApiOperation({ summary: 'Add a symbol with full contract spec' })
  async create(@CurrentTenant() t: any, @CurrentUser() u: any, @Body() body: any) {
    const s = await this.svc.create(t.id, body);
    await this.audit.log(t.id, u.id, 'SYMBOL_CHANGE', 'symbol', s.id, { after: body });
    return s;
  }

  @Patch(':id') @Roles('SUPER_ADMIN', 'TENANT_ADMIN') @ApiOperation({ summary: 'Update contract size/margin/swap/sessions/lots/slippage' })
  async update(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string, @Body() body: any) {
    const r = await this.svc.update(t.id, id, body);
    await this.audit.log(t.id, u.id, 'SYMBOL_CHANGE', 'symbol', id, { after: body });
    return r;
  }

  @Patch(':id/enabled') @Roles('SUPER_ADMIN', 'TENANT_ADMIN') @ApiOperation({ summary: 'Enable/disable a symbol' })
  setEnabled(@CurrentTenant() t: any, @Param('id') id: string, @Body() body: { enabled: boolean }) {
    return this.svc.setEnabled(t.id, id, body.enabled);
  }

  @Delete(':id') @Roles('SUPER_ADMIN', 'TENANT_ADMIN') @ApiOperation({ summary: 'Remove a symbol' })
  remove(@CurrentTenant() t: any, @Param('id') id: string) { return this.svc.remove(t.id, id); }

  @Post('sync-now') @Roles('SUPER_ADMIN', 'TENANT_ADMIN') @ApiOperation({ summary: 'Ask the MT5 bridge to reconcile symbols/groups immediately' })
  async syncNow(@CurrentTenant() t: any) {
    const now = new Date();
    await prisma.tenant.update({ where: { id: t.id }, data: { bridgeSyncRequestedAt: now } });
    return { ok: true, requestedAt: now.toISOString() };
  }

  @Get('groups/all') @ApiOperation({ summary: 'List symbol groups' })
  groups(@CurrentTenant() t: any) { return this.svc.groups(t.id); }

  @Post('groups') @Roles('SUPER_ADMIN', 'TENANT_ADMIN') @ApiOperation({ summary: 'Create a symbol group (markup bucket)' })
  createGroup(@CurrentTenant() t: any, @Body() body: any) { return this.svc.createGroup(t.id, body); }
}
