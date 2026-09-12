/**
 * Standalone Node test (no jest / pnpm). Run:
 *   node --test apps/trading-engine/src/execution-selftest.mjs
 */
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const here = dirname(fileURLToPath(import.meta.url));

function protectiveHit(args) {
  const isBuy = String(args.side).toUpperCase() === 'BUY';
  const mkt = isBuy ? args.bid : args.ask;
  const sl = args.sl != null && args.sl > 0 ? args.sl : null;
  const tp = args.tp != null && args.tp > 0 ? args.tp : null;
  const hitSL = sl != null && (isBuy ? mkt <= sl : mkt >= sl);
  const hitTP = tp != null && (isBuy ? mkt >= tp : mkt <= tp);
  if (hitSL) return { hit: 'SL', level: sl };
  if (hitTP) return { hit: 'TP', level: tp };
  return { hit: null, level: null };
}

function emptyLatch() {
  return { claimed: false, closed: false, kind: null, level: null, triggerWall: 0 };
}

function applyProtectiveTick(state, args, nowWall = Date.now()) {
  if (state.closed || state.claimed) return state;
  const hit = protectiveHit(args);
  if (!hit.hit) return state;
  return {
    claimed: true,
    closed: false,
    kind: hit.hit === 'SL' ? 'sl' : 'tp',
    level: hit.level,
    triggerWall: nowWall,
    bid: args.bid,
    ask: args.ask,
  };
}

class MemoryClaimStore {
  constructor() {
    this.m = new Map();
  }
  claim(id, data) {
    if (this.m.has(id)) return 'already_claimed';
    this.m.set(id, data);
    return 'claimed';
  }
  get size() {
    return this.m.size;
  }
}

function executionApplies(flags, kind) {
  if (!flags || Object.keys(flags).length === 0) return true;
  return flags[kind] !== false;
}

function marketExecutionDelayMs(pricing, kind) {
  if (!pricing) return 0;
  if ((pricing.executionMode ?? 'MARKET') !== 'MARKET') return 0;
  if (!executionApplies(pricing.executionApplyTo, kind)) return 0;
  return Math.max(0, Math.floor(Number(pricing.executionDelayMs) || 0));
}

function createExecutionPlan({ pricing, kind, triggerMono = 0 }) {
  const delayMs = marketExecutionDelayMs(pricing, kind);
  return { kind, delayMs, triggerMono, deadlineMono: triggerMono + delayMs };
}

async function waitForDeadline(plan) {
  if (!plan || !(plan.delayMs > 0)) return 0;
  const left = plan.deadlineMono - performance.now();
  if (left <= 0) return 0;
  const t0 = performance.now();
  await new Promise((r) => setTimeout(r, Math.ceil(left)));
  return performance.now() - t0;
}

class ExecutionWorker {
  constructor(run, concurrency = 2, maxQueue = 100) {
    this.run = run;
    this.concurrency = concurrency;
    this.maxQueue = maxQueue;
    this.q = [];
    this.inflight = new Set();
    this.active = 0;
  }
  enqueue(job) {
    if (this.inflight.has(job.key)) return false;
    this.inflight.add(job.key);
    this.q.push(job);
    this.pump();
    return true;
  }
  pump() {
    while (this.active < this.concurrency && this.q.length) {
      const job = this.q.shift();
      this.active++;
      void this.run(job).finally(() => {
        this.active--;
        this.inflight.delete(job.key);
        this.pump();
      });
    }
  }
}

