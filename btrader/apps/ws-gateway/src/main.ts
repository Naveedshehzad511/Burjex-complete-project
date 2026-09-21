// ============================================================================
//  WebSocket Gateway — the single realtime endpoint the mobile/web clients use.
//  - Authenticates the connection with the access JWT (?token=...).
//  - Scopes every subscription to the user's tenant (multi-tenant isolation).
//  - Subscribes to Redis channels (ticks + engine events) for that tenant and
//    fans out only the symbols/accounts the client subscribed to.
//
//  Wire protocol (JSON):
//    client -> { op: "subscribe",   symbols: ["EURUSD"] }
//    client -> { op: "unsubscribe", symbols: ["EURUSD"] }
//    client -> { op: "watch_account", accountId }
//    client -> { op: "ping" }
//    server -> WsFrame  ({ t:"tick"|"account"|"position"|"order"|"pong", d })
// ============================================================================

import { WebSocketServer, WebSocket } from 'ws';
import Redis from 'ioredis';
import jwt from 'jsonwebtoken';
import {
  Channels,
  Tick,
  WsFrame,
  CandleEvent,
  posIdOf,
  payloadClosed,
  forceClosed,
  coalescePosition,
  openPositionsRedisKey,
  counters,
  latency,
} from '@btrader/shared';

const PORT = Number(process.env.WS_PORT ?? 4101);
const REDIS_URL = process.env.REDIS_URL ?? 'redis://localhost:6380';
const JWT_SECRET = process.env.JWT_SECRET ?? 'change-me-access-secret';

// Roles allowed to watch any account in their tenant (events stay tenant-scoped
// anyway). Everyone else may only watch accounts they own.
const ADMIN_ROLES = new Set(['SUPER_ADMIN', 'TENANT_ADMIN', 'TENANT_STAFF']);

interface ClientState {
  ws: WebSocket;
  tenantId: string;
  userId: string;
  isAdmin: boolean;
  ownedAccounts: Set<string>; // JWT acct/accts, else Redis jwtaccts:{userId}
  pendingWatch: Set<string>;
  symbols: Set<string>;
  accountIds: Set<string>;
  alive: boolean;
  /// Latest tick per symbol awaiting the next flush. Quotes are snapshots, so
  /// retaining an older tick would make the app paint a price that is already
  /// obsolete by the time it arrives.
  tickBuf: Map<string, Tick>;
  tickTimer?: ReturnType<typeof setTimeout>;
  /// True once the client has told us it understands batched tick frames.
  /// Older builds have not, and must keep receiving one tick per frame.
  wantsBatch: boolean;
  /// True when the client also understands the compact positional form.
  wantsCompact: boolean;
  /// Per-connection symbol -> small integer. Assigned on subscribe and sent to
  /// the client, so ticks can carry a number instead of repeating the name.
  symbolIds: Map<string, number>;
  nextSymbolId: number;
  /// True once the client has said it understands batched engine-event frames.
  wantsEvtBatch: boolean;
  /// Coalescing buffers for engine events, flushed together on evtTimer.
  ///
  /// Positions and accounts are SNAPSHOTS - each carries the whole current
  /// state - so when several arrive for the same id inside one window only the
  /// last is worth sending; keyed Maps drop the superseded ones. Orders are
  /// STATE TRANSITIONS (pending -> partial -> filled) and each one is news, so
  /// they queue in an array and none is ever collapsed away.
  evtPos: Map<string, unknown>;
  evtAcct: Map<string, unknown>;
  evtOrders: unknown[];
  evtTimer?: ReturnType<typeof setTimeout>;
}

// Quotes are snapshots, not a replay log. Coalesce only to the latest quote
// and flush in the next millisecond-class turn. A larger 40–50ms batch makes a
// tradeable bid/ask stale before the portal can paint it.
const TICK_FLUSH_MS = Math.min(1, Math.max(0, Number(process.env.WS_TICK_FLUSH_MS ?? 1)));

// Trade-state changes must reach the client immediately. Tick fan-out may
// still coalesce, but an order/fill/close must never wait behind a batch timer.
// Setting this above zero is an explicit compatibility/performance trade-off
// for clients that opt into `evts:true`; staging must validate that choice.
const EVT_BATCH_MS = Math.max(0, Number(process.env.WS_EVT_BATCH_MS ?? 0));

