import {
  marketExecutionDelayMs,
  protectiveHit,
  onProtectiveHit,
  onProtectiveClose,
  onUserClose,
  preferStatus,
  staleOpenBlocked,
} from '@btrader/engine-core';
import {
  payloadClosed,
  coalescePosition,
  reconcileOpenSnapshot,
  overlayDropsChart,
  forceClosed,
} from '@btrader/shared';

const marketPricing = {
  executionMode: 'MARKET' as const,
  executionDelayMs: 150,
  executionApplyTo: { sl: true, tp: true, marketBuy: true, buyStop: true },
};

describe('BUY/SELL SL/TP on the authoritative tick', () => {
  test('BUY SL hits on bid', () => {
    expect(protectiveHit('BUY', 1.099, 1.0992, 1.1, null)).toEqual({ hit: 'SL', level: 1.1 });
  });
  test('SELL SL hits on ask', () => {
    expect(protectiveHit('SELL', 1.1008, 1.101, 1.1, null)).toEqual({ hit: 'SL', level: 1.1 });
  });
  test('BUY TP hits on bid', () => {
    expect(protectiveHit('BUY', 1.21, 1.2102, null, 1.2)).toEqual({ hit: 'TP', level: 1.2 });
  });
  test('SELL TP hits on ask', () => {
    expect(protectiveHit('SELL', 1.189, 1.1892, null, 1.2)).toEqual({ hit: 'TP', level: 1.2 });
  });
  test('no hit inside the levels', () => {
    expect(protectiveHit('BUY', 1.105, 1.1052, 1.1, 1.12).hit).toBeNull();
    expect(protectiveHit('SELL', 1.105, 1.1052, 1.12, 1.09).hit).toBeNull();
  });
});

describe('group execution_ms after SL/TP trigger', () => {
  test('SL/TP wait the configured MARKET delay', () => {
    expect(marketExecutionDelayMs(marketPricing, 'sl')).toBe(150);
    expect(marketExecutionDelayMs(marketPricing, 'tp')).toBe(150);
  });
  test('pending fills still skip delay', () => {
    expect(marketExecutionDelayMs(marketPricing, 'buyStop')).toBe(0);
  });
  test('INSTANT is 0', () => {
    expect(
      marketExecutionDelayMs({ ...marketPricing, executionMode: 'INSTANT' }, 'sl'),
    ).toBe(0);
  });
  test('unchecked apply-to is 0', () => {
    expect(
      marketExecutionDelayMs({ ...marketPricing, executionApplyTo: { sl: false, tp: true } }, 'sl'),
    ).toBe(0);
    expect(
      marketExecutionDelayMs({ ...marketPricing, executionApplyTo: { sl: false, tp: true } }, 'tp'),
    ).toBe(150);
  });
});

describe('OPEN → CLOSE_PENDING → CLOSED is atomic/idempotent', () => {
  test('first tick claims OPEN', () => {
    expect(onProtectiveHit('OPEN')).toBe('claim');
  });
  test('duplicate close / second hit is ignored', () => {
    expect(onProtectiveHit('CLOSE_PENDING')).toBe('ignore');
    expect(onProtectiveHit('CLOSED')).toBe('ignore');
    expect(onProtectiveClose('CLOSED')).toBe('ignore');
    expect(onUserClose('CLOSE_PENDING')).toBe('ignore');
    expect(onUserClose('CLOSED')).toBe('ignore');
    expect(onProtectiveClose('CLOSE_PENDING')).toBe('close');
  });
});

describe('stale OPEN cannot resurrect a closed ticket', () => {
  test('coalesce keeps CLOSED over a later OPEN', () => {
    const closed = new Set<string>();
    const still = (id: string) => closed.has(id);
    const remember = (id: string) => closed.add(id);
    const first = coalescePosition(
      undefined,
      { id: 'p1', status: 'CLOSED', event: 'position_closed' },
      still,
      remember,
    );
    expect(payloadClosed(first)).toBe(true);
    const next = coalescePosition(first, { id: 'p1', status: 'OPEN', profit: 12 }, still, remember);
    expect(payloadClosed(next)).toBe(true);
    expect((next as { status: string }).status).toBe('CLOSED');
  });
  test('CLOSE_PENDING is not treated as closed', () => {
    expect(payloadClosed({ id: 'p1', status: 'CLOSE_PENDING' })).toBe(false);
    expect(preferStatus('OPEN', 'CLOSE_PENDING')).toBe('CLOSE_PENDING');
    expect(preferStatus('CLOSED', 'OPEN')).toBe('CLOSED');
  });
  test('staleOpenBlocked', () => {
    expect(staleOpenBlocked('p1', 'OPEN', ['p1'])).toBe(true);
    expect(staleOpenBlocked('p1', 'OPEN', ['p2'])).toBe(false);
  });
});

describe('reconnect snapshot + chart overlay removal', () => {
  test('reconnect drops tickets the server no longer has open', () => {
    const snap = [
      { id: 'keep', status: 'OPEN' },
      { id: 'pending', status: 'CLOSE_PENDING' },
      { id: 'gone', status: 'OPEN' },
    ];
    const out = reconcileOpenSnapshot(snap, ['gone']);
    expect(out.map((p: { id: string }) => p.id)).toEqual(['keep', 'pending']);
  });
  test('empty snapshot is a real reconcile (all closed while disconnected)', () => {
    expect(reconcileOpenSnapshot([], [])).toEqual([]);
  });
  test('chart drops marker/SL/TP on position_closed', () => {
    expect(overlayDropsChart('p1', { id: 'p1', status: 'CLOSED', event: 'position_closed' }, [])).toBe(true);
    expect(overlayDropsChart('p1', { id: 'p1', status: 'CLOSE_PENDING' }, [])).toBe(false);
    expect(overlayDropsChart('p1', { id: 'p1', status: 'OPEN' }, ['p1'])).toBe(true);
  });
  test('forceClosed stamps position_closed', () => {
    expect(forceClosed({ id: 'p1' }, 'p1').event).toBe('position_closed');
  });
});
