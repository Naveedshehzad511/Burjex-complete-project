import { Body, Controller, Post, UseGuards } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation } from '@nestjs/swagger';
import { IsEnum, IsNumber, IsOptional, IsPositive, IsString } from 'class-validator';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { Roles, RequirePerm, CurrentTenant, CurrentUser } from '../../common/decorators';
import { FinancialService } from './financial.service';
import { AuditService } from '../audit/audit.service';

class AdjustDto {
  @IsString() accountId!: string;
  @IsEnum(['DEPOSIT', 'WITHDRAWAL', 'BONUS', 'DIVIDEND', 'CREDIT', 'MANUAL', 'CORRECTION'])
  type!: any;
  @IsNumber() @IsPositive() amount!: number;
  @IsOptional() @IsString() comment?: string;
}

@ApiTags('financial')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Roles('SUPER_ADMIN', 'TENANT_ADMIN', 'TENANT_STAFF')
@Controller('financial')
export class FinancialController {
  constructor(
    private readonly fin: FinancialService,
    private readonly audit: AuditService,
  ) {}

  @Post('adjust')
  @RequirePerm('balance.adjust')
  @ApiOperation({ summary: 'Admin manual balance op (deposit/withdraw/bonus/dividend/manual)' })
  async adjust(@CurrentTenant() t: any, @CurrentUser() u: any, @Body() dto: AdjustDto) {
    const res = await this.fin.adjust({
      tenantId: t.id,
      accountId: dto.accountId,
      type: dto.type,
      amount: dto.amount,
      comment: dto.comment,
      performedBy: u.id,
    });
    await this.audit.log(t.id, u.id, 'BALANCE_ADJUST', 'account', dto.accountId, { after: { ...dto, ...res } });
    return res;
  }
}
