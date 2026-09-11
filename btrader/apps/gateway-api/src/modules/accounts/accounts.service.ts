import { Injectable, BadRequestException, NotFoundException } from '@nestjs/common';
import * as bcrypt from 'bcryptjs';
import * as crypto from 'crypto';
import { prisma } from '@btrader/db';
import { PORTAL_READ_CACHE_MS, ttlWrap } from '../../common/ttl-cache';

/** A readable random trading password (no ambiguous chars like O/0, I/l). */
function genPassword(): string {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  const buf = crypto.randomBytes(10);
  let s = '';
  for (let i = 0; i < buf.length; i++) s += chars[buf[i] % chars.length];
  return s;
}

/** Client + trading-account management for tenant admins. */
@Injectable()
export class AccountsService {
  listClients(tenantId: string) {
    return prisma.user.findMany({
      where: { tenantId, role: 'TRADER' },
      include: { accounts: true },
      orderBy: { createdAt: 'desc' },
      take: 500,
    });
  }

  /** Flat list of every trading account with owner name + live money fields
   *  (balance/equity/floating P/L persisted by the engine on each tick sweep). */
  async allAccounts(tenantId: string) {
    const accounts = await prisma.account.findMany({
      where: { tenantId },
      include: { user: { select: { firstName: true, lastName: true, email: true, phone: true } } },
      orderBy: { login: 'asc' },
      take: 2000,
    });
    return accounts.map((a) => ({
      id: a.id,
      login: a.login,
      name: [a.user?.firstName, a.user?.lastName].filter(Boolean).join(' ').trim() || a.user?.email || '—',
      email: a.user?.email ?? null,
      phone: a.user?.phone ?? null,
      type: a.type,
      currency: a.currency,
      leverage: a.leverage,
      isDemo: a.isDemo,
      balance: a.balance,
      equity: a.equity,
      floatingPL: a.floatingPL,
      status: a.status,
      createdAt: a.createdAt,
    }));
  }

  async createClient(tenantId: string, body: any) {
    // Use the supplied password or generate one; set it on BOTH the user (email
    // login) and the account (account-number login). Return it once so the admin
    // can share it — it's hashed at rest and can't be shown again later.
    const password = body.password && String(body.password).length >= 6 ? String(body.password) : genPassword();
    const passwordHash = await bcrypt.hash(password, 10);
    const user = await prisma.user.create({
      data: {
        tenantId,
        email: body.email,
        role: 'TRADER',
        firstName: body.firstName,
        lastName: body.lastName,
        phone: body.phone,
        crmUserId: body.crmUserId,
        passwordHash,
      },
    });
    const last = await prisma.account.findFirst({ where: { tenantId }, orderBy: { login: 'desc' } });
    const login = String(last ? parseInt(last.login, 10) + 1 : 500001);
    const isDemo = body.isDemo === true || body.type === 'DEMO';
    const account = await prisma.account.create({
      data: {
        tenantId,
        userId: user.id,
        login,
        type: body.type ?? 'STANDARD',
        currency: body.currency ?? 'USD',
        leverage: body.leverage ?? 100,
        isDemo,
        // Demo accounts are hard-warehoused so they can never cover to the LP.
        book: isDemo ? 'B' : undefined,
        passwordHash,
      },
    });
    return { user, account, login, password };
  }

