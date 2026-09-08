/**
 * Process-local counters + Prometheus text. Pair with latency.ts: latency is
 * histograms, this is counts (fills, rejects, gaps, uncovered hedges).
 */

class CounterSet {
  private readonly n = new Map<string, number>();

  inc(name: string, by = 1): void {
    this.n.set(name, (this.n.get(name) ?? 0) + by);
  }

  get(name: string): number {
    return this.n.get(name) ?? 0;
  }

  snapshot(): Record<string, number> {
    return Object.fromEntries(this.n);
  }

  reset(): void {
    this.n.clear();
  }
}

export const counters = new CounterSet();

function promName(label: string): string {
  return 'btrader_' + label.replace(/[^a-zA-Z0-9_]/g, '_');
}

/** Prometheus 0.0.4 text (no extra deps). */
export function prometheusText(
  latency: Record<string, { count: number; avg: number; p50: number; p95: number; p99: number; max: number }>,
  extra?: Record<string, number>,
): string {
  const lines: string[] = [];
  for (const [k, v] of Object.entries(counters.snapshot())) {
    const n = promName(k);
    lines.push(`# TYPE ${n} counter`, `${n} ${v}`);
  }
  if (extra) {
    for (const [k, v] of Object.entries(extra)) {
      const n = promName(k);
      lines.push(`# TYPE ${n} gauge`, `${n} ${v}`);
    }
  }
  for (const [k, s] of Object.entries(latency)) {
    const n = promName(`latency_${k}`);
    lines.push(`# TYPE ${n}_count counter`, `${n}_count ${s.count}`);
    lines.push(`# TYPE ${n}_millis summary`);
    lines.push(`${n}_millis{quantile="0.5"} ${s.p50}`);
    lines.push(`${n}_millis{quantile="0.95"} ${s.p95}`);
    lines.push(`${n}_millis{quantile="0.99"} ${s.p99}`);
    lines.push(`${n}_millis_sum ${Math.round(s.avg * s.count)}`);
  }
  return lines.join('\n') + '\n';
}
