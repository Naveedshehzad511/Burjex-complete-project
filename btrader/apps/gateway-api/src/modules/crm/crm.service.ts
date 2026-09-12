import { Injectable } from '@nestjs/common';
import * as bcrypt from 'bcryptjs';
import { prisma } from '@btrader/db';
import { BtError, BtErrorCode, CrmAccountInfo, CrmPosition, CrmDeal, CrmTradingStats } from '@btrader/shared';
import { positionProfit, resolveFxFactor } from '@btrader/engine-core';
import { FinancialService } from '../financial/financial.service';
import { EngineProvider } from '../trading/engine.provider';

const num = (v: any) => (v == null ? 0 : Number(v));

/**
 * Implements the B-Trader → CRM contract (superset of the CRM's mt5.service).
 * All methods are tenant-scoped by the CrmKeyGuard.
 */
@Injectable()
export class CrmService {
  constructor(
    private readonly fin: FinancialService,
    private readonly engineProvider: EngineProvider,
  ) {}

  /** Groups the CRM maps in Group Management → account types (`group` on createAccount). */
  async listGroups(tenantId: string): Promise<Array<{ id: string; name: string; enabled: boolean; defaultLeverage: number; defaultBook: string }>> {
    const groups = await prisma.tradingGroup.findMany({
      where: { tenantId },
      select: { id: true, name: true, enabled: true, defaultLeverage: true, defaultBook: true },
      orderBy: { name: 'asc' },
    });
    return groups.map((g) => ({
      id: g.id,
      name: g.name,
      enabled: g.enabled,
      defaultLeverage: g.defaultLeverage,
      defaultBook: g.defaultBook,
    }));
  }

  /** Broker-created engine symbols (XAUUSD.s), not raw LP feed names. */
  async listSymbols(tenantId: string): Promise<Array<{ symbol: string; description: string | null; class: string; enabled: boolean }>> {
    const rows = await prisma.symbol.findMany({
      where: { tenantId, enabled: true },
      select: { symbol: true, description: true, class: true, enabled: true },
      orderBy: { symbol: 'asc' },
    });
    return rows.map((r) => ({
      symbol: r.symbol,
      description: r.description,
      class: r.class,
      enabled: r.enabled,
    }));
  }

  async createAccount(tenantId: string, body: any): Promise<{ accountId: string; login: string }> {
    // Find-or-create the trader user mapped to the CRM user id.
    const user = await prisma.user.upsert({
      where: { tenantId_email: { tenantId, email: body.email } },
      update: { crmUserId: body.crmUserId },
      create: {
        tenantId,
        email: body.email,
        crmUserId: body.crmUserId,
        role: 'TRADER',
        firstName: body.name?.split(' ')?.[0],
        lastName: body.name?.split(' ')?.slice(1).join(' '),
        phone: body.phone,
      },
    });

    const login = await this.nextLogin(tenantId);
    // CRM sends the account (MAIN) password; B-Trader hashes + stores it. The
    // client logs into the app with this login number + password.
    const passwordHash = body.password ? await bcrypt.hash(String(body.password), 10) : null;
    // #3B: CRM also sends a distinct INVESTOR (read-only) password. Logging in
    // with this yields a read-only session. null when the CRM omits it.
    const investorPasswordHash = body.investorPassword
      ? await bcrypt.hash(String(body.investorPassword), 10)
      : null;

    // Resolve the trading group by name (matches the CRM's account-type group).
    // The group sets the client's spread markup, commission, default leverage
    // and book. If the CRM sends a group the broker hasn't created in B-Trader,
    // the account is still created (no group) — pricing falls back to symbol.
    const groupName = (body.group ?? '').toString().trim();
    const group = groupName
      ? await prisma.tradingGroup.findUnique({ where: { tenantId_name: { tenantId, name: groupName } } })
      : null;

    const account = await prisma.account.create({
      data: {
        tenantId,
        userId: user.id,
        login,
        passwordHash,
        investorPasswordHash,
        type: body.type ?? 'STANDARD',
        groupId: group?.id ?? null,
        // Explicit CRM value wins; otherwise inherit the group's defaults.
        currency: body.currency ?? 'USD',
        leverage: body.leverage ?? group?.defaultLeverage ?? 100,
        book: group ? group.defaultBook : undefined,
        isDemo: !!body.isDemo,
        crmAccountId: body.crmAccountId,
      },
    });
    return { accountId: account.id, login: account.login };
  }

