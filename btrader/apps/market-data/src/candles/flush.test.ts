import { FlushRow, selectFlushRows } from './flush';

interface Row extends FlushRow {
  h: number;
  l: number;
  src: string;
}
const row = (t: number, src: string, extra: Partial<Row> = {}): Row => ({
  symbol: 'XAUUSD',
  tf: '1m',
  t,
  h: 0,
  l: 0,
  src,
  ...extra,
});

describe('selectFlushRows', () => {
  it('an engine-closed bar is NOT cancelled by a gap-fill bridge row for the same bar', () => {
    const history = [row(60, 'bridge', { gapFill: true })];
    const closed = [row(60, 'engine-closed', { h: 2445.5, l: 2439.2 })];
    const sel = selectFlushRows(history, closed, 100);
    const written = sel.batch.filter((r) => r.t === 60);
    expect(written).toHaveLength(1);
    expect(written[0]!.src).toBe('engine-closed');
    expect(written[0]!.gapFill).toBeUndefined(); // so it overwrites the partial tip row
    expect(written[0]!.h).toBe(2445.5);
  });

  it('bridge history for a bucket BEFORE the engine era still wins (the engine bar there is partial)', () => {
    const history = [row(14400, 'bridge')]; // gapFill unset: authoritative
    const closed = [row(14400, 'engine-closed')];
    const sel = selectFlushRows(history, closed, 100);
    expect(sel.batch.map((r) => r.src)).toEqual(['bridge']);
  });

  it('a gap-fill row still fills a bucket nothing else wrote', () => {
    const sel = selectFlushRows([row(120, 'bridge', { gapFill: true })], [row(60, 'engine-closed')], 100);
    expect(sel.batch.map((r) => `${r.t}:${r.src}`).sort()).toEqual(['120:bridge', '60:engine-closed']);
  });

  it('closed bars are taken before gap-fill rows when space is limited, and nothing is lost', () => {
    const history = [row(1, 'bridge', { gapFill: true }), row(2, 'bridge', { gapFill: true })];
    const closed = [row(10, 'engine-closed'), row(11, 'engine-closed')];
    const sel = selectFlushRows(history, closed, 2);
    expect(sel.batch.map((r) => r.src)).toEqual(['engine-closed', 'engine-closed']);
    // The gap-fill rows stay queued, in order, for the next cycle.
    expect(history.map((r) => r.t)).toEqual([1, 2]);
    expect(closed).toHaveLength(0);
  });

  it('rows that did not fit stay queued and a second cycle drains them', () => {
    const history = [row(1, 'bridge'), row(2, 'bridge'), row(3, 'bridge')];
    const closed: Row[] = [];
    const first = selectFlushRows(history, closed, 2);
    expect(first.batch).toHaveLength(2);
    const second = selectFlushRows(history, closed, 2);
    expect(second.batch.map((r) => r.t)).toEqual([3]);
  });

  it('two closed rows for the same bar write once', () => {
    const sel = selectFlushRows([], [row(60, 'a'), row(60, 'b')], 100);
    expect(sel.batch).toHaveLength(1);
  });
});
