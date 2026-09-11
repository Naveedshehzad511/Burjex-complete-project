import { ExecutionContext, Injectable } from '@nestjs/common';
import { ThrottlerGuard } from '@nestjs/throttler';
import { clientIp } from './client-ip';

/**
 * Per-IP throttle using the TLS terminator's client address, not Caddy's
 * docker IP. Optional LOAD_TEST_KEY lets a staging/k6 run skip the limiter
 * without raising public limits; unset key means the header is ignored.
 */
@Injectable()
export class BtThrottlerGuard extends ThrottlerGuard {
  protected async shouldSkip(context: ExecutionContext): Promise<boolean> {
    const key = (process.env.LOAD_TEST_KEY || '').trim();
    if (!key) return false;
    const req = context.switchToHttp().getRequest();
    const sent = req.header?.('x-bt-load-test') ?? req.headers?.['x-bt-load-test'];
    return typeof sent === 'string' && sent === key;
  }

  protected async getTracker(req: Record<string, any>): Promise<string> {
    return clientIp(req);
  }
}
