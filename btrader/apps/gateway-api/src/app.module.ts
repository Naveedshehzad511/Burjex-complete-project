import { Module, MiddlewareConsumer, NestModule } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { ThrottlerModule, ThrottlerGuard } from '@nestjs/throttler';
import { APP_GUARD } from '@nestjs/core';
import { TenantMiddleware } from './common/tenant.middleware';
import { PrismaService } from './common/prisma.service';
import { HealthController } from './common/health.controller';
import { AuthModule } from './modules/auth/auth.module';
import { TenantsModule } from './modules/tenants/tenants.module';
import { AccountsModule } from './modules/accounts/accounts.module';
import { SymbolsModule } from './modules/symbols/symbols.module';
import { TradingModule } from './modules/trading/trading.module';
import { FinancialModule } from './modules/financial/financial.module';
import { CrmModule } from './modules/crm/crm.module';
import { CrmAdminModule } from './modules/crm-admin/crm-admin.module';
import { RiskModule } from './modules/risk/risk.module';
import { AuditModule } from './modules/audit/audit.module';
import { PublicModule } from './modules/public/public.module';
import { MarketModule } from './modules/market/market.module';
import { BookModule } from './modules/book/book.module';
import { GroupsModule } from './modules/groups/groups.module';
import { BridgeModule } from './modules/bridge/bridge.module';
import { LiquidityModule } from './modules/liquidity/liquidity.module';
import { HqModule } from './modules/hq/hq.module';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    // Global API rate limiting (per-IP). Override per-route as needed.
    ThrottlerModule.forRoot([{ ttl: 60_000, limit: 300 }]),
    AuthModule,
    TenantsModule,
    AccountsModule,
    SymbolsModule,
    TradingModule,
    FinancialModule,
    CrmModule,
    CrmAdminModule,
    RiskModule,
    AuditModule,
    PublicModule,
    MarketModule,
    BookModule,
    GroupsModule,
    BridgeModule,
    LiquidityModule,
    HqModule,
  ],
  controllers: [HealthController],
  providers: [
    PrismaService,
    { provide: APP_GUARD, useClass: ThrottlerGuard },
  ],
  exports: [PrismaService],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer) {
    // Resolve tenant from host/header on every request before guards run.
    consumer.apply(TenantMiddleware).forRoutes('*');
  }
}