  /**
   * Self-serve demo account for the logged-in trader: virtual balance (any
   * amount the client chooses), hard B-book, real prices. No real money moves.
   */
  async createDemo(tenantId: string, userId: string, body: any) {
    const currency = String(body.currency ?? 'USD').toUpperCase().slice(0, 8) || 'USD';
    const leverage = Math.min(Math.max(parseInt(String(body.leverage ?? 100), 10) || 100, 1), 3000);
    const balance = Math.min(Math.max(Number(body.balance) || 0, 0), 1e12);
    const last = await prisma.account.findFirst({ where: { tenantId }, orderBy: { login: 'desc' } });
    const login = String(last ? parseInt(last.login, 10) + 1 : 500001);
    // Give the demo its own trading password so it can be logged into by account
    // number, MT5-style. Client-supplied (>= 6 chars) or auto-generated. Returned
    // once in plaintext so the app can show it — hashed at rest.
    const password = body.password && String(body.password).length >= 6 ? String(body.password) : genPassword();
    const passwordHash = await bcrypt.hash(password, 10);
    const account = await prisma.account.create({
      data: { tenantId, userId, login, type: 'DEMO', isDemo: true, book: 'B', currency, leverage, balance, passwordHash },
    });
    if (balance > 0) {
      await prisma.balanceAdjustment.create({
        data: { tenantId, accountId: account.id, type: 'DEPOSIT', amount: balance, currency, comment: 'Demo funding', performedBy: userId },
      }).catch(() => undefined);
    }
    return { id: account.id, login, currency, leverage, balance, password };
  }

  /**
   * Set a demo account's virtual balance (top-up / reset to any amount). Only
   * the owner may change it, and only on a demo account — real accounts are
   * untouchable here.
   */
  async setDemoBalance(tenantId: string, userId: string, accountId: string, balanceRaw: unknown) {
    const acc = await prisma.account.findFirst({ where: { id: accountId, tenantId, userId, isDemo: true } });
    if (!acc) throw new NotFoundException('demo account not found');
    const balance = Math.min(Math.max(Number(balanceRaw) || 0, 0), 1e12);
    const delta = balance - Number(acc.balance);
    await prisma.account.update({ where: { id: accountId }, data: { balance } });
    if (delta !== 0) {
      await prisma.balanceAdjustment.create({
        data: { tenantId, accountId, type: 'CORRECTION', amount: delta, currency: acc.currency, comment: 'Demo balance set', performedBy: userId },
      }).catch(() => undefined);
    }
    return { ok: true, balance };
  }

  /** Set / reset an account's trading password (also syncs the user password). */
  async setAccountPassword(tenantId: string, accountId: string, password: string) {
    if (!password || password.length < 6) throw new BadRequestException('password must be at least 6 characters');
    const account = await prisma.account.findFirst({ where: { tenantId, id: accountId } });
    if (!account) throw new NotFoundException('account not found');
    const passwordHash = await bcrypt.hash(password, 10);
    await prisma.account.update({ where: { id: accountId }, data: { passwordHash } });
    await prisma.user.update({ where: { id: account.userId }, data: { passwordHash } });
    return { ok: true, login: account.login };
  }

  async setClientActive(tenantId: string, userId: string, isActive: boolean) {
    const res = await prisma.user.updateMany({ where: { tenantId, id: userId }, data: { isActive } });
    // Disabling an account must log it out now, not just block the next login —
    // revoke all live sessions so the apps drop to the login screen on their
    // next refresh (sessions are otherwise persistent).
    if (!isActive) {
      await prisma.session.updateMany({ where: { userId, revokedAt: null }, data: { revokedAt: new Date() } });
    }
    return res;
  }

  setTrading(tenantId: string, accountId: string, enabled: boolean) {
    return prisma.account.updateMany({
      where: { tenantId, id: accountId },
      data: { status: enabled ? 'ACTIVE' : 'TRADING_DISABLED' },
    });
  }

  changeLeverage(tenantId: string, accountId: string, leverage: number) {
    return prisma.account.updateMany({ where: { tenantId, id: accountId }, data: { leverage } });
  }

  /** Move an account to a trading group (validated to this tenant), or clear it. */
  async setGroup(tenantId: string, accountId: string, groupId: string | null) {
    if (groupId) {
      const g = await prisma.tradingGroup.findFirst({ where: { tenantId, id: groupId }, select: { id: true } });
      if (!g) return { error: 'group not found' };
    }
    await prisma.account.updateMany({ where: { tenantId, id: accountId }, data: { groupId } });
    return { ok: true };
  }

