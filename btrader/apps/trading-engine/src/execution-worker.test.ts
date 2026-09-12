import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { ExecutionWorker, type ExecJob } from '../../../packages/engine-core/src/execution-worker.ts';

const here = dirname(fileURLToPath(import.meta.url));

describe('execution worker + no hard-coded 200ms delay', () => {
  test('duplicate keys are not queued twice', async () => {
    const ran: string[] = [];
    const w = new ExecutionWorker(async (job) => {
      ran.push(job.key);
    }, 2, 100);
    const job = (id: string): ExecJob => ({
      type: 'protective',
      key: `p:${id}`,
      tenantId: 't',
      positionId: id,
      accountId: 'a',
      kind: 'sl',
      bid: 1,
      ask: 1,
      triggerMono: 0,
      triggerWall: 0,
    });
    assert.equal(w.enqueue(job('1')), true);
    assert.equal(w.enqueue(job('1')), false);
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(ran.filter((k) => k === 'p:1').length, 1);
  });

  test('engine-core source has no sleep(200) / delayMs = 200 hard-code', () => {
    const root = join(here, '../../../packages/engine-core/src');
    for (const f of ['engine.ts', 'execution-policy.ts', 'calc.ts']) {
      const src = readFileSync(join(root, f), 'utf8');
      assert.equal(/sleep(Ms|Until)?\(\s*200\s*\)/.test(src), false, f);
      assert.equal(/executionDelayMs\s*=\s*200/.test(src), false, f);
      assert.equal(/delayMs\s*=\s*200\s*;/.test(src), false, f);
    }
  });
});
