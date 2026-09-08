import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { MarketController } from './market.controller';
import { CandlesService } from './candles.service';
import { QuotesService } from './quotes.service';

@Module({
  imports: [JwtModule.register({})],
  controllers: [MarketController],
  providers: [CandlesService, QuotesService],
})
export class MarketModule {}
