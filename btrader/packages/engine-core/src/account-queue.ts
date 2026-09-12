import { BtError, BtErrorCode } from '@btrader/shared';

/**
 * Per-account FIFO serialization for trading mutations.
 *
 * Node has no Arc/Mutex — this is the TypeScript equivalent of an actor mailbox:
 * all place/close/modify for one accountId run strictly one-after-another in this
 * process, so concurrent HTTP floods cannot interleave margin checks before the
 * DB FOR UPDATE lock is taken.
 *
 * Waiters that sit longer than ACCOUNT_QUEUE_WAIT_MS (default 8s) are rejected
 * with 429 so one flooded account cannot pin thousands of HTTP connections.
 * Timed-out waiters still occupy their mailbox slot (no-op) so exclusivity holds.
 *
 * Delay clocks live on ExecutionPlan (trigger + group.executionDelayMs), not
 * here. A late start after FIFO wait must call waitForDeadline(original) so
 * remaining time is 0 — this queue must never restart a delay.
 *
 * Cross-process safety still relies on PostgreSQL `SELECT … FOR UPDATE`.
 */
export class AccountExclusiveQueue {
  private readonly tails = new Map<string, Promise<unknown>>();
  private readonly waitMs = Math.max(0, Number(process.env.ACCOUNT_QUEUE_WAIT_MS ?? 8_000));

  /** Run `fn` exclusively for `accountId` (FIFO with prior callers). */
  run<T>(accountId: string, fn: () => Promise<T>): Promise<T> {
    const key = String(accountId || '');
    if (!key) return fn();
    const prev = this.tails.get(key) ?? Promise.resolve();

    let timedOut = false;
    let settle!: (err: unknown, value?: T) => void;
    const work = new Promise<T>((resolve, reject) => {
      settle = (err, value) => (err ? reject(err) : resolve(value as T));
    });

    const timer =
      this.waitMs > 0
        ? setTimeout(() => {
            timedOut = true;
            settle(new BtError(BtErrorCode.RATE_LIMITED, 'account busy — too many queued mutations'));
          }, this.waitMs)
        : undefined;

    const slot = prev
      .then(
        () => undefined,
        () => undefined,
      )
      .then(() => {
        if (timer) clearTimeout(timer);
        if (timedOut) return;
        return Promise.resolve()
          .then(fn)
          .then(
            (v) => settle(null, v),
            (e) => settle(e),
          );
      });

    const sentinel = slot.then(
      () => undefined,
      () => undefined,
    );
    this.tails.set(key, sentinel);
    void sentinel.then(() => {
      if (this.tails.get(key) === sentinel) this.tails.delete(key);
    });
    return work;
  }

  /** Approx number of accounts with an in-flight exclusive chain (metrics). */
  get pendingAccounts(): number {
    return this.tails.size;
  }
}

/**
 * Sliding-window order rate limit per account (in-process).
 * Protects the DB under spam (e.g. hundreds of opens/sec from one client).
 */
export class AccountOrderRateLimiter {
  private readonly hits = new Map<string, number[]>();

  constructor(
    private readonly maxPerWindow = Math.max(1, Number(process.env.ORDER_RATE_MAX ?? 40)),
    private readonly windowMs = Math.max(100, Number(process.env.ORDER_RATE_WINDOW_MS ?? 1000)),
  ) {}

  /** @returns true if allowed; false if over limit. */
  allow(accountId: string): boolean {
    const key = String(accountId || '');
    if (!key) return true;
    const now = Date.now();
    const cutoff = now - this.windowMs;
    let arr = this.hits.get(key);
    if (!arr) {
      arr = [];
      this.hits.set(key, arr);
    }
    while (arr.length && arr[0]! < cutoff) arr.shift();
    if (arr.length >= this.maxPerWindow) return false;
    arr.push(now);
    if (this.hits.size > 50_000) {
      for (const [k, v] of this.hits) {
        if (!v.length || v[v.length - 1]! < cutoff) this.hits.delete(k);
      }
    }
    return true;
  }
}
