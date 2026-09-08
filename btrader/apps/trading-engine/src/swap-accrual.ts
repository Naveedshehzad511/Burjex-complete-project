// ============================================================================
//  Overnight swap accrual.
//
//  Lives outside main.ts so it can be integration-tested: importing main.ts
//  boots the whole service (Redis subscriptions, tick consumers).
// ============================================================================

import { prisma } from '@btrader/db';
import { swapDayStart, isRolloverHour, swapMultiplier } from './swap-schedule';

const ROLLOVER_HOUR = Number(process.env.SWAP_ROLLOVER_HOUR ?? 22); // UTC

export async function maybeApplySwaps(): Promise<void> {
  const now = new Date();
  if (!isRolloverHour(now, ROLLOVER_HOUR)) return;
  // No in-memory "already ran today" flag: it does not survive a restart, and a
  // restart inside the rollover hour used to accrue every position a second
  // time. Idempotency is now enforced per position against the SWAP deal
  // ledger, which also makes a crash mid-run safe to resume.
  await applySwaps(now);
}

export async function applySwaps(now: Date): Promise<void> {
  const dayStart = swapDayStart(now);

  const positions = await prisma.position.findMany({ where: { status: 'OPEN' }, include: { symbol: true } });

  // Cheap pre-filter so a re-run inside the rollover hour does not open a
  // transaction per position. The authoritative check is inside the TX below.
  const alreadySwapped = new Set(
    (
      await prisma.deal.findMany({
        where: { type: 'SWAP', createdAt: { gte: dayStart }, positionId: { not: null } },
        select: { positionId: true },
        distinct: ['positionId'],
      })
    ).map((row) => row.positionId as string),
  );

  let count = 0;
  let skipped = 0;
  for (const p of positions) {
    const sym = p.symbol;
    const rate = Number(p.side === 'BUY' ? sym.swapLong : sym.swapShort);
    if (!rate) continue;
    if (alreadySwapped.has(p.id)) {
      skipped++;
      continue;
    }
    const multiplier = swapMultiplier(now, sym.swap3DayWeekday); // triple-swap day

    const applied = await prisma.$transaction(async (tx) => {
      // Lock the position so two runs (or two engine instances) cannot both
      // pass the "not swapped yet" check for the same position.
      await tx.$queryRaw`SELECT id FROM positions WHERE id = ${p.id} FOR UPDATE`;

      const dup = await tx.deal.findFirst({
        where: { positionId: p.id, type: 'SWAP', createdAt: { gte: dayStart } },
        select: { id: true },
      });
      if (dup) return false;

      // Re-read: the position may have closed between the scan and this lock.
      const fresh = await tx.position.findUnique({ where: { id: p.id } });
      if (!fresh || fresh.status !== 'OPEN') return false;

      const swapAmount = rate * Number(fresh.volume) * multiplier; // accrues on the position
      const acct = await tx.account.findUnique({ where: { id: fresh.accountId } });

      await tx.position.update({
        where: { id: fresh.id },
        data: { swap: Number(fresh.swap) + swapAmount },
      });
      await tx.deal.create({
        data: {
          tenantId: fresh.tenantId,
          accountId: fresh.accountId,
          positionId: fresh.id,
          symbolId: sym.id,
          type: 'SWAP',
          swap: swapAmount,
          profit: 0,
          balanceAfter: acct ? Number(acct.balance) : 0,
          comment: 'Overnight swap',
          // Stamp from `now`, not the DB default. This row IS the idempotency
          // marker and it is matched against swapDayStart(now); letting it
          // default to the database clock means the marker and the window it
          // must fall inside come from two different clocks. Any disagreement
          // — drift, or a deliberate backfill with a historical date — puts the
          // marker outside its own window and silently re-enables the
          // double-accrual this check exists to prevent.
          createdAt: now,
        },
      });
      return true;
    });

    if (applied) count++;
    else skipped++;
  }
  console.log(`[trading-engine] swaps applied to ${count} open positions (${skipped} already accrued today)`);
}
