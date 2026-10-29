/**
 * Log-only watch for pauses in the price feed, so a client's "the chart has a gap at …" can be checked against the
 * server log (`docker logs bxnet_bt_market_data | grep feed-gap`). It never changes a tick, a bar or a publish.
 *
 * Times are the ticks' own market timestamps, printed in UTC (= Exness server time = the chart's time axis).
 *
 *   [feed-gap] no usable ticks from any symbol for 60s (last 2026-10-29 07:59:55 UTC) …
 *   [feed-gap] feed resumed after 74s without ticks: 2026-10-29 07:59:55 → 08:01:09 UTC
 *   [feed-gap] 2 symbol(s) resumed after a pause over 120s: XAUUSD 74s (07:59:55 → 08:01:09), …
 *
 * Pure (the caller passes the clock) so it can be tested; main.ts prints what it returns.
 */
export interface FeedGapOptions {
  /** Whole feed silent this long → one warning, and a "resumed" line when ticks come back. Default 60 s. */
  feedGapMs?: number;
  /** One symbol silent this long while the rest of the feed kept ticking → listed when it resumes. Default 120 s. */
  symbolGapMs?: number;
  /** How often the per-symbol list is printed at most. Default 30 s. */
  summaryEveryMs?: number;
}

export const utcStamp = (ms: number): string => new Date(ms).toISOString().replace('T', ' ').slice(0, 19) + ' UTC';
const hms = (ms: number): string => new Date(ms).toISOString().slice(11, 19);
const secs = (ms: number): string => `${Math.round(ms / 1000)}s`;

export class FeedGapWatch {
  private readonly feedGapMs: number;
  private readonly symbolGapMs: number;
  private readonly summaryEveryMs: number;
  private readonly lastBySymbol = new Map<string, number>();
  private lastAny = 0;
  private silentReported = false;
  /** The last whole-feed pause (market time), so its symbols are not listed one by one as well. */
  private feedGap?: { from: number; to: number };
  private pending: Array<{ symbol: string; from: number; to: number }> = [];
  private pendingSince = 0;
  private summaryAt = 0;

  constructor(opts: FeedGapOptions = {}) {
    this.feedGapMs = opts.feedGapMs ?? 60_000;
    this.symbolGapMs = opts.symbolGapMs ?? 120_000;
    this.summaryEveryMs = opts.summaryEveryMs ?? 30_000;
  }

  /** A usable tick (market time [tsMs]); returns log lines to print, usually none. */
  tick(symbol: string, tsMs: number, nowMs: number): string[] {
    const out: string[] = [];
    if (!Number.isFinite(tsMs) || tsMs <= 0) return out;

    if (this.lastAny > 0 && tsMs - this.lastAny >= this.feedGapMs) {
      this.feedGap = { from: this.lastAny, to: tsMs };
      out.push(
        `[feed-gap] feed resumed after ${secs(tsMs - this.lastAny)} without ticks: ` +
          `${utcStamp(this.lastAny)} → ${hms(tsMs)} UTC. Charts have no live bars for this span; ` +
          `the EA's MT5 repair refills them within about 5 minutes.`,
      );
    }
    if (tsMs > this.lastAny) {
      this.lastAny = tsMs;
      this.silentReported = false;
    }

    const prev = this.lastBySymbol.get(symbol);
    if (prev !== undefined && tsMs - prev >= this.symbolGapMs) {
      const g = this.feedGap;
      const coveredByFeedGap = g !== undefined && g.from >= prev && g.to <= tsMs;
      if (!coveredByFeedGap) {
        if (this.pending.length === 0) this.pendingSince = nowMs;
        this.pending.push({ symbol, from: prev, to: tsMs });
      }
    }
    if (prev === undefined || tsMs > prev) this.lastBySymbol.set(symbol, tsMs);

    out.push(...this.flushSummary(nowMs));
    return out;
  }

  /** Called on a timer; reports a feed that has gone silent (once per pause). */
  check(nowMs: number): string[] {
    const out = this.flushSummary(nowMs);
    if (this.lastAny > 0 && !this.silentReported && nowMs - this.lastAny >= this.feedGapMs) {
      this.silentReported = true;
      out.push(
        `[feed-gap] no usable ticks from any symbol for ${secs(nowMs - this.lastAny)} (last ${utcStamp(this.lastAny)}). ` +
          `Live prices are paused: check the MT5 terminal / BTraderFeed EA on the feed server, the link, ` +
          `or whether the market is closed.`,
      );
    }
    return out;
  }

  private flushSummary(nowMs: number): string[] {
    // Wait a few seconds so symbols that resume together share one line.
    if (this.pending.length === 0 || nowMs - this.pendingSince < 5_000 || nowMs - this.summaryAt < this.summaryEveryMs) return [];
    this.summaryAt = nowMs;
    const list = this.pending;
    this.pending = [];
    const shown = list
      .slice(0, 20)
      .map((p) => `${p.symbol} ${secs(p.to - p.from)} (${utcStamp(p.from).slice(0, 10)} ${hms(p.from)} → ${hms(p.to)})`)
      .join(', ');
    return [
      `[feed-gap] ${list.length} symbol(s) resumed after a pause over ${secs(this.symbolGapMs)}: ${shown}` +
        (list.length > 20 ? ` … and ${list.length - 20} more` : ''),
    ];
  }
}
