import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { MarketController } from './market.controller';
import { CandlesService } from './candles.service';
import { QuotesService } from './quotes.service';
import { MoversService } from './movers.service';
import { SymbolsModule } from '../symbols/symbols.module';

@Module({
  imports: [JwtModule.register({}), SymbolsModule],
  controllers: [MarketController],
  providers: [CandlesService, QuotesService, MoversService],
})
export class MarketModule {}
