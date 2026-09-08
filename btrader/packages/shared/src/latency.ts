/**
 * Lightweight in-process latency collector for profiling hot paths (order
 * execution, tick fan-out) without an external metrics stack. Records a rolling
 * window of samples per label and computes percentiles on demand. Zero-cost
 * beyond an O(1) push per measurement; safe to leave on in production.
 *
 * One process-global `latency` singleton is shared across a service's code via
 * the Node module cache (each service process gets its own instance).
 */
/** Sub-millisecond monotonic clock (ms), env-agnostic — no Node types needed. */
function nowMs(): number {
  const p = (globalThis as { performance?: { now?: () => number } }).performance;
  return p && typeof p.now === 'function' ? p.now() : Date.now();
}

export class LatencyStats {
  private readonly buf = new Map<string, number[]>();
  constructor(private readonly cap = 5000) {}

  /** Record a measured duration (milliseconds) under a label. */
  record(label: string, ms: number): void {
    let a = this.buf.get(label);
    if (!a) {
      a = [];
      this.buf.set(label, a);
    }
    a.push(ms);
    if (a.length > this.cap) a.shift();
  }

  /** Time an async fn and record its duration. Returns the fn's result. */
  async time<T>(label: string, fn: () => Promise<T>): Promise<T> {
    const start = nowMs();
    try {
      return await fn();
    } finally {
      this.record(label, nowMs() - start);
    }
  }

  /** Start a manual span; call the returned fn to stop + record. */
  start(label: string): () => void {
    const t0 = nowMs();
    return () => this.record(label, nowMs() - t0);
  }

  snapshot(): Record<string, { count: number; avg: number; p50: number; p95: number; p99: number; max: number }> {
    const out: Record<string, { count: number; avg: number; p50: number; p95: number; p99: number; max: number }> = {};
    for (const [label, arr] of this.buf) {
      if (!arr.length) continue;
      const s = [...arr].sort((a, b) => a - b);
      const pct = (p: number) => s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
      const sum = s.reduce((a, b) => a + b, 0);
      const r = (x: number) => Math.round(x * 1000) / 1000;
      out[label] = { count: s.length, avg: r(sum / s.length), p50: r(pct(50)), p95: r(pct(95)), p99: r(pct(99)), max: r(s[s.length - 1]) };
    }
    return out;
  }

  reset(): void {
    this.buf.clear();
  }
}

/** Process-global collector. */
export const latency = new LatencyStats();