// A slow phone must never turn its kernel/WebSocket queue into an unbounded
// source of stale prices or memory pressure for all other clients. Disconnect
// it with 1013 ("try again later"); on reconnect it resubscribes and seeds from
// the current REST/Redis snapshot rather than replaying an obsolete backlog.
const MAX_BUFFERED_BYTES = Math.max(1, Number(process.env.WS_MAX_BUFFERED_BYTES ?? 1_048_576));
const MAX_TICK_BUFFER = Math.max(1, Number(process.env.WS_MAX_TICK_BUFFER ?? 2_048));
const MAX_EVT_BUFFER = Math.max(1, Number(process.env.WS_MAX_EVENT_BUFFER ?? 512));
const METRICS_LOG_MS = Math.max(0, Number(process.env.WS_METRICS_LOG_MS ?? 15_000));

/// Ids the engine has already closed (or claimed for SL/TP). A later OPEN
/// snapshot in the same 50ms coalesce window — or on the next tick — must not
/// resurrect them on the trader screen.
const CLOSED_TTL_MS = Number(process.env.WS_CLOSED_TTL_MS ?? 10 * 60_000);
const recentlyClosed = new Map<string, number>();

function rememberClosed(id: string) {
  if (!id) return;
  recentlyClosed.set(id, Date.now() + CLOSED_TTL_MS);
  if (recentlyClosed.size > 20_000) {
    const now = Date.now();
    for (const [k, exp] of recentlyClosed) {
      if (exp <= now) recentlyClosed.delete(k);
    }
  }
}

function stillClosed(id: string): boolean {
  if (!id) return false;
  const exp = recentlyClosed.get(id);
  if (exp == null) return false;
  if (Date.now() > exp) {
    recentlyClosed.delete(id);
    return false;
  }
  return true;
}

function mergePosition(prev: unknown, next: unknown): unknown {
  return coalescePosition(prev, next, stillClosed, rememberClosed);
}

const clients = new Set<ClientState>();

// ── Routing indexes ────────────────────────────────────────────────────────
//
// Every inbound message used to walk the whole client set to find its
// recipients, so delivering one position update to ONE owner cost a pass over
// every connected client. That is O(clients x events): fine at a few hundred
// users, ~600M iterations/sec at ten thousand, and hopeless beyond. These maps
// make routing O(recipients) instead.
//
// Keys are tenant-scoped, because symbol names and account ids are only unique
// within a tenant and a cross-tenant collision would leak one broker's data to
// another's client.
const byTenantSymbol = new Map<string, Set<ClientState>>();
const byAccount = new Map<string, Set<ClientState>>();

// Shared empty set for the `?? EMPTY` fallback - allocating one per miss would
// churn the hot path. Never mutated.
const EMPTY: ReadonlySet<ClientState> = new Set<ClientState>();

const tkey = (tenantId: string, symbol: string) => `${tenantId}\u0000${symbol}`;

function indexAdd(map: Map<string, Set<ClientState>>, key: string, c: ClientState) {
  let set = map.get(key);
  if (set === undefined) {
    set = new Set();
    map.set(key, set);
  }
  set.add(c);
}

function indexRemove(map: Map<string, Set<ClientState>>, key: string, c: ClientState) {
  const set = map.get(key);
  if (set === undefined) return;
  set.delete(c);
  // Drop the empty bucket, or a long-lived process accumulates one entry per
  // symbol/account ever seen - a slow leak that only shows up in production.
  if (set.size === 0) map.delete(key);
}

/// Single exit path for a client. Every disconnect route goes through here, so
/// there is one place that has to be right: a client left behind in an index
/// would keep receiving sends against a dead socket, and keep its buffers alive.
function dropClient(c: ClientState) {
  if (c.tickTimer !== undefined) clearTimeout(c.tickTimer);
  if (c.evtTimer !== undefined) clearTimeout(c.evtTimer);
  for (const sym of c.symbols) indexRemove(byTenantSymbol, tkey(c.tenantId, sym), c);
  for (const acct of c.accountIds) indexRemove(byAccount, tkey(c.tenantId, acct), c);
  clients.delete(c);
}
const sub = new Redis(REDIS_URL);
const redis = new Redis(REDIS_URL);

function disconnectSlowClient(c: ClientState, reason: string): void {
  counters.inc(`ws.disconnect.${reason}`);
  if (c.ws.readyState === WebSocket.OPEN || c.ws.readyState === WebSocket.CLOSING) {
    c.ws.close(1013, 'slow consumer: reconnect to resync');
  }
  dropClient(c);
}

