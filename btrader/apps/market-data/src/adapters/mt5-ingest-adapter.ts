import * as http from 'http';
import { LpBridgeAdapter, RawTick } from '@btrader/shared';

/** One OHLC bar pushed by the bridge (epoch SECONDS open time). */
export interface CandleBar {
  t: number;
  o: number;
  h: number;
  l: number;
  c: number;
  v: number;
}

/** Resolved feed source for an incoming token (multi-source ingestion). */
export interface FeedSource {
  code: string;            // provider code stamped on each tick (e.g. "LP4")
  tenantId: string | null; // owning tenant; null for the legacy tenant-agnostic feed
}

export interface Mt5IngestOptions {
  port: number;
  /** Legacy shared secret — accepted as the tenant-agnostic "default" source. */
  token: string;
  /**
   * Multi-source resolver: map an incoming X-Feed-Token to a registered provider.
   * Return null to fall back to the legacy token check. Lets many bridges (one
   * per LP/company) post to the same endpoint, each tagged with its own source.
   */
  resolveSource?: (token: string) => FeedSource | null;
  /** Optional MT5 symbol suffix to strip (e.g. ".r", "m", ".pro") so "EURUSD.r" → "EURUSD". */
  stripSuffix?: string;
  /** Reject ticks older than this many ms (0 = no staleness check). */
  maxAgeMs?: number;
}

/**
 * MT5 → B-Trader ingest bridge. Implements the LpBridgeAdapter contract by
 * RECEIVING ticks (rather than connecting out): it runs a small HTTP server
 * that an MT5 Expert Advisor / Manager-API bridge POSTs quotes to. Each accepted
 * tick is emitted through onTick into the normal market-data pipeline (tenant
 * markup → Redis fan-out), so nothing downstream changes.
 *
 * POST /ingest   headers: X-Feed-Token: <token>, Content-Type: application/json
 *   body (batch):  { "ticks": [ { "symbol":"EURUSD", "bid":1.0950, "ask":1.0951, "ts":1718000000000 } ] }
 *   body (single): { "symbol":"EURUSD", "bid":1.0950, "ask":1.0951 }
 * GET  /health   → 200 { ok, ticks, lastTickAt }
 */
export class Mt5IngestAdapter implements LpBridgeAdapter {
  readonly name = 'mt5-ingest';
  private server?: http.Server;
  private connected = false;
  private received = 0;
  private lastTickAt = 0;
  private tickHandler?: (t: RawTick) => void;
  private candleHandler?: (symbol: string, tf: string, bars: CandleBar[]) => void;
  private statusHandler?: (s: 'connected' | 'disconnected' | 'error', d?: string) => void;

  constructor(private readonly opts: Mt5IngestOptions) {}

  async connect(): Promise<void> {
    if (!this.opts.token && !this.opts.resolveSource) {
      // Refuse to run an unauthenticated public price ingest.
      throw new Error('MT5_FEED_TOKEN or a source resolver is required for the mt5-ingest adapter');
    }
    this.server = http.createServer((req, res) => this.handle(req, res));
    await new Promise<void>((resolve) => this.server!.listen(this.opts.port, '0.0.0.0', resolve));
    this.connected = true;
    this.statusHandler?.('connected', `ingest listening on :${this.opts.port}`);
  }

  async disconnect(): Promise<void> {
    this.connected = false;
    await new Promise<void>((resolve) => (this.server ? this.server.close(() => resolve()) : resolve()));
    this.statusHandler?.('disconnected');
  }

  // Inbound feed: subscribe/unsubscribe are no-ops (the bridge pushes whatever
  // symbols it is configured to send; B-Trader routing filters to enabled ones).
  async subscribe(): Promise<void> {}
  async unsubscribe(): Promise<void> {}

  onTick(h: (t: RawTick) => void): void {
    this.tickHandler = h;
  }
  /** Register a handler for pushed OHLC history/updates (charts). */
  onCandles(h: (symbol: string, tf: string, bars: CandleBar[]) => void): void {
    this.candleHandler = h;
  }
  onStatus(h: (s: 'connected' | 'disconnected' | 'error', d?: string) => void): void {
    this.statusHandler = h;
  }
  isConnected(): boolean {
    return this.connected;
  }

