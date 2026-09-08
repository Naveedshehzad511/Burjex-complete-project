import { pendingFires, protectiveHit, clampLimitFill, isLimitFillType } from '@btrader/engine-core';
import { PendingBook } from '@btrader/engine-core';
import { sessionClosesAt } from '@btrader/engine-core';
import { shardOfTenant } from '@btrader/engine-core';

describe('pending Bid/Ask crossing (checklist §3, §5)', () => {
  test('Buy Stop fires on Ask cross, not exact tick', () => {
    expect(
      pendingFires({ type: 'BUY_STOP', side: 'BUY', bid: 1.0998, ask: 1.1, trigger: 1.1 }),
    ).toBe('fill');
  });

  test('gap: Buy Stop 1.10000, market 1.09980 → 1.10050 still fills', () => {
    expect(
      pendingFires({ type: 'BUY_STOP', side: 'BUY', bid: 1.0997, ask: 1.0998, trigger: 1.1 }),
    ).toBe('none');
    expect(
      pendingFires({ type: 'BUY_STOP', side: 'BUY', bid: 1.1004, ask: 1.1005, trigger: 1.1 }),
    ).toBe('fill');
  });

  test('Buy Limit uses Ask, Sell Limit uses Bid', () => {
    expect(pendingFires({ type: 'BUY_LIMIT', side: 'BUY', bid: 1.1, ask: 1.1002, trigger: 1.1001 })).toBe(
      'none',
    );
    expect(pendingFires({ type: 'BUY_LIMIT', side: 'BUY', bid: 1.099, ask: 1.0995, trigger: 1.1 })).toBe(
      'fill',
    );
    expect(pendingFires({ type: 'SELL_LIMIT', side: 'SELL', bid: 1.101, ask: 1.1012, trigger: 1.1 })).toBe(
      'fill',
    );
  });

  test('Sell Stop uses Bid', () => {
    expect(pendingFires({ type: 'SELL_STOP', side: 'SELL', bid: 1.1, ask: 1.1002, trigger: 1.1 })).toBe(
      'fill',
    );
    expect(pendingFires({ type: 'SELL_STOP', side: 'SELL', bid: 1.1001, ask: 1.1003, trigger: 1.1 })).toBe(
      'none',
    );
  });
});

describe('STOP_LIMIT two-stage', () => {
  test('arms when stop hits but limit has not', () => {
    expect(
      pendingFires({
        type: 'STOP_LIMIT',
        side: 'BUY',
        bid: 1.1,
        ask: 1.1005,
        trigger: 1.1,
        stopPrice: 1.1,
        limitPrice: 1.099,
        stopTriggered: false,
      }),
    ).toBe('arm_stop_limit');
  });

  test('gap through both stop and limit fills immediately', () => {
    expect(
      pendingFires({
        type: 'STOP_LIMIT',
        side: 'BUY',
        bid: 1.1004,
        ask: 1.1005,
        trigger: 1.1,
        stopPrice: 1.1,
        limitPrice: 1.101,
        stopTriggered: false,
      }),
    ).toBe('fill');
  });

  test('after arm, waits for limit', () => {
    expect(
      pendingFires({
        type: 'STOP_LIMIT',
        side: 'BUY',
        bid: 1.102,
        ask: 1.1025,
        trigger: 1.1,
        stopPrice: 1.1,
        limitPrice: 1.101,
        stopTriggered: true,
      }),
    ).toBe('none');
    expect(
      pendingFires({
        type: 'STOP_LIMIT',
        side: 'BUY',
        bid: 1.1,
        ask: 1.1005,
        trigger: 1.1,
        stopPrice: 1.1,
        limitPrice: 1.101,
        stopTriggered: true,
      }),
    ).toBe('fill');
  });
});

describe('SL/TP Bid/Ask (MT5: long uses Bid, short uses Ask)', () => {
  test('Buy SL triggers on Bid through the level', () => {
    expect(protectiveHit({ side: 'BUY', bid: 1.099, ask: 1.0995, sl: 1.1, tp: 1.12 }).hit).toBe('SL');
    expect(protectiveHit({ side: 'BUY', bid: 1.101, ask: 1.1015, sl: 1.1, tp: 1.12 }).hit).toBe(null);
  });

  test('Sell SL triggers on Ask through the level', () => {
    expect(protectiveHit({ side: 'SELL', bid: 1.099, ask: 1.101, sl: 1.1, tp: 1.08 }).hit).toBe('SL');
  });

  test('gap through SL still hits; SL wins over TP on the same tick', () => {
    expect(protectiveHit({ side: 'BUY', bid: 1.05, ask: 1.0505, sl: 1.1, tp: 1.04 }).hit).toBe('SL');
  });
});

describe('limit clamp and books', () => {
  test('BUY limit fill never worse than limit', () => {
    expect(clampLimitFill('BUY', 1.105, 1.1)).toBe(1.1);
    expect(clampLimitFill('BUY', 1.099, 1.1)).toBe(1.099);
  });

  test('pending book hydrate / reconcile', () => {
    const b = new PendingBook();
    b.load([
      {
        id: '1',
        tenantId: 't',
        accountId: 'a',
        symbolId: 's',
        side: 'BUY',
        type: 'BUY_STOP',
        status: 'PENDING',
        volume: 0.1,
        price: 1.1,
        stopPrice: 1.1,
        slPrice: null,
        tpPrice: null,
        expiresAt: null,
        updatedAt: new Date(),
        stopTriggered: false,
      },
    ]);
    expect(b.forSymbol('t', 's')).toHaveLength(1);
    expect(b.reconcile([])).toEqual({ missing: 0, stale: 0, extra: 1 });
    expect(b.size).toBe(0);
  });

  test('isLimitFillType', () => {
    expect(isLimitFillType('BUY_LIMIT')).toBe(true);
    expect(isLimitFillType('BUY_STOP')).toBe(false);
  });
});

describe('DAY session close + sharding', () => {
  test('crypto DAY expires at next UTC midnight', () => {
    const now = new Date(Date.UTC(2026, 8, 8, 15, 0, 0));
    const close = sessionClosesAt(null, 'CRYPTO', now);
    expect(close.toISOString()).toBe('2026-09-09T00:00:00.000Z');
  });

  test('same tenant always maps to the same shard', () => {
    const id = 'tenant-abc';
    expect(shardOfTenant(id, 4)).toBe(shardOfTenant(id, 4));
    expect(shardOfTenant(id, 1)).toBe(0);
  });
});

describe('fast-market burst (10k evaluations, no lost crosses)', () => {
  test('once Ask crosses the stop, every later tick still reports fill', () => {
    let first = -1;
    let fires = 0;
    for (let i = 0; i < 10_000; i++) {
      const ask = 1.099 + i * 0.0000004;
      if (pendingFires({ type: 'BUY_STOP', side: 'BUY', bid: ask - 0.0001, ask, trigger: 1.1 }) === 'fill') {
        if (first < 0) first = i;
        fires++;
      }
    }
    expect(first).toBeGreaterThan(0);
    expect(fires).toBe(10_000 - first);
  });
});