/// Buffer one engine event for a client, coalescing where it is safe to.
///
/// Snapshot kinds (position, account) key by id so a later state replaces an
/// earlier one inside the same window - sending both would just render the
/// stale one first. Orders pass through unkeyed: each is a distinct transition
/// and dropping one loses the fill.
function queueEvt(c: ClientState, kind: 'position' | 'account' | 'order', key: string, body: unknown) {
  if (kind === 'position') {
    body = mergePosition(c.wantsEvtBatch ? c.evtPos.get(key) : undefined, body);
    const id = posIdOf(body);
    // Actual CLOSED / position_closed must hit the client immediately as
    // `t:"position"` (and `t:"position_closed"`) — bypass the 50ms evt batch.
    if (id && (payloadClosed(body) || stillClosed(id))) {
      rememberClosed(id);
      body = forceClosed(body, id);
      send(c, { t: 'position', d: body } as WsFrame);
      send(c, { t: 'position_closed', d: body } as WsFrame);
      if (c.wantsEvtBatch) c.evtPos.delete(key);
      return;
    }
  }
  if (!c.wantsEvtBatch || EVT_BATCH_MS <= 0) {
    // The default is immediate, for old and new clients alike. Fills and
    // closes are state transitions, not a UI update that can sit 50 ms behind
    // a last-write-wins buffer.
    send(c, { t: kind, d: body } as WsFrame);
    return;
  }
  if (kind === 'position') {
    c.evtPos.set(key, body);
  } else if (kind === 'account') c.evtAcct.set(key, body);
  else c.evtOrders.push(body);

  if (c.evtPos.size + c.evtAcct.size + c.evtOrders.length > MAX_EVT_BUFFER) {
    disconnectSlowClient(c, 'event_buffer');
    return;
  }
  if (c.evtTimer === undefined) {
    c.evtTimer = setTimeout(() => flushEvts(c), EVT_BATCH_MS);
  }
}

/// Emit one frame carrying everything buffered for this client.
function flushEvts(c: ClientState) {
  c.evtTimer = undefined;
  if (c.evtPos.size === 0 && c.evtAcct.size === 0 && c.evtOrders.length === 0) return;
  const frame = {
    t: 'evts',
    d: {
      p: [...c.evtPos.values()],
      a: [...c.evtAcct.values()],
      o: c.evtOrders,
    },
  };
  c.evtPos = new Map();
  c.evtAcct = new Map();
  c.evtOrders = [];
  send(c, frame as unknown as WsFrame);
}

function send(c: ClientState, frame: WsFrame): boolean {
  if (c.ws.readyState !== WebSocket.OPEN) return false;
  if (c.ws.bufferedAmount > MAX_BUFFERED_BYTES) {
    disconnectSlowClient(c, 'socket_buffer');
    return false;
  }
  const stop = latency.start('ws.enqueue');
  try {
    c.ws.send(JSON.stringify(frame));
    return true;
  } finally {
    stop();
  }
}

/// Emit this client's buffered ticks as one frame.
///
/// Two shapes, chosen by what the client said it understands:
///
///   `ticks` — array of tick objects. Readable, ~68 bytes per tick.
///   `k`     — array of `[symbolId, bid, ask, ts]`. ~36 bytes per tick.
///
/// Half of a JSON tick is its field names and symbol string, repeated on every
/// single one. At a few hundred ticks a second that is hundreds of megabytes of
/// a trader's mobile data over a session, and tens of gigabytes of egress per
/// day once there are many of them — for bytes that carry no information after
/// the first tick. The positional form drops both without leaving JSON, so
/// frames stay readable in a debugger.
function flushTicks(c: ClientState): void {
  c.tickTimer = undefined;
  if (c.tickBuf.size === 0) return;
  const batch = [...c.tickBuf.values()];
  c.tickBuf.clear();
  if (!c.wantsCompact) {
    send(c, { t: 'ticks', d: batch } as unknown as WsFrame);
    return;
  }
  const rows: Array<[number, number, number, number]> = [];
  for (const t of batch) {
    const id = c.symbolIds.get(t.symbol);
    if (id === undefined) continue; // never assigned: cannot be decoded
    rows.push([id, t.bid, t.ask, t.ts]);
  }
  if (rows.length > 0) send(c, { t: 'k', d: rows } as unknown as WsFrame);
}

