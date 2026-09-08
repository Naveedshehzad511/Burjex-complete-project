import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { LiquidityController } from './liquidity.controller';
import { AuditModule } from '../audit/audit.module';

/**
 * Liquidity providers (multi-source price feed) + the live spread monitor that
 * reads market-data's per-provider quote cache from Redis.
 */
@Module({
  imports: [JwtModule.register({}), AuditModule],
  controllers: [LiquidityController],
})
export class LiquidityModule {}
