import {
  CanActivate,
  ExecutionContext,
  Injectable,
  UnauthorizedException,
  ForbiddenException,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { ROLES_KEY, PERM_KEY, FORBID_READONLY_KEY } from './decorators';
import { prisma } from '@btrader/db';

/**
 * JWT auth + RBAC guard. Verifies the access token, loads role/permissions,
 * enforces @Roles and @RequirePerm, and pins the principal to the resolved
 * tenant (cross-tenant access is rejected for non-SUPER_ADMIN).
 */
@Injectable()
export class JwtAuthGuard implements CanActivate {
  constructor(
    private readonly jwt: JwtService,
    private readonly reflector: Reflector,
  ) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const req = ctx.switchToHttp().getRequest();
    const auth = req.headers.authorization ?? '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
    if (!token) throw new UnauthorizedException('missing token');

    let claims: any;
    try {
      claims = this.jwt.verify(token, { secret: process.env.JWT_SECRET });
    } catch {
      throw new UnauthorizedException('invalid token');
    }

    // Tenant isolation: token tenant must match resolved tenant unless platform.
    if (claims.role !== 'SUPER_ADMIN' && req.tenant && claims.tenantId !== req.tenant.id) {
      throw new ForbiddenException('tenant mismatch');
    }

    const readonly = claims.ro === true;
    req.user = { id: claims.sub, role: claims.role, tenantId: claims.tenantId, acct: claims.acct ?? null, readonly };

    // Read-only (investor-password) sessions may not reach any trade mutation.
    // Checked before @Roles so the message is specific to the investor case.
    const forbidReadonly = this.reflector.getAllAndOverride<boolean>(FORBID_READONLY_KEY, [
      ctx.getHandler(),
      ctx.getClass(),
    ]);
    if (forbidReadonly && readonly) {
      throw new ForbiddenException('read-only (investor) session: trading is disabled');
    }

    const roles = this.reflector.getAllAndOverride<string[]>(ROLES_KEY, [
      ctx.getHandler(),
      ctx.getClass(),
    ]);
    if (roles?.length && !roles.includes(claims.role)) {
      throw new ForbiddenException('insufficient role');
    }

    const perm = this.reflector.getAllAndOverride<string>(PERM_KEY, [
      ctx.getHandler(),
      ctx.getClass(),
    ]);
    if (perm && claims.role !== 'SUPER_ADMIN' && claims.role !== 'TENANT_ADMIN') {
      const has = await prisma.userPermission.findFirst({
        where: { userId: claims.sub, scope: perm },
      });
      if (!has) throw new ForbiddenException(`missing permission: ${perm}`);
    }
    return true;
  }
}
