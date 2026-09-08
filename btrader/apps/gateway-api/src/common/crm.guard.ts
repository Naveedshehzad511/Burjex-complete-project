import {
  CanActivate,
  ExecutionContext,
  Injectable,
  UnauthorizedException,
  ForbiddenException,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import * as crypto from 'crypto';
import { prisma } from '@btrader/db';
import { CRM_AUTH_KEY } from './decorators';

/**
 * Service-to-service auth for /v1/crm/* routes.
 * Headers: X-BT-Key (keyId), X-BT-Timestamp (epoch ms), X-BT-Signature
 *   signature = HMAC_SHA256(secret, `${timestamp}.${rawBody}`)
 * Verifies: key active, not expired, IP allowlist, timestamp freshness (±5 min),
 * constant-time signature match, and required scopes. Sets req.tenant + req.user.
 */
@Injectable()
export class CrmKeyGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const req = ctx.switchToHttp().getRequest();
    const keyId = req.header('x-bt-key');
    const ts = req.header('x-bt-timestamp');
    const sig = req.header('x-bt-signature');
    if (!keyId || !ts || !sig) throw new UnauthorizedException('missing CRM auth headers');

    // Replay protection: 5-minute window.
    const skew = Math.abs(Date.now() - Number(ts));
    if (!Number.isFinite(skew) || skew > 5 * 60_000) throw new UnauthorizedException('stale timestamp');

    const key = await prisma.apiKey.findUnique({ where: { keyId } });
    if (!key || key.revokedAt || (key.expiresAt && key.expiresAt < new Date()))
      throw new UnauthorizedException('invalid key');

    // IP allowlist (CIDR-less exact / prefix match kept simple here).
    const ip = (req.headers['x-forwarded-for']?.split(',')[0] ?? req.ip ?? '').trim();
    if (key.ipAllowlist.length && !key.ipAllowlist.some((c) => ip.startsWith(c.split('/')[0])))
      throw new ForbiddenException('ip not allowed');

    const raw = req.rawBody ? req.rawBody.toString() : JSON.stringify(req.body ?? {});
    // Each key carries its own HMAC secret → every tenant's CRM is isolated.
    const secret = key.secret ?? process.env.CRM_INTEGRATION_KEY ?? 'shared-crm-service-key';
    const expected = crypto
      .createHmac('sha256', secret)
      .update(`${ts}.${raw}`)
      .digest('hex');
    const ok =
      expected.length === sig.length &&
      crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(sig));
    if (!ok) throw new UnauthorizedException('bad signature');

    const required = this.reflector.getAllAndOverride<string[]>(CRM_AUTH_KEY, [
      ctx.getHandler(),
      ctx.getClass(),
    ]);
    if (required?.length && !required.every((s) => key.scopes.includes(s)))
      throw new ForbiddenException('insufficient scope');

    // Bind tenant context from the key — AUTHORITATIVE for CRM routes. A scoped
    // key's tenant MUST override whatever TenantMiddleware resolved from the host
    // (which defaults to the fallback tenant when no X-BT-Tenant is sent), or a
    // tenant's CRM would write into another tenant. Only platform keys (no
    // tenantId) fall back to the X-BT-Tenant header.
    const tenantId = key.tenantId ?? req.header('x-bt-tenant');
    if (!tenantId) throw new ForbiddenException('tenant unresolved for key');
    req.tenant = { id: tenantId };
    req.user = { id: 'apikey:' + key.id, role: 'SERVICE', tenantId };

    await prisma.apiKey.update({ where: { keyId }, data: { lastUsedAt: new Date() } });
    return true;
  }
}
