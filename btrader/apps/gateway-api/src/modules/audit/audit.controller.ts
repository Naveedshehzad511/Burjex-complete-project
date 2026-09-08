import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation } from '@nestjs/swagger';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { Roles, CurrentTenant } from '../../common/decorators';
import { AuditService } from './audit.service';

@ApiTags('audit')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Roles('SUPER_ADMIN', 'TENANT_ADMIN', 'TENANT_STAFF')
@Controller('audit')
export class AuditController {
  constructor(private readonly audit: AuditService) {}

  @Get()
  @ApiOperation({ summary: 'Query audit logs (tenant-scoped)' })
  list(@CurrentTenant() t: any, @Query('action') action?: string, @Query('entity') entity?: string) {
    return this.audit.list(t.id, { action, entity });
  }
}