  async getAccount(tenantId: string, login: string): Promise<CrmAccountInfo> {
    const a = await prisma.account.findFirst({ where: { tenantId, login }, include: { user: true } });
    if (!a) throw new BtError(BtErrorCode.VALIDATION, 'account not found');
    return this.toInfo(a);
  }

  async batch(tenantId: string, logins: string[]): Promise<Record<string, CrmAccountInfo>> {
    const accts = await prisma.account.findMany({ where: { tenantId, login: { in: logins } } });
    const out: Record<string, CrmAccountInfo> = {};
    for (const a of accts) out[a.login] = this.toInfo(a);
    return out;
  }

  async positions(tenantId: string, login: string): Promise<CrmPosition[]> {
    const acct = await prisma.account.findFirst({ where: { tenantId, login } });
    if (!acct) return [];
    const pos = await prisma.position.findMany({
      where: { tenantId, accountId: acct.id, status: 'OPEN' },
      include: { symbol: true },
    });
    // Value at live prices. This used to report currentPrice = openPrice and
    // profit = Position.profit — a column with no writer for open rows — so the
    // CRM showed every open position as breakeven with no price movement, and
    // any statement or risk view built on this endpoint was wrong.
    const prices = this.engineProvider.prices;
    return pos.map((p) => {
      // Closing side: a BUY exits at bid, a SELL at ask.
      const live =
        p.side === 'BUY'
          ? prices.sellPrice(tenantId, p.symbol.symbol)
          : prices.buyPrice(tenantId, p.symbol.symbol);
      const currentPrice = live ?? num(p.openPrice);
      const spec = {
        digits: p.symbol.digits,
        pipSize: num(p.symbol.pipSize),
        contractSize: num(p.symbol.contractSize),
        marginRate: num(p.symbol.marginRate),
        quoteCurrency: p.symbol.quoteCurrency,
        baseCurrency: p.symbol.baseCurrency,
      };
      const conv = resolveFxFactor(acct.currency, p.symbol.quoteCurrency, (s) => {
        const b = prices.buyPrice(tenantId, s);
        const a = prices.sellPrice(tenantId, s);
        if (b != null && a != null) return (b + a) / 2;
        return b ?? a ?? null;
      });
      const profit =
        live == null
          ? // No quote: fall back to the cached column rather than reporting a
            // fabricated zero. It is refreshed by the engine every couple of
            // seconds while ticks flow, so it is the best available answer.
            num(p.profit)
          : positionProfit(
              p.side as 'BUY' | 'SELL',
              num(p.volume),
              num(p.openPrice),
              currentPrice,
              spec,
              conv ?? 1,
            ) +
            num(p.swap) +
            num(p.commission);
      return {
        positionId: p.id,
        login,
        symbol: p.symbol.symbol,
        side: p.side as 'BUY' | 'SELL',
        volume: num(p.volume),
        openPrice: num(p.openPrice),
        currentPrice,
        slPrice: p.slPrice ? num(p.slPrice) : undefined,
        tpPrice: p.tpPrice ? num(p.tpPrice) : undefined,
        swap: num(p.swap),
        commission: num(p.commission),
        profit,
        openedAt: p.openedAt.toISOString(),
      };
    });
  }

  async deals(tenantId: string, login: string, from: string, to: string): Promise<CrmDeal[]> {
    const acct = await prisma.account.findFirst({ where: { tenantId, login } });
    if (!acct) return [];
    const deals = await prisma.deal.findMany({
      where: { tenantId, accountId: acct.id, createdAt: { gte: new Date(from), lte: new Date(to) } },
      orderBy: { createdAt: 'desc' },
      take: 1000,
    });
    return deals.map((d) => ({
      dealId: d.id,
      login,
      positionId: d.positionId ?? undefined,
      type: d.type,
      side: (d.side ?? undefined) as any,
      volume: d.volume ? num(d.volume) : undefined,
      price: d.price ? num(d.price) : undefined,
      profit: num(d.profit),
      swap: num(d.swap),
      commission: num(d.commission),
      balanceAfter: num(d.balanceAfter),
      comment: d.comment ?? undefined,
      externalRef: d.externalRef ?? undefined,
      createdAt: d.createdAt.toISOString(),
    }));
  }

  async balanceOp(tenantId: string, login: string, body: any) {
    return this.fin.adjust({
      tenantId,
      login,
      type: body.type,
      amount: body.amount,
      comment: body.comment,
      externalRef: body.externalRef,
      performedBy: 'crm:service',
    });
  }

