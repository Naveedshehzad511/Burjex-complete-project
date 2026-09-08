import { CanActivate, ExecutionContext, Injectable, UnauthorizedException } from '@nestjs/common';
import * as crypto from 'crypto';

/**
 * Shared-secret auth for the read-only HQ overview (/hq/overview).
 *
 * Each company deployment sets its own HQ_TOKEN; the central HQ dashboard
 * presents it as X-HQ-Token. Deliberately SEPARATE from BRIDGE_TOKEN so the
 * oversight credential never gains symbol/hedge/order authority — the only
 * route this guard protects is a read-only aggregate.
 */
@Injectable()
export class HqGuard implements CanActivate {
  canActivate(ctx: ExecutionContext): boolean {
    const req = ctx.switchToHttp().getRequest();
    const token = req.header('x-hq-token');
    const secret = process.env.HQ_TOKEN;
    if (!secret) throw new UnauthorizedException('HQ_TOKEN not configured on this server');
    if (!token || token.length !== secret.length || !crypto.timingSafeEqual(Buffer.from(token), Buffer.from(secret)))
      throw new UnauthorizedException('bad HQ token');
    return true;
  }
}
