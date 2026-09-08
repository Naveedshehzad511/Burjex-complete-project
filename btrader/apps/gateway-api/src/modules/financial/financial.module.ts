import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { FinancialService } from './financial.service';
import { FinancialController } from './financial.controller';
import { AuditModule } from '../audit/audit.module';

@Module({
  imports: [JwtModule.register({}), AuditModule],
  controllers: [FinancialController],
  providers: [FinancialService],
  exports: [FinancialService],
})
export class FinancialModule {}