/// Assign ids to any newly subscribed symbols and tell the client the mapping.
/// Sent before any tick can reference them, so a client never sees an unknown id.
function announceSymbolIds(c: ClientState, symbols: string[]): void {
  const fresh: Record<string, number> = {};
  for (const sym of symbols) {
    if (c.symbolIds.has(sym)) continue;
    const id = c.nextSymbolId++;
    c.symbolIds.set(sym, id);
    fresh[sym] = id;
  }
  if (Object.keys(fresh).length > 0) {
    send(c, { t: 'sym', d: fresh } as unknown as WsFrame);
  }
}

// One pattern subscription; route by channel -> tenant.
sub.psubscribe(
  `bt:*:${Channels.TICKS}`,
  `bt:*:${Channels.CANDLES}`,
  `bt:*:${Channels.ENGINE_EVT}`,
);
sub.on('pmessage', async (_pattern, channel, message) => {
  const parts = channel.split(':');
  const tenantId = parts[1];
  const kind = parts[2];

  if (kind === Channels.TICKS) {
    let tick: Tick;
    try {
      tick = JSON.parse(message) as Tick;
    } catch {
      console.error('[ws-gateway] Invalid tick JSON:', message);
      return;
    }
    // Coalesce only snapshots for the same symbol. A delayed replay of every
    // intermediary quote is worse than dropping superseded snapshots because
    // it makes the visible bid/ask lag the price accepted by the engine.
    const priceAgeMs = Date.now() - tick.ts;
    if (Number.isFinite(priceAgeMs) && priceAgeMs >= 0) latency.record('ws.price_age', priceAgeMs);
    for (const c of byTenantSymbol.get(tkey(tenantId, tick.symbol)) ?? EMPTY) {
      if (TICK_FLUSH_MS <= 0 || !c.wantsBatch) {
        send(c, { t: 'tick', d: tick });
        continue;
      }
      if (c.tickBuf.size >= MAX_TICK_BUFFER && !c.tickBuf.has(tick.symbol)) {
        disconnectSlowClient(c, 'tick_buffer');
        continue;
      }
      const previous = c.tickBuf.get(tick.symbol);
      if (previous && tick.ts < previous.ts) continue;
      c.tickBuf.set(tick.symbol, tick);
      if (c.tickTimer === undefined) {
        c.tickTimer = setTimeout(() => flushTicks(c), TICK_FLUSH_MS);
      }
    }
    return;
  }

  // Server-authoritative chart bars. Already transformed into this tenant's
  // visible price by market-data, so the gateway only has to route them.
  if (kind === Channels.CANDLES) {
    let candle: CandleEvent;
    try {
      candle = JSON.parse(message) as CandleEvent;
    } catch {
      console.error('[ws-gateway] Invalid candle JSON:', message);
      return;
    }
    for (const c of byTenantSymbol.get(tkey(tenantId, candle.symbol)) ?? EMPTY) {
      send(c, { t: 'candle', d: candle });
    }
    return;
  }

  if (kind === Channels.ENGINE_EVT) {
    let evt: any;
    try {
      evt = JSON.parse(message);
    } catch {
      counters.inc('ws.invalid_engine_event');
      return;
    }
    const emittedAt = Number(evt.emittedAt);
    const eventAgeMs = Date.now() - emittedAt;
    if (Number.isFinite(eventAgeMs) && eventAgeMs >= 0) latency.record('ws.engine_event_age', eventAgeMs);

    // Nested `position` carries closing/SL/TP; top-level is used by close fills.
    const isClosedOrSlTp = payloadClosed(evt) || payloadClosed(evt.position);

    // A position event arrives in one of two shapes. emitLiveUpdates sends a
    // full snapshot under `position`; open / close / modify send only ids at
    // the top level. This used to require `evt.position`, so every one of the
    // second kind was silently dropped - a closed position simply stopped
    // updating on the client and sat there stale, because the close never
    // arrived. Route on whichever carries the account.
    let rawPosBody =
      evt.kind === 'POSITION_UPDATE'
        ? evt.position ??
          (evt.accountId
            ? {
                id: evt.positionId,
                accountId: evt.accountId,
                status: isClosedOrSlTp ? 'CLOSED' : undefined,
                book: isClosedOrSlTp ? 'closed' : evt.book,
                closing: isClosedOrSlTp,
                stale: !isClosedOrSlTp && !evt.position,
              }
            : null)
        : null;

    // Ensure closing flags and status are properly enforced on rawPosBody if it exists
    // Keep A/B book ("A"/"B") on live rows. Only overwrite book when the
    // engine has actually closed the ticket.
    let posBody = rawPosBody
      ? {
          ...rawPosBody,
          book: isClosedOrSlTp ? 'closed' : rawPosBody.book || evt.book,
          status: isClosedOrSlTp ? 'CLOSED' : rawPosBody.status || evt.position?.status || 'OPEN',
          closing: isClosedOrSlTp ? true : rawPosBody.closing || false,
          event: isClosedOrSlTp ? 'position_closed' : rawPosBody.event || evt.event,
          reason: evt.reason || rawPosBody.reason,
        }
      : null;

    const posAccount = posBody?.accountId;
    // The compact fill event intentionally used to contain only an id and
    // account. That is sufficient for a REST reconciliation but not for a
    // live portal session that must render the new Trade row and Chart SL/TP
    // lines without a page refresh. The matcher has already written the
    // authoritative snapshot before publishing position_opened, so enrich
    // this one transition from Redis rather than polling REST from clients.
    if (posBody?.event === 'position_opened' && posAccount) {
      try {
        const raw = await redis.get(openPositionsRedisKey(tenantId, posAccount));
        const snapshot = raw ? JSON.parse(raw) as { positions?: unknown } : null;
        const positions = Array.isArray(snapshot?.positions) ? snapshot.positions : [];
        const id = String(posBody.id ?? posBody.positionId ?? '');
        const full = positions.find((p: any) => String(p?.id ?? p?.positionId ?? '') === id);
        if (full && typeof full === 'object') {
          posBody = {
            ...posBody,
            ...(full as Record<string, unknown>),
            status: 'OPEN',
            closing: false,
            event: 'position_opened',
          };
        }
      } catch {
        // The original event still reaches the client; reconnect snapshot
        // remains the fallback if Redis is temporarily unavailable.
      }
    }

    // Each branch touches only the clients watching that one account.
    if (evt.kind === 'ACCOUNT_UPDATE' && evt.account?.accountId) {
      for (const c of byAccount.get(tkey(tenantId, evt.account.accountId)) ?? EMPTY) {
        queueEvt(c, 'account', evt.account.accountId, evt.account);
      }
    }
    if (posBody && posAccount) {
      const key = String(posBody.id ?? posBody.positionId);
      for (const c of byAccount.get(tkey(tenantId, posAccount)) ?? EMPTY) {
        queueEvt(c, 'position', key, posBody);
      }
    }
    if (evt.kind === 'ORDER_UPDATE' && evt.order?.accountId) {
      for (const c of byAccount.get(tkey(tenantId, evt.order.accountId)) ?? EMPTY) {
        queueEvt(c, 'order', '', evt.order);
      }
    }
  }
});

