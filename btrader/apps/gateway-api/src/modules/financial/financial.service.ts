import { Injectable } from '@nestjs/common';
import { prisma } from '@btrader/db';
import { BtError, BtErrorCode } from '@btrader/shared';

type OpType = 'DEPOSIT' | 'WITHDRAWAL' | 'BONUS' | 'DIVIDEND' | 'CREDIT' | 'CORRECTION' | 'MANUAL';

const MAX_ADJUST_AMOUNT = 1e12;

/**
 * Authoritative money movements that are NOT trade P/L: deposits, withdrawals,
 * bonus, dividend, manual adjustments. Idempotent on externalRef so CRM retries
 * never double-apply. BONUS/CREDIT move `credit` (non-withdrawable); everything
 * else moves `balance`. WITHDRAWAL checks available = min(balance, freeMargin)
 * so credit cannot be cashed out and margin-locked funds cannot be withdrawn.
 */
@Injectable()
export class FinancialService {
  async adjust(params: {
    tenantId: string;
    login?: string;
    accountId?: string;
    type: OpType;
    amount: number; // positive magnitude
    comment?: string;
    externalRef?: string;
    performedBy?: string;
  }) {
    if (!(params.amount > 0) || !Number.isFinite(params.amount) || params.amount > MAX_ADJUST_AMOUNT) {
      throw new BtError(BtErrorCode.VALIDATION, 'amount must be a positive finite number');
    }

    const account = await prisma.account.findFirst({
      where: {
        tenantId: params.tenantId,
        ...(params.accountId ? { id: params.accountId } : { login: params.login }),
      },
    });
    if (!account) throw new BtError(BtErrorCode.VALIDATION, 'account not found');

    // Idempotency: if this externalRef already processed, return prior result.
    if (params.externalRef) {
      const existing = await prisma.balanceAdjustment.findUnique({
        where: { externalRef: params.externalRef },
      });
      if (existing) {
        const acct = await prisma.account.findUniqueOrThrow({ where: { id: account.id } });
        return { ok: true, dealId: existing.dealId ?? '', balanceAfter: Number(acct.balance), duplicate: true };
      }
    }

    const isCredit = params.type === 'BONUS' || params.type === 'CREDIT';
    const isDebit = params.type === 'WITHDRAWAL';
    const signed = isDebit ? -Math.abs(params.amount) : Math.abs(params.amount);

    if (isDebit) {
      // Refresh stored aggregates so floating P/L is reflected before the TX.
      await this.recomputeAggregates(account.id);
    }

    const result = await prisma.$transaction(async (tx) => {
      // Serialize with trading opens that also lock accounts FOR UPDATE.
      await tx.$queryRaw`SELECT id FROM accounts WHERE id = ${account.id} FOR UPDATE`;
      const acct = await tx.account.findUniqueOrThrow({ where: { id: account.id } });

      if (isDebit) {
        // Credit is non-withdrawable. Free margin includes credit via equity, so
        // available cash = min(balance, freeMargin). Never allow balance < 0.
        const balance = Number(acct.balance);
        const freeMargin = Number(acct.freeMargin);
        const available = Math.max(0, Math.min(balance, freeMargin));
        if (Math.abs(params.amount) > available + 1e-8) {
          throw new BtError(
            BtErrorCode.INSUFFICIENT_FUNDS,
            `insufficient funds: need ${params.amount}, available ${available} (balance ${balance}, freeMargin ${freeMargin})`,
          );
        }
      }

      const field = isCredit ? 'credit' : 'balance';
      const newValue = Number(acct[field as 'balance' | 'credit']) + signed;
      if (!isCredit && newValue < -1e-8) {
        throw new BtError(BtErrorCode.INSUFFICIENT_FUNDS, 'negative balance is not allowed');
      }
      const newBalance = isCredit ? Number(acct.balance) : newValue;

      const deal = await tx.deal.create({
        data: {
          tenantId: params.tenantId,
          accountId: acct.id,
          type: mapDealType(params.type),
          profit: 0,
          balanceAfter: newBalance,
          comment: params.comment,
          externalRef: params.externalRef,
        },
      });
      await tx.account.update({ where: { id: acct.id }, data: { [field]: newValue } as any });
      const adj = await tx.balanceAdjustment.create({
        data: {
          tenantId: params.tenantId,
          accountId: acct.id,
          type: (params.type === 'MANUAL' ? 'MANUAL' : params.type) as any,
          amount: signed,
          currency: acct.currency,
          comment: params.comment,
          externalRef: params.externalRef,
          performedBy: params.performedBy,
          dealId: deal.id,
        },
      });
      return { dealId: deal.id, adjId: adj.id, balanceAfter: newValue };
    });

    // Recompute aggregates so equity/free-margin reflect the new balance. Without
    // this a deposit updates `balance` but leaves equity/freeMargin at their stale
    // value (0 for a fresh account) → the client shows Equity 0 / Floating −balance.
    await this.recomputeAggregates(account.id);

    // Push CRM webhook so broker CRM Admin + app Home stay in sync without polling.
    try {
      const snap = await prisma.account.findUnique({
        where: { id: account.id },
        select: {
          login: true,
          balance: true,
          credit: true,
          equity: true,
          margin: true,
          freeMargin: true,
          marginLevel: true,
          floatingPL: true,
          currency: true,
          leverage: true,
          status: true,
        },
      });
      if (snap) {
        await prisma.crmSyncOutbox.create({
          data: {
            tenantId: params.tenantId,
            eventType: 'account.snapshot',
            payload: {
              login: snap.login,
              balance: Number(snap.balance),
              credit: Number(snap.credit),
              equity: Number(snap.equity),
              margin: Number(snap.margin),
              freeMargin: Number(snap.freeMargin),
              marginLevel: Number(snap.marginLevel),
              floatingPL: Number(snap.floatingPL),
              currency: snap.currency,
              leverage: snap.leverage,
              status: snap.status,
              dealId: result.dealId,
              type: params.type,
            },
          },
        });
      }
    } catch {
      // Outbox failure must not roll back a successful money movement.
    }

    return { ok: true, dealId: result.dealId, balanceAfter: result.balanceAfter, duplicate: false };
  }

