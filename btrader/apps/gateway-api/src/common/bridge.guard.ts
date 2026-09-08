import { CanActivate, ExecutionContext, Injectable, UnauthorizedException, ForbiddenException } from '@nestjs/common';
import * as crypto from 'crypto';

/**
 * Shared-secret auth for the MT5 Manager bridge (/bridge/* routes).
 *
 * The bridge runs on a trusted Windows VPS alongside the MT5 server. It proves
 * itself with a single header instead of a user login:
 *   X-Bridge-Token: <BRIDGE_TOKEN>          (constant-time compared)
 *   X-BT-Tenant:    <tenantId>              (which tenant these ops apply to)
 *
 * BRIDGE_TOKEN is deliberately SEPARATE from the price-feed token (MT5_FEED_TOKEN)
 * so the low-risk price ingest secret never gains symbol/group/hedge authority.
 * Sets req.tenant + a SERVICE principal so downstream code is tenant-scoped.
 */
@Injectable()
export class BridgeGuard implements CanActivate {
  canActivate(ctx: ExecutionContext): boolean {
    const req = ctx.switchToHttp().getRequest();
    const token = req.header('x-bridge-token');
    const secret = process.env.BRIDGE_TOKEN;
    if (!secret) throw new UnauthorizedException('BRIDGE_TOKEN not configured');
    if (!token || token.length !== secret.length || !crypto.timingSafeEqual(Buffer.from(token), Buffer.from(secret)))
      throw new UnauthorizedException('bad bridge token');

    const tenantId = req.header('x-bt-tenant') ?? req.tenant?.id;
    if (!tenantId) throw new ForbiddenException('X-BT-Tenant required');
    req.tenant = { id: tenantId };
    req.user = { id: 'bridge', role: 'SERVICE', tenantId };
    return true;
  }
}
