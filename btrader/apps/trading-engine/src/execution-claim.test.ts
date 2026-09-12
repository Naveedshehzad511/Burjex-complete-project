import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import {
  applyProtectiveTick,
  emptyLatch,
  MemoryClaimStore,
  raceClaims,
} from '../../../packages/engine-core/src/execution-claim.ts';
import { protectiveHit } from '../../../packages/engine-core/src/trigger.ts';

describe('SL/TP latch: reversal cannot cancel a claimed close', () => {
  test('critical regression: Bid through SL then immediately reverses — still claimed', () => {
    let s = emptyLatch();
    s = applyProtectiveTick(s, { side: 'BUY', bid: 2499.98, ask: 2500.1, sl: 2500, tp: 2510 });
    assert.equal(s.claimed, true);
    assert.equal(s.kind, 'sl');
    const after = applyProtectiveTick(s, { side: 'BUY', bid: 2500.1, ask: 2500.22, sl: 2500, tp: 2510 });
    assert.equal(after.claimed, true);
    assert.equal(after.kind, 'sl');
    assert.equal(after.closed, false);
  });

  test('TP latch survives reversal', () => {
    let s = emptyLatch();
    s = applyProtectiveTick(s, { side: 'BUY', bid: 2510.01, ask: 2510.2, sl: 2490, tp: 2510 });
    assert.equal(s.kind, 'tp');
    s = applyProtectiveTick(s, { side: 'BUY', bid: 2509, ask: 2509.2, sl: 2490, tp: 2510 });
    assert.equal(s.claimed, true);
    assert.equal(s.kind, 'tp');
  });

  test('gap through SL still latches; later ticks ignored', () => {
    let s = emptyLatch();
    s = applyProtectiveTick(s, { side: 'BUY', bid: 2480, ask: 2480.2, sl: 2500, tp: 2520 });
    assert.equal(s.claimed, true);
    for (let i = 0; i < 1000; i++) {
      s = applyProtectiveTick(s, { side: 'BUY', bid: 2510, ask: 2510.2, sl: 2500, tp: 2520 });
    }
    assert.equal(s.kind, 'sl');
  });

  test('thousands of reverse-after-hit cycles stay claimed', () => {
    let claimed = 0;
    let cancelled = 0;
    for (let i = 0; i < 5000; i++) {
      let s = emptyLatch();
      s = applyProtectiveTick(s, { side: 'BUY', bid: 2499.9, ask: 2500, sl: 2500, tp: 2510 });
      s = applyProtectiveTick(s, { side: 'BUY', bid: 2500.4, ask: 2500.5, sl: 2500, tp: 2510 });
      if (s.claimed) claimed++;
      else cancelled++;
    }
    assert.equal(claimed, 5000);
    assert.equal(cancelled, 0);
  });
});

describe('two-engine / concurrent claim', () => {
  test('exactly one worker wins a shared claim', () => {
    const store = new MemoryClaimStore();
    const results = raceClaims(store, 'pos-1', 8, 'sl');
    assert.equal(results.filter((r) => r === 'claimed').length, 1);
    assert.equal(results.filter((r) => r === 'already_claimed').length, 7);
  });

  test('5000 positions × 2 engines → 5000 claims, 0 doubles', () => {
    const store = new MemoryClaimStore();
    let claimed = 0;
    let dup = 0;
    for (let i = 0; i < 5000; i++) {
      const a = store.claim(`p${i}`, {
        kind: 'sl',
        claimedBy: 'gw',
        triggerWall: 1,
        deadlineWall: 1,
        delayMs: 50,
      });
      const b = store.claim(`p${i}`, {
        kind: 'sl',
        claimedBy: 'eng',
        triggerWall: 1,
        deadlineWall: 1,
        delayMs: 50,
      });
      if (a === 'claimed') claimed++;
      if (b === 'claimed') dup++;
    }
    assert.equal(claimed, 5000);
    assert.equal(dup, 0);
    assert.equal(store.size, 5000);
  });
});

describe('protectiveHit Bid/Ask (authoritative rules unchanged)', () => {
  test('long uses Bid, short uses Ask', () => {
    assert.equal(protectiveHit({ side: 'BUY', bid: 2499.98, ask: 2500.5, sl: 2500 }).hit, 'SL');
    assert.equal(protectiveHit({ side: 'SELL', bid: 2499, ask: 2500.01, sl: 2500 }).hit, 'SL');
  });
});