  /**
   * Recompute an account's live aggregates from its balance/credit plus any OPEN
   * positions' stored P/L (the engine maintains position.profit on each tick).
   *   equity      = balance + credit + Σ(profit + swap + commission)
   *   margin      = Σ marginUsed
   *   freeMargin  = equity − margin
   *   marginLevel = margin > 0 ? equity/margin*100 : 0
   * For a flat account this yields equity = balance, freeMargin = balance,
   * floatingPL = 0 (fixing the "Equity 0 / Floating −balance" display).
   */
  async recomputeAggregates(accountId: string): Promise<void> {
    const acct = await prisma.account.findUnique({
      where: { id: accountId },
      select: { balance: true, credit: true },
    });
    if (!acct) return;
    const positions = await prisma.position.findMany({
      where: { accountId, status: 'OPEN' },
      select: { profit: true, swap: true, commission: true, marginUsed: true },
    });
    let floating = 0;
    let margin = 0;
    for (const p of positions) {
      floating += Number(p.profit) + Number(p.swap) + Number(p.commission);
      margin += Number(p.marginUsed);
    }
    const balance = Number(acct.balance);
    const credit = Number(acct.credit);
    const equity = balance + credit + floating;
    const freeMargin = equity - margin;
    const marginLevel = margin > 0 ? (equity / margin) * 100 : 0;
    await prisma.account.update({
      where: { id: accountId },
      data: { equity, margin, freeMargin, marginLevel, floatingPL: floating },
    });
  }
}

function mapDealType(t: OpType) {
  switch (t) {
    case 'DEPOSIT': return 'DEPOSIT';
    case 'WITHDRAWAL': return 'WITHDRAWAL';
    case 'BONUS': return 'BONUS';
    case 'DIVIDEND': return 'DIVIDEND';
    case 'CREDIT': return 'CREDIT';
    default: return 'BALANCE';
  }
}