const wss = new WebSocketServer({ port: PORT });

async function ownedAccountIds(claims: {
  sub: string;
  acct?: string;
  accts?: string[];
}): Promise<Set<string>> {
  if (claims.acct) return new Set([claims.acct]);
  if (Array.isArray(claims.accts) && claims.accts.length) return new Set(claims.accts);
  try {
    const raw = await redis.get(`jwtaccts:${claims.sub}`);
    if (raw) {
      const ids = JSON.parse(raw);
      if (Array.isArray(ids)) return new Set(ids.filter((id) => typeof id === 'string'));
    }
  } catch {
    /* Quotes/HTTP still work; watch_account stays closed until Redis is populated. */
  }
  return new Set();
}

wss.on('connection', (ws, req) => {
  const url = new URL(req.url ?? '', 'http://localhost');
  const token = url.searchParams.get('token') ?? '';
  let claims: { sub: string; tenantId: string; role?: string; accts?: string[]; acct?: string };
  try {
    claims = jwt.verify(token, JWT_SECRET) as any;
  } catch {
    ws.close(4401, 'unauthorized');
    return;
  }

  const seeded = claims.acct ? new Set([claims.acct]) : new Set(claims.accts ?? []);
  const state = attachClient(ws, claims, seeded);
  if (!claims.acct && !(claims.accts && claims.accts.length)) {
    void ownedAccountIds(claims).then((owned) => {
      for (const id of owned) state.ownedAccounts.add(id);
      for (const id of [...state.pendingWatch]) {
        if (state.ownedAccounts.has(id)) {
          state.pendingWatch.delete(id);
          watchAccount(state, id);
        }
      }
    });
  }
});