describe('SL/TP latch', () => {
  test('price through SL then reverses — still claimed', () => {
    let s = emptyLatch();
    s = applyProtectiveTick(s, { side: 'BUY', bid: 2499.98, ask: 2500.1, sl: 2500, tp: 2510 });
    assert.equal(s.claimed, true);
    assert.equal(s.kind, 'sl');
    s = applyProtectiveTick(s, { side: 'BUY', bid: 2500.1, ask: 2500.22, sl: 2500, tp: 2510 });
    assert.equal(s.claimed, true);
    assert.equal(s.kind, 'sl');
  });

  test('5000 reverse-after-hit cycles stay claimed', () => {
    let claimed = 0;
    for (let i = 0; i < 5000; i++) {
      let s = emptyLatch();
      s = applyProtectiveTick(s, { side: 'BUY', bid: 2499.9, ask: 2500, sl: 2500, tp: 2510 });
      s = applyProtectiveTick(s, { side: 'BUY', bid: 2500.4, ask: 2500.5, sl: 2500, tp: 2510 });
      if (s.claimed) claimed++;
    }
    assert.equal(claimed, 5000);
  });

  test('gap through SL latches', () => {
    const s = applyProtectiveTick(emptyLatch(), { side: 'BUY', bid: 2480, ask: 2480.2, sl: 2500 });
    assert.equal(s.claimed, true);
  });
});

describe('two-engine claim', () => {
  test('exactly one winner', () => {
    const store = new MemoryClaimStore();
    const a = store.claim('p1', { kind: 'sl' });
    const b = store.claim('p1', { kind: 'sl' });
    assert.equal(a, 'claimed');
    assert.equal(b, 'already_claimed');
  });

  test('5000 positions × 2 engines, zero doubles', () => {
    const store = new MemoryClaimStore();
    let claimed = 0;
    let dup = 0;
    for (let i = 0; i < 5000; i++) {
      if (store.claim(`p${i}`, {}) === 'claimed') claimed++;
      if (store.claim(`p${i}`, {}) === 'claimed') dup++;
    }
    assert.equal(claimed, 5000);
    assert.equal(dup, 0);
    assert.equal(store.size, 5000);
  });
});

describe('central delay policy', () => {
  test('50 / 200 / 500 ms come from group config', () => {
    for (const ms of [50, 200, 500]) {
      const plan = createExecutionPlan({
        pricing: { executionMode: 'MARKET', executionDelayMs: ms, executionApplyTo: {} },
        kind: 'sl',
        triggerMono: 1000,
      });
      assert.equal(plan.delayMs, ms);
      assert.equal(plan.deadlineMono, 1000 + ms);
    }
  });

  test('apply-to false → 0 delay', () => {
    assert.equal(
      marketExecutionDelayMs({ executionMode: 'MARKET', executionDelayMs: 500, executionApplyTo: { sl: false } }, 'sl'),
      0,
    );
  });

  test('INSTANT never waits', () => {
    assert.equal(
      marketExecutionDelayMs({ executionMode: 'INSTANT', executionDelayMs: 500, executionApplyTo: {} }, 'marketBuy'),
      0,
    );
  });

  test('late queue start does not restart delay', async () => {
    const plan = createExecutionPlan({
      pricing: { executionMode: 'MARKET', executionDelayMs: 50, executionApplyTo: {} },
      kind: 'manualClose',
      triggerMono: performance.now() - 80,
    });
    const waited = await waitForDeadline(plan);
    assert.ok(waited < 5, `waited ${waited}`);
  });
});

describe('worker + source audit', () => {
  test('duplicate job keys enqueue once', async () => {
    const ran = [];
    const w = new ExecutionWorker(async (job) => {
      ran.push(job.key);
    });
    assert.equal(w.enqueue({ key: 'p:1' }), true);
    assert.equal(w.enqueue({ key: 'p:1' }), false);
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(ran.filter((k) => k === 'p:1').length, 1);
  });

  test('engine.ts has no sleep(200) hard-code', () => {
    const src = readFileSync(join(here, '../../../packages/engine-core/src/engine.ts'), 'utf8');
    assert.equal(/sleep(Ms|Until)?\(\s*200\s*\)/.test(src), false);
    assert.equal(/executionDelayMs\s*=\s*200/.test(src), false);
    assert.match(src, /waitForDeadline/);
    assert.match(src, /claimPositionDb/);
    assert.equal(src.includes('protectiveClosing'), false);
    assert.equal(src.includes('fastBusy'), false);
  });
});