  async updateAccount(tenantId: string, login: string, body: any) {
    const acct = await prisma.account.findFirst({ where: { tenantId, login } });
    if (!acct) throw new BtError(BtErrorCode.VALIDATION, 'account not found');
    const data: any = {};
    if (body.leverage != null) data.leverage = body.leverage;
    if (body.enableTrading === true) data.status = 'ACTIVE';
    if (body.enableTrading === false) data.status = 'TRADING_DISABLED';
    if (body.status) data.status = body.status;
    await prisma.account.update({ where: { id: acct.id }, data });
    return { ok: true };
  }

  async stats(tenantId: string, login: string): Promise<CrmTradingStats> {
    const acct = await prisma.account.findFirst({ where: { tenantId, login } });
    if (!acct) throw new BtError(BtErrorCode.VALIDATION, 'account not found');
    const [deals, openCount, closedAgg, lastTrade] = await Promise.all([
      prisma.deal.groupBy({ by: ['type'], where: { tenantId, accountId: acct.id }, _sum: { profit: true } }),
      prisma.position.count({ where: { tenantId, accountId: acct.id, status: 'OPEN' } }),
      prisma.position.aggregate({
        where: { tenantId, accountId: acct.id, status: 'CLOSED' },
        _sum: { profit: true, volume: true },
        _count: true,
      }),
      prisma.deal.findFirst({ where: { tenantId, accountId: acct.id, type: { in: ['OPEN', 'CLOSE'] } }, orderBy: { createdAt: 'desc' } }),
    ]);
    const sumBy = (t: string) => num(deals.find((d) => d.type === t)?._sum.profit);
    const wins = await prisma.position.count({ where: { tenantId, accountId: acct.id, status: 'CLOSED', profit: { gt: 0 } } });
    const totalClosed = closedAgg._count || 0;
    return {
      login,
      totalDeposits: Math.abs(sumByDeal(deals, 'DEPOSIT')),
      totalWithdrawals: Math.abs(sumByDeal(deals, 'WITHDRAWAL')),
      totalBonus: Math.abs(sumByDeal(deals, 'BONUS')),
      totalDividend: Math.abs(sumByDeal(deals, 'DIVIDEND')),
      closedPL: num(closedAgg._sum.profit),
      totalTrades: totalClosed,
      openPositions: openCount,
      volumeLots: num(closedAgg._sum.volume),
      winRate: totalClosed ? wins / totalClosed : 0,
      lastTradeAt: lastTrade?.createdAt.toISOString(),
    };
    void sumBy;
  }

  async changePassword(tenantId: string, login: string, newPassword: string, type: 'MAIN' | 'INVESTOR') {
    const acct = await prisma.account.findFirst({ where: { tenantId, login }, select: { id: true, userId: true } });
    if (!acct) throw new BtError(BtErrorCode.VALIDATION, 'account not found');
    const hash = await bcrypt.hash(newPassword, 10);
    // MAIN password is the trading login password (account-number login).
    // INVESTOR (read-only, spec #3B) grants a view-only session when used.
    if (type === 'MAIN') {
      await prisma.account.update({ where: { id: acct.id }, data: { passwordHash: hash } });
    } else if (type === 'INVESTOR') {
      await prisma.account.update({ where: { id: acct.id }, data: { investorPasswordHash: hash } });
    }
    return { ok: true };
  }

  private toInfo(a: any): CrmAccountInfo {
    return {
      accountId: a.id,
      login: a.login,
      crmUserId: a.crmUserId ?? undefined,
      currency: a.currency,
      leverage: a.leverage,
      status: a.status,
      enabled: a.status === 'ACTIVE',
      balance: num(a.balance),
      credit: num(a.credit),
      equity: num(a.equity),
      margin: num(a.margin),
      freeMargin: num(a.freeMargin),
      marginLevel: num(a.marginLevel),
      floatingPL: num(a.floatingPL),
      bonus: num(a.credit),
      dividend: 0,
    };
  }

  /** Sequential per-tenant login starting at 500000. */
  private async nextLogin(tenantId: string): Promise<string> {
    const last = await prisma.account.findFirst({
      where: { tenantId },
      orderBy: { login: 'desc' },
      select: { login: true },
    });
    const n = last ? parseInt(last.login, 10) + 1 : 500001;
    return String(n);
  }
}

function sumByDeal(groups: { type: string; _sum: { profit: any } }[], type: string): number {
  return Number(groups.find((g) => g.type === type)?._sum.profit ?? 0);
}
