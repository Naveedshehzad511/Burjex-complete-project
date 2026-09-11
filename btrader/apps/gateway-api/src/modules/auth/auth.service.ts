import { Injectable, UnauthorizedException, BadRequestException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import * as bcrypt from 'bcryptjs';
import * as crypto from 'crypto';
import { prisma } from '@btrader/db';
import { ttlWrap } from '../../common/ttl-cache';

function genDemoPassword(): string {
  return crypto.randomBytes(9).toString('base64').replace(/[^a-zA-Z0-9]/g, '').slice(0, 8) + '9x';
}

@Injectable()
export class AuthService {
  constructor(private readonly jwt: JwtService) {}

  /** One UPDATE per user per minute — 500 concurrent logins must not serialize on one row. */
  private lastLoginTouch = new Map<string, number>();

  private touchLastLogin(userId: string) {
    const now = Date.now();
    const prev = this.lastLoginTouch.get(userId) ?? 0;
    if (now - prev < 60_000) return;
    this.lastLoginTouch.set(userId, now);
    void prisma.user
      .update({ where: { id: userId }, data: { lastLoginAt: new Date() } })
      .catch(() => undefined);
  }

  /**
   * Self-serve demo signup (lead generation). Captures the prospect's full
   * contact details (name, email, phone), creates — or reuses, for a returning
   * email — the lead user, opens a virtual DEMO account, and auto-logs-in scoped
   * to that account. All details are stored on the user/account and surface in
   * the admin Demo Accounts page.
   */
  async registerDemo(tenantId: string | null, body: any, ip?: string, ua?: string) {
    if (!tenantId) throw new BadRequestException('unknown broker');
    const email = String(body.email ?? '').trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new BadRequestException('a valid email is required');
    const firstName = String(body.firstName ?? '').trim() || null;
    const lastName = String(body.lastName ?? '').trim() || null;
    const phone = String(body.phone ?? '').trim() || null;
    const password = body.password && String(body.password).length >= 6 ? String(body.password) : genDemoPassword();
    const passwordHash = await bcrypt.hash(password, 10);

    // Find-or-create the lead user (email is unique per tenant).
    let user = await prisma.user.findFirst({ where: { email, tenantId } });
    if (!user) {
      user = await prisma.user.create({
        data: { tenantId, email, role: 'TRADER', firstName, lastName, phone, passwordHash, isActive: true },
      });
    } else {
      // Returning lead: backfill any contact details we didn't have. Keep their
      // existing password (don't overwrite an established login).
      await prisma.user.update({
        where: { id: user.id },
        data: { firstName: user.firstName ?? firstName, lastName: user.lastName ?? lastName, phone: user.phone ?? phone },
      });
      if (!user.isActive) throw new UnauthorizedException('account disabled');
    }

    // Open the virtual demo account (B-book, real prices).
    const currency = String(body.currency ?? 'USD').toUpperCase().slice(0, 8) || 'USD';
    const leverage = Math.min(Math.max(parseInt(String(body.leverage ?? 100), 10) || 100, 1), 3000);
    const balance = Math.min(Math.max(Number(body.balance) || 0, 0), 1e12);
    const last = await prisma.account.findFirst({ where: { tenantId }, orderBy: { login: 'desc' } });
    const login = String(last ? parseInt(last.login, 10) + 1 : 500001);
    const account = await prisma.account.create({
      data: { tenantId, userId: user.id, login, type: 'DEMO', isDemo: true, book: 'B', currency, leverage, balance, passwordHash },
    });
    if (balance > 0) {
      await prisma.balanceAdjustment.create({
        data: { tenantId, accountId: account.id, type: 'DEPOSIT', amount: balance, currency, comment: 'Demo funding', performedBy: user.id },
      }).catch(() => undefined);
    }

    const tokens = await this.issue(user, ip, ua, account.id);
    return { ...tokens, accountId: account.id, login: account.login, password };
  }

  private async accessToken(
    user: { id: string; role: string; tenantId: string | null },
    acctScope?: string | null,
    readonly = false,
  ) {
    // MT5-style session scoping: a client who logs in by ACCOUNT NUMBER only
    // sees/operates that one account (`acct` claim, and `accts` restricted to
    // it). Email logins (admins) stay unscoped and see all their accounts. The
    // WS gateway uses `accts` to authorize which accounts may be watched.
    const accts = acctScope
      ? [acctScope]
      : (
          await ttlWrap(`accts:${user.id}`, 5_000, () =>
            prisma.account.findMany({ where: { userId: user.id }, select: { id: true } }),
          )
        ).map((a) => a.id);
    return this.jwt.sign(
      {
        sub: user.id,
        role: user.role,
        tenantId: user.tenantId,
        accts,
        ...(acctScope ? { acct: acctScope } : {}),
        // #3B: read-only investor session. Absent for normal sessions.
        ...(readonly ? { ro: true } : {}),
      },
      { secret: process.env.JWT_SECRET, expiresIn: process.env.JWT_EXPIRES_IN ?? '15m' },
    );
  }

  private refreshToken(user: { id: string }, acctScope?: string | null, readonly = false) {
    return this.jwt.sign(
      {
        sub: user.id,
        typ: 'refresh',
        jti: crypto.randomUUID(),
        ...(acctScope ? { acct: acctScope } : {}),
        // Carry read-only across refreshes so a re-issued access token stays read-only.
        ...(readonly ? { ro: true } : {}),
      },
      // Sessions are persistent by design: a signed-in client/admin stays logged
      // in until they sign out, or the account is disabled/deleted by an admin
      // (enforced in refresh()). Default the refresh token to ~10 years so time
      // alone never logs anyone out. Override via JWT_REFRESH_EXPIRES_IN.
      { secret: process.env.JWT_REFRESH_SECRET, expiresIn: process.env.JWT_REFRESH_EXPIRES_IN ?? '3650d' },
    );
  }

  /** Far-future session expiry (~10y). Sessions end via logout/revoke, not time. */
  private sessionExpiry() {
    return new Date(Date.now() + 3650 * 24 * 3600 * 1000);
  }

  async login(tenantId: string | null, email: string, password: string, ip?: string, ua?: string) {
    const normalizedEmail = String(email ?? '').trim().toLowerCase();
    let user = await prisma.user.findFirst({
      where: { email: normalizedEmail, tenantId: tenantId ?? null },
    });
    // Global super-admins aren't bound to a tenant. The admin app pins a tenant
    // header (X-BT-Tenant), so a tenant-scoped lookup never finds them — fall
    // back to a tenant-less SUPER_ADMIN with this email so they can sign in
    // through any tenant's admin console.
    if (!user && tenantId) {
      user = await prisma.user.findFirst({
        where: { email: normalizedEmail, tenantId: null, role: 'SUPER_ADMIN' },
      });
    }
    if (!user || !user.passwordHash) throw new UnauthorizedException('invalid credentials');

    const ok =
      // accept bcrypt or the seed's sha256 (dev) for convenience
      (await bcrypt.compare(password, user.passwordHash).catch(() => false)) ||
      crypto.createHash('sha256').update(password).digest('hex') === user.passwordHash;
    if (!ok) throw new UnauthorizedException('invalid credentials');
    if (!user.isActive) throw new UnauthorizedException('account disabled');

    return this.issue(user, ip, ua);
  }

  /**
   * MT5-style login by trading account NUMBER + password. Resolves the account,
   * verifies its MAIN password, issues tokens for the account's user, and
   * returns the accountId so the app sets it active.
   */
  async loginByAccount(tenantId: string | null, login: string, password: string, ip?: string, ua?: string) {
    const account = await prisma.account.findFirst({
      where: { login, tenantId: tenantId ?? undefined },
      include: { user: true },
    });
    if (!account) throw new UnauthorizedException('invalid credentials');
    // Prefer the per-account password; fall back to the user password for
    // accounts provisioned before per-account passwords existed.
    const mainHash = account.passwordHash ?? account.user.passwordHash;
    // #3B: the investor password grants a READ-ONLY session. Check the main
    // password first (so an account where investor == main stays full-access,
    // the legacy default), then the investor password. Only a distinct investor
    // password that matches yields a read-only session.
    const matches = async (h: string | null | undefined): Promise<boolean> => {
      if (!h) return false;
      return (
        (await bcrypt.compare(password, h).catch(() => false)) ||
        crypto.createHash('sha256').update(password).digest('hex') === h
      );
    };
    let readonly = false;
    if (await matches(mainHash)) {
      readonly = false;
    } else if (await matches(account.investorPasswordHash)) {
      readonly = true;
    } else {
      throw new UnauthorizedException('invalid credentials');
    }
    if (account.status === 'ARCHIVED' || !account.user.isActive) throw new UnauthorizedException('account disabled');

    const tokens = await this.issue(account.user, ip, ua, account.id, readonly);
    return { ...tokens, accountId: account.id, login: account.login };
  }

  private async issue(
    user: { id: string; role: string; tenantId: string | null },
    ip?: string,
    ua?: string,
    acctScope?: string | null,
    readonly = false,
  ) {
    const access = await this.accessToken(user, acctScope, readonly);
    const refresh = this.refreshToken(user, acctScope, readonly);
    const refreshHash = crypto.createHash('sha256').update(refresh).digest('hex');
    const expiresAt = this.sessionExpiry();
    await prisma.session.create({
      data: { userId: user.id, tenantId: user.tenantId, refreshHash, ip, userAgent: ua, expiresAt },
    });
    this.touchLastLogin(user.id);
    // `readonly` lets the client hide trade controls for an investor session;
    // the server enforces it regardless (JwtAuthGuard + @ForbidReadOnly).
    return { accessToken: access, refreshToken: refresh, role: user.role, readonly };
  }

  async refresh(refreshToken: string) {
    let claims: any;
    try {
      claims = this.jwt.verify(refreshToken, { secret: process.env.JWT_REFRESH_SECRET });
    } catch {
      throw new UnauthorizedException('invalid refresh token');
    }
    const hash = crypto.createHash('sha256').update(refreshToken).digest('hex');
    const session = await prisma.session.findFirst({
      where: { refreshHash: hash, userId: claims.sub, revokedAt: null },
    });
    if (!session || session.expiresAt < new Date()) throw new UnauthorizedException('session expired');

    // The session only ends via explicit sign-out, admin revoke, or the account
    // being disabled/deleted — enforce the last two here so they take effect on
    // the next refresh. A deleted user cascades its sessions away (so `session`
    // would already be null), but guard anyway and return 401 (not 500).
    const user = await prisma.user.findUnique({ where: { id: claims.sub } });
    if (!user) throw new UnauthorizedException('account removed');
    if (!user.isActive) {
      await prisma.session.update({ where: { id: session.id }, data: { revokedAt: new Date() } });
      throw new UnauthorizedException('account disabled');
    }
    // Non-rotating: issue a fresh access token but KEEP the same refresh token /
    // session. Rotating here stranded apps that refreshed in memory then were
    // killed before persisting the new refresh token. The session is persistent
    // (~10y) and ends only via logout/force-logout/disable/delete.
    // Preserve the account scope from the refresh token so a by-account session
    // stays pinned to its one account across refreshes.
    return {
      accessToken: await this.accessToken(user, claims.acct ?? null, claims.ro === true),
      refreshToken,
      role: user.role,
      readonly: claims.ro === true,
    };
  }

  /** Force-logout: revoke all of a user's sessions (admin action). */
  async forceLogout(userId: string) {
    await prisma.session.updateMany({
      where: { userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
    return { ok: true };
  }

  async logout(refreshToken: string) {
    const hash = crypto.createHash('sha256').update(refreshToken).digest('hex');
    await prisma.session.updateMany({ where: { refreshHash: hash }, data: { revokedAt: new Date() } });
    return { ok: true };
  }
}
