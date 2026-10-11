import type { CandleEvent } from '@btrader/shared';

/**
 * Bars waiting for a client's next tick flush.
 *
 * Nothing is dropped. A bar update is a snapshot of the WHOLE bar, so a newer update replaces the older
 * update of the same bar that is still waiting (it would only be drawn and immediately overwritten). Every
 * tick produces an update for each timeframe, so the same bar is updated many times inside one flush window
 * and only its last state is worth sending. A `created` or `closed` bar is news in its own right: it is
 * always kept, and no later update replaces anything at or before it, so for every bar the order of its
 * events is exactly the order they arrived in.
 */
export class CandleBuffer {
  private items: CandleEvent[] = [];
  /** Position of the newest item for each bar, so a replacement needs no scan. */
  private latest = new Map<string, number>();

  private static key(c: CandleEvent): string {
    return `${c.symbol}|${c.tf}|${c.t}`;
  }

  get size(): number {
    return this.items.length;
  }

  push(candle: CandleEvent): void {
    const key = CandleBuffer.key(candle);
    const at = this.latest.get(key);
    if (candle.kind === 'updated' && at !== undefined && this.items[at]!.kind === 'updated') {
      this.items[at] = candle;
      return;
    }
    this.items.push(candle);
    this.latest.set(key, this.items.length - 1);
  }

  /** Everything waiting, oldest first; the buffer is empty afterwards. */
  drain(): CandleEvent[] {
    const out = this.items;
    this.items = [];
    this.latest = new Map();
    return out;
  }
}