  // ── HTTP handling ──────────────────────────────────────────────────────────
  private handle(req: http.IncomingMessage, res: http.ServerResponse): void {
    if (req.method === 'GET' && req.url === '/health') {
      return this.json(res, 200, { ok: true, received: this.received, lastTickAt: this.lastTickAt });
    }
    const isTicks = req.method === 'POST' && (req.url === '/ingest' || req.url === '/');
    const isCandles = req.method === 'POST' && req.url === '/ingest/candles';
    if (!isTicks && !isCandles) {
      return this.json(res, 404, { error: 'not found' });
    }
    const rawToken = req.headers['x-feed-token'];
    const token = Array.isArray(rawToken) ? rawToken[0] : rawToken;
    const source = this.resolve(token);
    if (!source) {
      return this.json(res, 401, { error: 'bad token' });
    }

    const chunks: Buffer[] = [];
    let size = 0;
    let tooBig = false;
    req.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size > 4_000_000) {
        tooBig = true;
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (tooBig) return;
      let parsed: any;
      try {
        parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      } catch {
        return this.json(res, 400, { error: 'invalid json' });
      }
      if (isCandles) return this.handleCandles(parsed, res);

      const ticks: any[] = Array.isArray(parsed?.ticks)
        ? parsed.ticks
        : parsed?.symbol != null
          ? [parsed]
          : [];
      // Normalize cheaply, ACK immediately, then fan-out off the HTTP path.
      // Under 400+ symbol batches + candle history, sync handleTick (Redis publish
      // + candle tip updates) used to stall the response past the bridge's 8s
      // read timeout → intermittent Read timed out / ruk-ruk.
      const now = Date.now();
      const normalized: RawTick[] = [];
      for (const t of ticks) {
        const tick = this.normalize(t, now, source);
        if (tick) normalized.push(tick);
      }
      this.received += normalized.length;
      if (normalized.length) this.lastTickAt = now;
      this.json(res, 200, { ok: true, accepted: normalized.length });
      if (normalized.length === 0) return;
      // Slice fan-out across turns so candle DB flush / other HTTP stay responsive.
      const slice = 40;
      const run = (idx: number) => {
        const end = Math.min(idx + slice, normalized.length);
        for (let i = idx; i < end; i++) this.tickHandler?.(normalized[i]!);
        if (end < normalized.length) setImmediate(() => run(end));
      };
      setImmediate(() => run(0));
    });
  }

  /** Map an incoming token to a feed source (provider resolver → legacy token). */
  private resolve(token: string | undefined): FeedSource | null {
    if (!token) return null;
    const fromProvider = this.opts.resolveSource?.(token);
    if (fromProvider) return fromProvider;
    if (this.opts.token && token === this.opts.token) return { code: 'default', tenantId: null };
    return null;
  }

  private handleCandles(parsed: any, res: http.ServerResponse): void {
    let symbol = String(parsed?.symbol ?? '').trim().toUpperCase();
    const tf = String(parsed?.tf ?? '').trim();
    const rawBars: any[] = Array.isArray(parsed?.bars) ? parsed.bars : [];
    if (!symbol || !tf || rawBars.length === 0) {
      return this.json(res, 400, { error: 'symbol, tf and bars[] required' });
    }
    const sfx = this.opts.stripSuffix?.toUpperCase();
    if (sfx && symbol.endsWith(sfx)) symbol = symbol.slice(0, symbol.length - sfx.length);

    // Ack first — heavy bar normalize/filter + Prisma queue must not delay the
    // HTTP response (tick POSTs share this event loop under seed/refresh load).
    this.json(res, 200, { ok: true, accepted: rawBars.length });
    setImmediate(() => {
      const bars: CandleBar[] = [];
      for (const b of rawBars) {
        let t = Number(b.t);
        const o = Number(b.o),
          h = Number(b.h),
          l = Number(b.l),
          c = Number(b.c);
        if (![t, o, h, l, c].every(Number.isFinite) || t <= 0) continue;
        // Epoch seconds throughout; auto-detect accidental milliseconds.
        if (t > 10_000_000_000) t = Math.floor(t / 1000);
        else t = Math.floor(t);
        bars.push({ t, o, h, l, c, v: Number(b.v) || 0 });
      }
      if (bars.length === 0) return;
      bars.sort((a, b) => a.t - b.t);
      this.candleHandler?.(symbol, tf, bars);
    });
  }

  private normalize(t: any, now: number, source: FeedSource): RawTick | null {
    if (t == null) return null;
    const bid = Number(t.bid);
    const ask = Number(t.ask);
    if (!t.symbol || !Number.isFinite(bid) || !Number.isFinite(ask) || bid <= 0 || ask <= 0) return null;
    let symbol = String(t.symbol).trim().toUpperCase();
    const sfx = this.opts.stripSuffix?.toUpperCase();
    if (sfx && symbol.endsWith(sfx)) symbol = symbol.slice(0, symbol.length - sfx.length);
    const ts = Number(t.ts ?? t.time ?? now);
    if (this.opts.maxAgeMs && this.opts.maxAgeMs > 0 && now - ts > this.opts.maxAgeMs) return null;
    return {
      symbol,
      bid,
      ask,
      ts: Number.isFinite(ts) ? ts : now,
      source: source.code,
      tenantId: source.tenantId,
    };
  }

  private json(res: http.ServerResponse, code: number, body: unknown): void {
    const payload = JSON.stringify(body);
    res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) });
    res.end(payload);
  }
}
