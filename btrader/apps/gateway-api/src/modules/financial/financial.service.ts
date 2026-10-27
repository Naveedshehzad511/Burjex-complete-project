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
    /**
     * WITHDRAWAL only: the reference of the reservation this withdrawal pays out. The reservation is finalized in
     * the SAME transaction as the debit (its amount is not counted against the funds, and is not deducted twice).
     */
    reservationRef?: string;
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

      // The same request may be in flight twice (a retry racing the first call): the check above ran before the
      // lock, so look again now that this call has the account. The second one answers "already done".
      if (params.externalRef) {
        const done = await tx.balanceAdjustment.findUnique({ where: { externalRef: params.externalRef } });
        if (done) return { dealId: done.dealId ?? '', adjId: done.id, balanceAfter: Number(acct.balance), duplicate: true };
      }

      // Funds held for pending withdrawal requests cannot be taken by any other debit (transfer, admin debit,
      // another request). The reservation this very withdrawal pays out is not "other": it is finalized below.
      let reservedByOthers = Number(acct.reservedWithdraw);
      let finalizing: { id: string; amount: number } | null = null;
      if (isDebit && params.reservationRef) {
        const r = await tx.withdrawReservation.findUnique({ where: { externalRef: params.reservationRef } });
        if (r && r.accountId !== acct.id) {
          throw new BtError(BtErrorCode.VALIDATION, 'reservation belongs to another account');
        }
        if (r?.status === 'RELEASED') {
          throw new BtError(BtErrorCode.VALIDATION, 'reservation was released: this withdrawal was rejected');
        }
        if (r?.status === 'RESERVED') {
          if (Math.abs(Number(r.amount) - params.amount) > 1e-8) {
            throw new BtError(BtErrorCode.VALIDATION, `amount ${params.amount} differs from the reserved ${Number(r.amount)}`);
          }
          finalizing = { id: r.id, amount: Number(r.amount) };
          reservedByOthers -= Number(r.amount);
        }
        // No reservation (a request made before reservations existed): paid as before, against the free funds.
      }

      if (isDebit) {
        // Credit is non-withdrawable. Free margin includes credit via equity, so
        // available cash = min(balance, freeMargin) less the funds held for other requests. Never allow balance < 0.
        const balance = Number(acct.balance);
        const freeMargin = (await this.aggregatesUnderLock(tx, acct.id)).freeMargin;
        const available = Math.max(0, Math.min(balance, freeMargin) - Math.max(0, reservedByOthers));
        if (Math.abs(params.amount) > available + 1e-8) {
          throw new BtError(
            BtErrorCode.INSUFFICIENT_FUNDS,
            `insufficient funds: need ${params.amount}, available ${available} (balance ${balance}, freeMargin ${freeMargin}, reserved ${Math.max(0, reservedByOthers)})`,
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
      await tx.account.update({
        where: { id: acct.id },
        data: {
          [field]: newValue,
          ...(finalizing ? { reservedWithdraw: Math.max(0, Number(acct.reservedWithdraw) - finalizing.amount) } : {}),
        } as any,
      });
      if (finalizing) {
        await tx.withdrawReservation.update({
          where: { id: finalizing.id },
          data: { status: 'FINALIZED', settledAt: new Date() },
        });
      }
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
      return { dealId: deal.id, adjId: adj.id, balanceAfter: newValue, duplicate: false };
    });
    if (result.duplicate) return { ok: true, dealId: result.dealId, balanceAfter: result.balanceAfter, duplicate: true };

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
   * Hold `amount` of an account's free funds for a withdrawal request. All-or-nothing and idempotent on
   * `externalRef`: the account row is locked (the engine locks the same row to open a trade), the funds are
   * checked against what is not already reserved, and the reservation row is written in the same transaction.
   * A repeat of the same reference changes nothing, whatever happened to the reservation since.
   */
  async reserveWithdrawal(params: { tenantId: string; login: string; amount: number; externalRef: string }) {
    if (!(params.amount > 0) || !Number.isFinite(params.amount) || params.amount > MAX_ADJUST_AMOUNT) {
      throw new BtError(BtErrorCode.VALIDATION, 'amount must be a positive finite number');
    }
    if (!params.externalRef || typeof params.externalRef !== 'string') {
      throw new BtError(BtErrorCode.VALIDATION, 'externalRef is required');
    }
    const account = await prisma.account.findFirst({ where: { tenantId: params.tenantId, login: params.login } });
    if (!account) throw new BtError(BtErrorCode.VALIDATION, 'account not found');
    return prisma.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT id FROM accounts WHERE id = ${account.id} FOR UPDATE`;
      const acct = await tx.account.findUniqueOrThrow({ where: { id: account.id } });
      const existing = await tx.withdrawReservation.findUnique({ where: { externalRef: params.externalRef } });
      if (existing) {
        return { ok: true, duplicate: true, status: existing.status, reserved: Number(acct.reservedWithdraw) };
      }
      // Free margin as of NOW, read under the lock: the engine commits every trade under the same lock, so a
      // trade that won the race is already in these positions. (The stored value can be a moment stale.)
      const live = await this.aggregatesUnderLock(tx, acct.id);
      const balance = Number(acct.balance);
      const freeMargin = live.freeMargin;
      const reserved = Number(acct.reservedWithdraw);
      const available = Math.max(0, Math.min(balance, freeMargin) - reserved);
      if (params.amount > available + 1e-8) {
        throw new BtError(
          BtErrorCode.INSUFFICIENT_FUNDS,
          `insufficient funds to reserve: need ${params.amount}, available ${available} (balance ${balance}, freeMargin ${freeMargin}, reserved ${reserved})`,
        );
      }
      await tx.withdrawReservation.create({
        data: { tenantId: params.tenantId, accountId: acct.id, externalRef: params.externalRef, amount: params.amount },
      });
      const reservedAfter = reserved + params.amount;
      await tx.account.update({ where: { id: acct.id }, data: { reservedWithdraw: reservedAfter } });
      return { ok: true, duplicate: false, status: 'RESERVED', reserved: reservedAfter };
    });
  }

  /**
   * Give a reservation back (the request was rejected, or never got saved). Exactly once: only a RESERVED row is
   * released; a repeat, an unknown reference and an already FINALIZED one change nothing and say so.
   */
  async releaseWithdrawal(params: { tenantId: string; login: string; externalRef: string }) {
    if (!params.externalRef || typeof params.externalRef !== 'string') {
      throw new BtError(BtErrorCode.VALIDATION, 'externalRef is required');
    }
    const account = await prisma.account.findFirst({ where: { tenantId: params.tenantId, login: params.login } });
    if (!account) throw new BtError(BtErrorCode.VALIDATION, 'account not found');
    return prisma.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT id FROM accounts WHERE id = ${account.id} FOR UPDATE`;
      const acct = await tx.account.findUniqueOrThrow({ where: { id: account.id } });
      const r = await tx.withdrawReservation.findUnique({ where: { externalRef: params.externalRef } });
      if (!r || r.accountId !== acct.id) {
        return { ok: true, released: false, status: 'NONE', reserved: Number(acct.reservedWithdraw) };
      }
      if (r.status !== 'RESERVED') {
        return { ok: true, released: false, status: r.status, reserved: Number(acct.reservedWithdraw) };
      }
      const reservedAfter = Math.max(0, Number(acct.reservedWithdraw) - Number(r.amount));
      await tx.withdrawReservation.update({ where: { id: r.id }, data: { status: 'RELEASED', settledAt: new Date() } });
      await tx.account.update({ where: { id: acct.id }, data: { reservedWithdraw: reservedAfter } });
      return { ok: true, released: true, status: 'RELEASED', reserved: reservedAfter };
    });
  }

  /**
   * Equity / margin / free margin of an account from its committed balance, credit and OPEN positions, computed
   * and stored INSIDE a transaction that already holds the account's row lock. Use it for any check that decides
   * whether funds are free: the stored `freeMargin` is only refreshed now and then and can be a moment stale.
   */
  private async aggregatesUnderLock(tx: any, accountId: string) {
    const acct = await tx.account.findUniqueOrThrow({ where: { id: accountId }, select: { balance: true, credit: true } });
    const positions = await tx.position.findMany({
      where: { accountId, status: 'OPEN' },
      select: { profit: true, swap: true, commission: true, marginUsed: true },
    });
    let floating = 0;
    let margin = 0;
    for (const p of positions) {
      floating += Number(p.profit) + Number(p.swap) + Number(p.commission);
      margin += Number(p.marginUsed);
    }
    const equity = Number(acct.balance) + Number(acct.credit) + floating;
    const freeMargin = equity - margin;
    const marginLevel = margin > 0 ? (equity / margin) * 100 : 0;
    await tx.account.update({
      where: { id: accountId },
      data: { equity, margin, freeMargin, marginLevel, floatingPL: floating },
    });
    return { equity, margin, freeMargin };
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
