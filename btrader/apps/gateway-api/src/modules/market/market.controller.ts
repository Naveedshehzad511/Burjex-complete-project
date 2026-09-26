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
  async getQuotes(@CurrentTenant() t: any, @Query('symbol') symbol?: string) {
    const tenantId = t?.id || (await this.quotes.getDefaultTenantId());
    return this.quotes.snapshot(tenantId, symbol);
  }

  @Get('candles')
  @ApiOperation({ summary: 'OHLC candles for a symbol (provider-backed)' })
  @ApiQuery({ name: 'symbol', example: 'EURUSD' })
  @ApiQuery({ name: 'tf', example: '1m', enum: ['1m', '5m', '15m', '30m', '1h', '4h', '1d', '1w', '1mn'] })
  @ApiQuery({ name: 'limit', required: false, example: 300 })
  async getCandles(
    @CurrentTenant() t: any,
    @Query('symbol') symbol: string,
    @Query('tf') tf: string,
    @Query('limit') limit?: string,
  ) {
    if (!symbol) throw new BadRequestException('symbol required');
    const normalizedTf = this.normalizeTimeframe(tf);
    if (!this.candles.validTimeframe(normalizedTf)) throw new BadRequestException('invalid timeframe');
    const n = Math.min(Math.max(parseInt(limit ?? '300', 10) || 300, 10), 5000);
    return this.candles.candles({ symbol, tf: normalizedTf as Timeframe, limit: n }, t?.id);
  }

  private normalizeTimeframe(tf: string): string {
    if (!tf) return '1m';
    const s = tf.trim().toLowerCase();
    const map: Record<string, string> = {
      m1: '1m', '1m': '1m',
      m5: '5m', '5m': '5m',
      m15: '15m', '15m': '15m',
      m30: '30m', '30m': '30m',
      h1: '1h', '1h': '1h',
      h4: '4h', '4h': '4h',
      d1: '1d', '1d': '1d',
      w1: '1w', '1w': '1w',
      mn: '1mn', '1mn': '1mn', '1mo': '1mn',
    };
    return map[s] ?? s;
  }
}