function watchAccount(state: ClientState, accountId: string) {
  state.accountIds.add(accountId);
  indexAdd(byAccount, tkey(state.tenantId, accountId), state);
  void pushOpenSnapshot(state, accountId);
}

async function pushOpenSnapshot(state: ClientState, accountId: string) {
  try {
    const raw = await redis.get(openPositionsRedisKey(state.tenantId, accountId));
    if (raw == null) return;
    const parsed = JSON.parse(raw) as { positions?: unknown };
    const positions = Array.isArray(parsed?.positions) ? parsed.positions : [];
    send(state, {
      t: 'positions',
      d: { snapshot: true, accountId, positions },
    } as WsFrame);
  } catch {
    /* live POSITION_UPDATE events still apply */
  }
}

function attachClient(
  ws: WebSocket,
  claims: { sub: string; tenantId: string; role?: string; accts?: string[]; acct?: string },
  ownedAccounts: Set<string>,
): ClientState {
  const state: ClientState = {
    ws,
    tenantId: claims.tenantId,
    userId: claims.sub,
    isAdmin: ADMIN_ROLES.has(claims.role ?? ''),
    ownedAccounts,
    pendingWatch: new Set(),
    symbols: new Set(),
    accountIds: new Set(),
    alive: true,
    tickBuf: new Map(),
    wantsBatch: false,
    wantsCompact: false,
    symbolIds: new Map(),
    nextSymbolId: 1,
    wantsEvtBatch: false,
    evtPos: new Map(),
    evtAcct: new Map(),
    evtOrders: [],
  };
  clients.add(state);

  ws.on('message', (raw) => {
    let msg: any;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }
    switch (msg.op) {
      case 'subscribe': {
        // Opt-in so a client built before batching existed keeps working.
        if (msg.batch === true) state.wantsBatch = true;
        if (msg.compact === true) state.wantsCompact = true;
        // Deliberately its own flag rather than reusing `batch`: builds already
        // in the field send batch:true meaning TICK batching only, and would
        // not know what to do with a batched engine-event frame.
        if (msg.evts === true) state.wantsEvtBatch = true;
        const subs: string[] = msg.symbols ?? [];
        subs.forEach((sym: string) => {
          state.symbols.add(sym);
          indexAdd(byTenantSymbol, tkey(state.tenantId, sym), state);
        });
        if (state.wantsCompact) announceSymbolIds(state, subs);
      }
        break;
      case 'unsubscribe':
        (msg.symbols ?? []).forEach((sym: string) => {
          state.symbols.delete(sym);
          indexRemove(byTenantSymbol, tkey(state.tenantId, sym), state);
        });
        break;
      case 'watch_account':
        if (msg.accountId && (state.isAdmin || state.ownedAccounts.has(msg.accountId))) {
          watchAccount(state, msg.accountId);
        } else if (msg.accountId && !state.isAdmin) {
          state.pendingWatch.add(msg.accountId);
        }
        break;
      case 'unwatch_account':
        if (msg.accountId) {
          state.accountIds.delete(msg.accountId);
          indexRemove(byAccount, tkey(state.tenantId, msg.accountId), state);
        }
        break;
      case 'ping':
        send(state, { t: 'pong', d: { ts: Date.now() } });
        break;
    }
  });

  ws.on('pong', () => (state.alive = true));
  ws.on('close', () => dropClient(state));
  return state;
}

// Heartbeat: drop dead connections.
setInterval(() => {
  for (const c of clients) {
    if (!c.alive) {
      c.ws.terminate();
      dropClient(c);
      continue;
    }
    c.alive = false;
    if (c.ws.readyState === WebSocket.OPEN) c.ws.ping();
  }
}, 30_000);

if (METRICS_LOG_MS > 0) {
  setInterval(() => {
    const queuedTicks = [...clients].reduce((n, c) => n + c.tickBuf.size, 0);
    const queuedEvents = [...clients].reduce(
      (n, c) => n + c.evtPos.size + c.evtAcct.size + c.evtOrders.length,
      0,
    );
    console.log(
      '[ws-metrics]',
      JSON.stringify({
        clients: clients.size,
        queuedTicks,
        queuedEvents,
        counters: counters.snapshot(),
        latency: latency.snapshot(),
      }),
    );
  }, METRICS_LOG_MS);
}

// eslint-disable-next-line no-console
console.log(`[ws-gateway] listening on :${PORT}`);
