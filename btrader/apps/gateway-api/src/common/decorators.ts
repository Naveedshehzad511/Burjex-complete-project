import { createParamDecorator, ExecutionContext, SetMetadata } from '@nestjs/common';

/** Roles required for a route (RBAC). */
export const ROLES_KEY = 'roles';
export const Roles = (...roles: string[]) => SetMetadata(ROLES_KEY, roles);

/** Fine-grained permission scope required (e.g. 'balance.adjust'). */
export const PERM_KEY = 'perm';
export const RequirePerm = (scope: string) => SetMetadata(PERM_KEY, scope);

/**
 * Marks a route as a trade mutation that a READ-ONLY (investor-password)
 * session must never reach (spec #3B). Enforced in JwtAuthGuard: an investor
 * session (`ro` claim) is refused with 403 on any route carrying this marker.
 */
export const FORBID_READONLY_KEY = 'forbidReadonly';
export const ForbidReadOnly = () => SetMetadata(FORBID_READONLY_KEY, true);

/** Marks a route as CRM/service (HMAC-key auth instead of JWT). */
export const CRM_AUTH_KEY = 'crmAuth';
export const CrmAuth = (...scopes: string[]) => SetMetadata(CRM_AUTH_KEY, scopes);

/** Injects the resolved tenant. */
export const CurrentTenant = createParamDecorator((_d, ctx: ExecutionContext) => {
  return ctx.switchToHttp().getRequest().tenant;
});

/** Injects the authenticated principal (user or api-key). */
export const CurrentUser = createParamDecorator((_d, ctx: ExecutionContext) => {
  return ctx.switchToHttp().getRequest().user;
});
