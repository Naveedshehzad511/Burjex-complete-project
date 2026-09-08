import { Module } from '@nestjs/common';
import { CrmController } from './crm.controller';
import { CrmService } from './crm.service';
import { CrmKeyGuard } from '../../common/crm.guard';
import { FinancialModule } from '../financial/financial.module';
import { TradingModule } from '../trading/trading.module';

@Module({
  imports: [FinancialModule, TradingModule],
  controllers: [CrmController],
  providers: [CrmService, CrmKeyGuard],
})
export class CrmModule {}
