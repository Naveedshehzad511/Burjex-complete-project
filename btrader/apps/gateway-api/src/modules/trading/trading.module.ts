import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { TradingController } from './trading.controller';
import { EngineProvider } from './engine.provider';
import { AuditModule } from '../audit/audit.module';

@Module({
  imports: [JwtModule.register({}), AuditModule],
  controllers: [TradingController],
  providers: [EngineProvider],
  exports: [EngineProvider],
})
export class TradingModule {}
