import { Body, Controller, Delete, Get, Param, Post, UseGuards } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation } from '@nestjs/swagger';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { Roles, CurrentTenant } from '../../common/decorators';
import { RiskService } from './risk.service';

@ApiTags('risk')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Roles('SUPER_ADMIN', 'TENANT_ADMIN')
@Controller('risk')
export class RiskController {
  constructor(private readonly svc: RiskService) {}

  @Get('limits') @ApiOperation({ summary: 'List risk limits' })
  limits(@CurrentTenant() t: any) { return this.svc.limits(t.id); }

  @Post('limits') @ApiOperation({ summary: 'Create/update a risk limit (scope: tenant|account:<id>|symbol:<id>)' })
  upsert(@CurrentTenant() t: any, @Body() body: any) { return this.svc.upsert(t.id, body); }

  @Delete('limits/:scope') @ApiOperation({ summary: 'Remove a risk limit' })
  remove(@CurrentTenant() t: any, @Param('scope') scope: string) { return this.svc.remove(t.id, scope); }

  @Get('margin-alerts') @ApiOperation({ summary: 'Accounts at/near margin call' })
  alerts(@CurrentTenant() t: any) { return this.svc.marginAlerts(t.id); }
}
