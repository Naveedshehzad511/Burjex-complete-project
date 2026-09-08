import { Body, Controller, Get, HttpCode, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiSecurity } from '@nestjs/swagger';
import { CrmKeyGuard } from '../../common/crm.guard';
import { CrmAuth, CurrentTenant } from '../../common/decorators';
import { CrmService } from './crm.service';

/**
 * /v1/crm/* — consumed by the Example CRM. Auth = API key + HMAC (CrmKeyGuard).
 * Mirrors the CRM's existing mt5.service method shapes (see CRM_ROUTE_MAP).
 */
@ApiTags('crm-integration')
@ApiSecurity('crm-key')
@UseGuards(CrmKeyGuard)
@Controller('crm')
export class CrmController {
  constructor(private readonly crm: CrmService) {}

  @Get('groups')
  @CrmAuth('crm.read')
  @ApiOperation({ summary: 'List trading groups for CRM Group Management mapping' })
  groups(@CurrentTenant() t: any) {
    return this.crm.listGroups(t.id);
  }

  @Post('accounts')
  @CrmAuth('crm.write')
  @ApiOperation({ summary: 'Create a trading account (CRM provisioning)' })
  create(@CurrentTenant() t: any, @Body() body: any) {
    return this.crm.createAccount(t.id, body);
  }

  @Get('accounts/:login')
  @CrmAuth('crm.read')
  @ApiOperation({ summary: 'Account info: balance/equity/margin/freeMargin/etc.' })
  account(@CurrentTenant() t: any, @Param('login') login: string) {
    return this.crm.getAccount(t.id, login);
  }

  @Post('accounts/batch')
  @HttpCode(200) // read-style POST: return 200 (not Nest's default 201) so CRM
                 // connectors that treat 201 as failure see a clean success.
  @CrmAuth('crm.read')
  @ApiOperation({ summary: 'Batch account info (replaces CRM 30s poll)' })
  batch(@CurrentTenant() t: any, @Body() body: { logins: string[] }) {
    return this.crm.batch(t.id, body.logins ?? []);
  }

  @Get('accounts/:login/positions')
  @CrmAuth('crm.read')
  @ApiOperation({ summary: 'Open positions for an account' })
  positions(@CurrentTenant() t: any, @Param('login') login: string) {
    return this.crm.positions(t.id, login);
  }

  @Get('accounts/:login/deals')
  @CrmAuth('crm.read')
  @ApiOperation({ summary: 'Deal/trade history in a date range' })
  deals(
    @CurrentTenant() t: any,
    @Param('login') login: string,
    @Query('from') from: string,
    @Query('to') to: string,
  ) {
    return this.crm.deals(t.id, login, from, to);
  }

  @Post('accounts/:login/balance')
  @CrmAuth('crm.write', 'balance.adjust')
  @ApiOperation({ summary: 'Deposit/Withdraw/Bonus/Dividend (idempotent via externalRef)' })
  balance(@CurrentTenant() t: any, @Param('login') login: string, @Body() body: any) {
    return this.crm.balanceOp(t.id, login, body);
  }

  @Patch('accounts/:login')
  @CrmAuth('crm.write')
  @ApiOperation({ summary: 'Update leverage / enable-disable trading / status' })
  update(@CurrentTenant() t: any, @Param('login') login: string, @Body() body: any) {
    return this.crm.updateAccount(t.id, login, body);
  }

  @Get('accounts/:login/stats')
  @CrmAuth('crm.read')
  @ApiOperation({ summary: 'Trading statistics for CRM dashboards' })
  stats(@CurrentTenant() t: any, @Param('login') login: string) {
    return this.crm.stats(t.id, login);
  }

  @Post('accounts/:login/password')
  @CrmAuth('crm.write')
  @ApiOperation({ summary: 'Set account password (MAIN or INVESTOR)' })
  password(@CurrentTenant() t: any, @Param('login') login: string, @Body() body: any) {
    return this.crm.changePassword(t.id, login, body.newPassword, body.type ?? 'MAIN');
  }
}