  /** Remove an account. Hard-deletes a truly empty account (no deals/positions/
   *  orders); archives one that has history (keeps the audit trail). Refuses
   *  while positions are still open. */
  async deleteAccount(tenantId: string, accountId: string) {
    const acct = await prisma.account.findFirst({ where: { tenantId, id: accountId }, select: { id: true } });
    if (!acct) return { error: 'account not found' } as const;
    const openPositions = await prisma.position.count({ where: { tenantId, accountId, status: 'OPEN' } });
    if (openPositions > 0) return { error: 'close all open positions before deleting' } as const;

    const [deals, orders, positions] = await Promise.all([
      prisma.deal.count({ where: { tenantId, accountId } }),
      prisma.order.count({ where: { tenantId, accountId } }),
      prisma.position.count({ where: { tenantId, accountId } }),
    ]);
    if (deals === 0 && orders === 0 && positions === 0) {
      await prisma.account.delete({ where: { id: accountId } });
      return { deleted: true, archived: false } as const;
    }
    // Has history — archive instead of destroying financial records.
    await prisma.account.update({ where: { id: accountId }, data: { status: 'ARCHIVED' } });
    return { deleted: false, archived: true } as const;
  }

  /** The signed-in trader's own accounts (with the group's client symbol suffix).
   *  When the session is scoped to one account (logged in by account number),
   *  only that account is returned — the client sees just the account they
   *  signed into, and switches by logging in with another number + password. */
  async myAccounts(tenantId: string, userId: string, acctScope?: string | null) {
    const rows = await ttlWrap(
      `acctme:${tenantId}:${userId}:${acctScope ?? ''}`,
      PORTAL_READ_CACHE_MS,
      () =>
        prisma.account.findMany({
          where: { tenantId, userId, ...(acctScope ? { id: acctScope } : {}) },
          include: {
            group: { select: { clientSymbolSuffix: true, name: true } },
            user: { select: { firstName: true, lastName: true, email: true } },
          },
          orderBy: { createdAt: 'asc' },
        }),
    );
    return rows.map(({ group, user, ...a }) => ({
      ...a,
      symbolSuffix: group?.clientSymbolSuffix ?? null,
      groupName: group?.name ?? null,
      // Account holder's display name (same across a trader's accounts).
      ownerName: [user?.firstName, user?.lastName].filter(Boolean).join(' ').trim() || user?.email || null,
    }));
  }

  getAccount(tenantId: string, accountId: string) {
    return prisma.account.findFirst({ where: { tenantId, id: accountId }, include: { user: true } });
  }

  /** The client symbol suffix for an account's group (canonical when none). */
  async accountSymbolSuffix(tenantId: string, accountId: string): Promise<string | null> {
    const a = await prisma.account.findFirst({
      where: { tenantId, id: accountId },
      select: { group: { select: { clientSymbolSuffix: true } } },
    });
    return a?.group?.clientSymbolSuffix ?? null;
  }

  /** Net signed lots per SYMBOL (BUY positive, SELL negative), keyed by the
   *  human symbol name so the admin sees "EURUSD", not a symbolId UUID. */
  async netExposure(tenantId: string) {
    const grouped = await prisma.position.groupBy({
      by: ['symbolId', 'side'],
      where: { tenantId, status: 'OPEN' },
      _sum: { volume: true },
    });
    if (grouped.length === 0) return [];
    const symbols = await prisma.symbol.findMany({
      where: { tenantId, id: { in: [...new Set(grouped.map((g) => g.symbolId))] } },
      select: { id: true, symbol: true },
    });
    const nameById = new Map(symbols.map((s) => [s.id, s.symbol]));
    return grouped.map((g) => ({
      symbol: nameById.get(g.symbolId) ?? g.symbolId,
      symbolId: g.symbolId,
      side: g.side,
      _sum: g._sum,
    }));
  }

  /** All open positions tenant-wide (optionally scoped to one client's accounts). */
  allPositions(tenantId: string, userId?: string) {
    return prisma.position.findMany({
      where: { tenantId, status: 'OPEN', ...(userId ? { account: { userId } } : {}) },
      include: {
        symbol: { select: { symbol: true, digits: true } },
        account: { select: { login: true, userId: true } },
      },
      orderBy: { openedAt: 'desc' },
      take: 1000,
    });
  }
}
