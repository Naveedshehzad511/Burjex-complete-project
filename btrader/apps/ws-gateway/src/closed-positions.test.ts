import { ClosedPositions } from './closed-positions';

describe('ClosedPositions', () => {
  it('an OPEN update after the close of the same position is stale', () => {
    const f = new ClosedPositions();
    expect(f.isStale('t\u0000p1', false)).toBe(false); // live update while open
    expect(f.isStale('t\u0000p1', true)).toBe(false); // the close itself is always forwarded
    expect(f.isStale('t\u0000p1', false)).toBe(true); // the live loop's late snapshot
  });

  it('a repeated close is still forwarded', () => {
    const f = new ClosedPositions();
    f.isStale('t\u0000p1', true);
    expect(f.isStale('t\u0000p1', true)).toBe(false);
  });

  it('only the closed position is affected (other ids, other tenants, partial-close updates)', () => {
    const f = new ClosedPositions();
    f.isStale('t\u0000p1', true);
    expect(f.isStale('t\u0000p2', false)).toBe(false);
    expect(f.isStale('u\u0000p1', false)).toBe(false);
  });

  it('forgets a close after the ttl and prunes old entries', () => {
    let now = 0;
    const f = new ClosedPositions(1000, () => now);
    f.isStale('t\u0000p1', true);
    now = 999;
    expect(f.isStale('t\u0000p1', false)).toBe(true);
    now = 1000;
    expect(f.isStale('t\u0000p1', false)).toBe(false);
    expect(f.size).toBe(0);

    now = 0;
    for (let i = 0; i < 1025; i++) f.isStale(`t\u0000old${i}`, true);
    now = 5000;
    f.isStale('t\u0000new', true); // over the cap: expired entries are dropped
    expect(f.size).toBe(1);
  });
});
