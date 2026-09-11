import { Controller, Get, Query, UseGuards, BadRequestException } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation, ApiQuery } from '@nestjs/swagger';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { CurrentTenant } from '../../common/decorators';
import { CandlesService } from './candles.service';
import { QuotesService } from './quotes.service';
import { Timeframe } from './feed.types';

/**
 * Market data for charts. Internal provider serves MT5 Manager ChartRequest
 * OHLC (bridge → ingest). Closed bars are ChartRequest-only. Client may extend
 * the forming tip with Bid ticks only when they stay on the ChartRequest price
 * level; otherwise tip catch-up is another ChartRequest soft-refresh.
 */
@ApiTags('market')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Controller('market')
export class MarketController {
  constructor(
    private readonly candles: CandlesService,
    private readonly quotes: QuotesService,
  ) {}

  @Get('clock')
  @ApiOperation({
    summary:
      'Broker/server clock for candle boundaries. Client must sync BrokerClock from this — never device local time.',
  })
  getClock() {
    const raw = process.env.BROKER_UTC_OFFSET_SEC;
    const brokerUtcOffsetSec =
      raw == null || raw === '' ? 0 : Number.isFinite(parseInt(raw, 10)) ? parseInt(raw, 10) : 0;
    return {
      serverEpochMs: Date.now(),
      brokerUtcOffsetSec,
      source: 'gateway',
    };
  }

  @Get('quotes')
  @ApiOperation({ summary: 'Last-known quote per symbol — seeds the watchlist so it is never blank.' })
  @ApiQuery({ name: 'symbol', required: false, example: 'XAUUSD' })
  getQuotes(@CurrentTenant() t: any, @Query('symbol') symbol?: string) {
    return this.quotes.snapshot(t.id, symbol);
  }

  @Get('candles')
  @ApiOperation({ summary: 'OHLC candles for a symbol (provider-backed)' })
  @ApiQuery({ name: 'symbol', example: 'EURUSD' })
  @ApiQuery({ name: 'tf', example: '1m', enum: ['1m', '5m', '15m', '30m', '1h', '4h', '1d', '1w', '1mn'] })
  @ApiQuery({ name: 'limit', required: false, example: 300 })
  async getCandles(
    @CurrentTenant() _t: any,
    @Query('symbol') symbol: string,
    @Query('tf') tf: string,
    @Query('limit') limit?: string,
  ) {
    if (!symbol) throw new BadRequestException('symbol required');
    if (!this.candles.validTimeframe(tf)) throw new BadRequestException('invalid timeframe');
    const n = Math.min(Math.max(parseInt(limit ?? '300', 10) || 300, 10), 5000);
    return this.candles.candles({ symbol, tf: tf as Timeframe, limit: n });
  }
}
