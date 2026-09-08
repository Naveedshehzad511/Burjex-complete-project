import { Body, Controller, Delete, Get, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation } from '@nestjs/swagger';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { Roles, RequirePerm, CurrentTenant, CurrentUser } from '../../common/decorators';
import { AccountsService } from './accounts.service';
import { AuthService } from '../auth/auth.service';
import { AuditService } from '../audit/audit.service';

@ApiTags('accounts')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Roles('SUPER_ADMIN', 'TENANT_ADMIN', 'TENANT_STAFF')
@Controller('accounts')
export class AccountsController {
  constructor(
    private readonly svc: AccountsService,
    private readonly auth: AuthService,
    private readonly audit: AuditService,
  ) {}

  @Get('me') @Roles('TRADER', 'TENANT_STAFF', 'TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: "Current trader's own accounts" })
  me(@CurrentTenant() t: any, @CurrentUser() u: any) { return this.svc.myAccounts(t.id, u.id, u.acct ?? null); }

  @Post('demo') @Roles('TRADER', 'TENANT_STAFF', 'TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: 'Open a self-serve demo account (virtual balance, B-book, real prices)' })
  async createDemo(@CurrentTenant() t: any, @CurrentUser() u: any, @Body() body: any) {
    const a = await this.svc.createDemo(t.id, u.id, body);
    await this.audit.log(t.id, u.id, 'CREATE', 'account', a.id, { after: { demo: true, balance: body.balance } });
    return a;
  }

  @Post(':id/demo-balance') @Roles('TRADER', 'TENANT_STAFF', 'TENANT_ADMIN', 'SUPER_ADMIN')
  @ApiOperation({ summary: "Set a demo account's virtual balance (top-up / reset). Owner + demo only." })
  setDemoBalance(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string, @Body() body: any) {
    return this.svc.setDemoBalance(t.id, u.id, id, body.balance);
  }

  @Get('clients') @ApiOperation({ summary: 'List clients with their accounts' })
  clients(@CurrentTenant() t: any) { return this.svc.listClients(t.id); }

  @Get('all') @ApiOperation({ summary: 'All trading accounts (flat) with owner name + balance/equity/floating P/L' })
  all(@CurrentTenant() t: any) { return this.svc.allAccounts(t.id); }

  @Post('clients') @RequirePerm('clients.create') @ApiOperation({ summary: 'Create a client + account' })
  async createClient(@CurrentTenant() t: any, @CurrentUser() u: any, @Body() body: any) {
    const r = await this.svc.createClient(t.id, body);
    await this.audit.log(t.id, u.id, 'CREATE', 'user', r.user.id, { after: body });
    return r;
  }

  @Patch('clients/:userId/active') @ApiOperation({ summary: 'Enable/disable a client' })
  setActive(@CurrentTenant() t: any, @Param('userId') userId: string, @Body() body: { isActive: boolean }) {
    return this.svc.setClientActive(t.id, userId, body.isActive);
  }

  @Patch(':accountId/trading') @ApiOperation({ summary: 'Enable/disable trading on an account' })
  async setTrading(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('accountId') id: string, @Body() body: { enabled: boolean }) {
    const r = await this.svc.setTrading(t.id, id, body.enabled);
    await this.audit.log(t.id, u.id, 'UPDATE', 'account', id, { after: body });
    return r;
  }

  @Patch(':accountId/leverage') @RequirePerm('leverage.change') @ApiOperation({ summary: 'Change account leverage' })
  async leverage(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('accountId') id: string, @Body() body: { leverage: number }) {
    const r = await this.svc.changeLeverage(t.id, id, body.leverage);
    await this.audit.log(t.id, u.id, 'LEVERAGE_CHANGE', 'account', id, { after: body });
    return r;
  }

  @Patch(':accountId/group') @ApiOperation({ summary: 'Assign an account to a trading group (null to clear)' })
  async setGroup(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('accountId') id: string, @Body() body: { groupId: string | null }) {
    const r = await this.svc.setGroup(t.id, id, body.groupId ?? null);
    await this.audit.log(t.id, u.id, 'UPDATE', 'account', id, { after: { groupId: body.groupId ?? null } });
    return r;
  }

  @Delete(':accountId') @RequirePerm('clients.create') @ApiOperation({ summary: 'Delete an empty account, or archive one with history' })
  async remove(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('accountId') id: string) {
    const r = await this.svc.deleteAccount(t.id, id);
    await this.audit.log(t.id, u.id, r.deleted ? 'DELETE' : 'UPDATE', 'account', id, { meta: r });
    return r;
  }

  @Post(':accountId/password') @RequirePerm('clients.create') @ApiOperation({ summary: 'Set / reset an account trading password' })
  async setPassword(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('accountId') id: string, @Body() body: { password: string }) {
    const r = await this.svc.setAccountPassword(t.id, id, body.password);
    await this.audit.log(t.id, u.id, 'UPDATE', 'account', id, { meta: { action: 'set_password' } });
    return r;
  }

  @Post('clients/:userId/force-logout') @ApiOperation({ summary: 'Force-logout a client' })
  async forceLogout(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('userId') userId: string) {
    const r = await this.auth.forceLogout(userId);
    await this.audit.log(t.id, u.id, 'FORCE_LOGOUT', 'user', userId);
    return r;
  }

  @Get(':accountId') @ApiOperation({ summary: 'Get account detail' })
  account(@CurrentTenant() t: any, @Param('accountId') id: string) { return this.svc.getAccount(t.id, id); }

  @Get('exposure/net') @ApiOperation({ summary: 'Net exposure by symbol/side (risk monitoring)' })
  exposure(@CurrentTenant() t: any) { return this.svc.netExposure(t.id); }

  @Get('positions/all') @ApiOperation({ summary: 'All open positions tenant-wide (?userId to scope)' })
  allPositions(@CurrentTenant() t: any, @Query('userId') userId?: string) {
    return this.svc.allPositions(t.id, userId);
  }
}
