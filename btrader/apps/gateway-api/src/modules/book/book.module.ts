import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { BookController } from './book.controller';
import { TradingModule } from '../trading/trading.module';
import { AuditModule } from '../audit/audit.module';

/**
 * Dealing-desk / A-B book management. Reuses the TradingModule's EngineProvider
 * (which owns the LP router + price cache) so exposure and LP reloads share one
 * engine instance.
 */
@Module({
  imports: [JwtModule.register({}), TradingModule, AuditModule],
  controllers: [BookController],
})
export class BookModule {}
