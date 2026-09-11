import { Controller, Get, Header } from '@nestjs/common';
import { ApiTags, ApiOperation } from '@nestjs/swagger';
import { SkipThrottle } from '@nestjs/throttler';
import { prisma } from '@btrader/db';
import { latency, counters, prometheusText } from '@btrader/shared';

@ApiTags('health')
@SkipThrottle()
@Controller()
export class HealthController {
  @Get('health')
  @ApiOperation({ summary: 'Liveness/readiness probe' })
  async health() {
    let db = 'up';
    try {
      await prisma.$queryRaw`SELECT 1`;
    } catch {
      db = 'down';
    }
    return {
      status: db === 'up' ? 'ok' : 'degraded',
      db,
      ts: Date.now(),
      counters: counters.snapshot(),
      latency: latency.snapshot(),
    };
  }

  @Get('metrics')
  @Header('Content-Type', 'text/plain; version=0.0.4')
  @ApiOperation({ summary: 'Prometheus metrics (order latency, fills, SL/TP, feed)' })
  metrics() {
    return prometheusText(latency.snapshot());
  }
}
