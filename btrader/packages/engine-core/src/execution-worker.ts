/**
 * Bounded async execution mailbox.
 * Tick detection enqueues; this worker waits the original deadline then runs
 * the DB mutation. Detection is never blocked by a slow close TX.
 */
export type ExecJob =
  | {
      type: 'protective';
      key: string;
      tenantId: string;
      positionId: string;
      accountId: string;
      kind: 'sl' | 'tp';
      level?: number;
      bid: number;
      ask: number;
      triggerMono: number;
      triggerWall: number;
    }
  | {
      type: 'pending';
      key: string;
      tenantId: string;
      orderId: string;
      accountId: string;
      triggerMono: number;
      triggerWall: number;
    };

export class ExecutionWorker {
  private readonly q: ExecJob[] = [];
  private readonly inflight = new Set<string>();
  private active = 0;
  private dropped = 0;
  private readonly run: (job: ExecJob) => Promise<void>;
  private readonly concurrency: number;
  private readonly maxQueue: number;

  constructor(
    run: (job: ExecJob) => Promise<void>,
    concurrency = Math.max(1, Number(process.env.ENGINE_EXEC_CONCURRENCY ?? 16)),
    maxQueue = Math.max(1000, Number(process.env.ENGINE_EXEC_QUEUE_MAX ?? 50_000)),
  ) {
    this.run = run;
    this.concurrency = concurrency;
    this.maxQueue = maxQueue;
  }

  get queued(): number {
    return this.q.length;
  }

  get running(): number {
    return this.active;
  }

  get droppedCount(): number {
    return this.dropped;
  }

  /** Enqueue unless this entity is already waiting/running. */
  enqueue(job: ExecJob): boolean {
    if (this.inflight.has(job.key)) return false;
    if (this.q.length >= this.maxQueue) {
      this.dropped++;
      return false;
    }
    this.inflight.add(job.key);
    this.q.push(job);
    this.pump();
    return true;
  }

  private pump(): void {
    while (this.active < this.concurrency && this.q.length) {
      const job = this.q.shift()!;
      this.active++;
      void this.run(job)
        .catch(() => undefined)
        .finally(() => {
          this.active--;
          this.inflight.delete(job.key);
          this.pump();
        });
    }
  }
}
