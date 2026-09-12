import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import {
  createExecutionPlan,
  waitForDeadline,
  captureTrigger,
  closeApplyKind,
} from '../../../packages/engine-core/src/execution-policy.ts';
import { marketExecutionDelayMs, executionApplies, type GroupPricing } from '../../../packages/engine-core/src/calc.ts';

function pricing(over: Partial<GroupPricing> = {}): GroupPricing {
  return {
    markupPoints: 0,
    slippagePoints: 0,
    commissionType: 'NONE',
    commissionValue: 0,
    executionMode: 'MARKET',
    executionDelayMs: 200,
    executionApplyTo: {},
    ...over,
  };
}

describe('central execution deadline (never hard-coded)', () => {
  for (const ms of [50, 200, 500]) {
    test(`MARKET uses group executionDelayMs=${ms}`, () => {
      const t0 = 1000;
      const plan = createExecutionPlan({
        pricing: pricing({ executionDelayMs: ms }),
        kind: 'sl',
        triggerMono: t0,
        triggerWall: 0,
      });
      assert.equal(plan.delayMs, ms);
      assert.equal(plan.deadlineMono, t0 + ms);
    });
  }

  test('apply-to off → delay 0 even if executionDelayMs is set', () => {
    const p = pricing({
      executionDelayMs: 500,
      executionApplyTo: { sl: false, tp: true, marketBuy: true },
    });
    assert.equal(marketExecutionDelayMs(p, 'sl'), 0);
    assert.equal(marketExecutionDelayMs(p, 'tp'), 500);
  });

  test('INSTANT mode never waits', () => {
    const plan = createExecutionPlan({
      pricing: pricing({ executionMode: 'INSTANT', executionDelayMs: 500 }),
      kind: 'marketBuy',
      triggerMono: 0,
    });
    assert.equal(plan.delayMs, 0);
  });

  test('queue contention does not restart the delay clock', async () => {
    const triggerMono = performance.now() - 80;
    const plan = createExecutionPlan({
      pricing: pricing({ executionDelayMs: 50 }),
      kind: 'manualClose',
      triggerMono,
    });
    const waited = await waitForDeadline(plan);
    assert.ok(waited < 5);
  });

  test('waitForDeadline sleeps remaining time then returns', async () => {
    const triggerMono = performance.now();
    const plan = createExecutionPlan({
      pricing: pricing({ executionDelayMs: 25 }),
      kind: 'marketBuy',
      triggerMono,
    });
    const t0 = performance.now();
    await waitForDeadline(plan);
    const elapsed = performance.now() - t0;
    assert.ok(elapsed >= 20, `elapsed ${elapsed}`);
    assert.ok(elapsed < 80, `elapsed ${elapsed}`);
  });

  test('manualClose / closeAll / sl / tp are distinct apply kinds', () => {
    assert.equal(closeApplyKind({ protectiveKind: 'sl' }), 'sl');
    assert.equal(closeApplyKind({ protectiveKind: 'tp' }), 'tp');
    assert.equal(closeApplyKind({ closeAll: true }), 'closeAll');
    assert.equal(closeApplyKind({}), 'manualClose');
    assert.equal(closeApplyKind({ stopOut: true }), null);
    assert.equal(closeApplyKind({ dealer: true }), null);
  });

  test('missing apply-to keys default to apply (true)', () => {
    assert.equal(executionApplies({}, 'manualClose'), true);
    assert.equal(executionApplies({ marketBuy: false }, 'sl'), true);
    assert.equal(executionApplies({ sl: false }, 'sl'), false);
  });

  test('captureTrigger does not freeze a 200ms constant', () => {
    const a = captureTrigger(10, 20);
    assert.equal(a.triggerMono, 10);
    const plan = createExecutionPlan({
      pricing: pricing({ executionDelayMs: 17 }),
      kind: 'tp',
      triggerMono: a.triggerMono,
    });
    assert.equal(plan.delayMs, 17);
    assert.notEqual(plan.delayMs, 200);
  });
});
