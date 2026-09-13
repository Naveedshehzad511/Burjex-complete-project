// ============================================================================
//  Trading Engine worker (Node): overnight swaps, CRM outbox, auto net-hedge.
//  Market/pending/SL/TP matching lives in the Rust matching engine. This process
//  must NOT subscribe ticks into TradingEngine.onTickFast.
// ============================================================================

import Redis from 'ioredis';
import * as crypto from 'crypto';
import { prisma } from '@btrader/db';
import { maybeApplySwaps } from './swap-accrual';
import { autoHedgeSweep } from './auto-hedge';

const REDIS_URL = process.env.REDIS_URL ?? 'redis://localhost:6380';

async function main() {
  const redis = new Redis(REDIS_URL);

  setInterval(() => drainCrmOutbox().catch((e) => console.error('[outbox]', e?.message)), 2000);
  console.log('[trading-engine] CRM outbox worker active (per-tenant webhooks)');

  setInterval(() => maybeApplySwaps().catch((e) => console.error('[swaps]', e?.message)), 60_000);

  const autoHedgeSec = Math.max(5, Number(process.env.AUTOHEDGE_INTERVAL_SEC ?? 15));
  setInterval(() => autoHedgeSweep(redis).catch((e) => console.error('[autohedge]', e?.message)), autoHedgeSec * 1000);
  console.log(`[trading-engine] auto net-hedge sweep every ${autoHedgeSec}s (matching is Rust)`);

  console.log('[trading-engine] running (swaps + outbox + autohedge; no tick matching)');
}

async function drainCrmOutbox(): Promise<void> {
  const due = await prisma.crmSyncOutbox.findMany({
    where: { status: 'PENDING', nextAttempt: { lte: new Date() } },
    orderBy: { createdAt: 'asc' },
    take: 50,
  });
  for (const evt of due) {
    try {
      await deliverToCrm(evt);
      await prisma.crmSyncOutbox.update({
        where: { id: evt.id },
        data: { status: 'SENT', sentAt: new Date() },
      });
    } catch (e: any) {
      const attempts = evt.attempts + 1;
      const backoffSec = Math.min(2 ** attempts, 300);
      await prisma.crmSyncOutbox.update({
        where: { id: evt.id },
        data: {
          attempts,
          lastError: String(e?.message ?? e),
          nextAttempt: new Date(Date.now() + backoffSec * 1000),
          status: attempts >= 10 ? 'FAILED' : 'PENDING',
        },
      });
    }
  }
}

async function deliverToCrm(evt: {
  id: string;
  tenantId: string;
  eventType: string;
  payload: unknown;
  createdAt: Date;
}): Promise<void> {
  const cfg = await prisma.crmConfig.findUnique({ where: { tenantId: evt.tenantId } });
  const url = cfg?.enabled ? cfg.webhookUrl : null;
  const fallbackUrl = process.env.CRM_WEBHOOK_URL ?? null;
  const target = url ?? fallbackUrl;
  if (!target) return;
  const secret = (cfg?.enabled ? cfg.webhookSecret : null) ?? process.env.CRM_WEBHOOK_SECRET ?? '';
  if (cfg?.enabled && cfg.events.length && !cfg.events.includes(evt.eventType)) return;

  const body = JSON.stringify({
    id: evt.id,
    tenantId: evt.tenantId,
    type: evt.eventType,
    occurredAt: evt.createdAt.toISOString(),
    data: evt.payload,
  });
  const ts = Date.now().toString();
  const sig = crypto.createHmac('sha256', secret).update(`${ts}.${body}`).digest('hex');
  const res = await fetch(target, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-BT-Timestamp': ts, 'X-BT-Signature': sig },
    body,
  });
  if (!res.ok) throw new Error(`CRM webhook responded ${res.status}`);
}

main().catch((e) => {
  console.error('[trading-engine] fatal', e);
  process.exit(1);
});
