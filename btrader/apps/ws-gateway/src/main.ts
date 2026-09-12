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
import { Channels, Tick, WsFrame, CandleEvent } from '@btrader/shared';

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
  ownedAccounts: Set<string>; // account IDs from the JWT (non-admins gated to these)
  symbols: Set<string>;
  accountIds: Set<string>;
  alive: boolean;
  /// Ticks awaiting the next batch flush, in arrival order.
  tickBuf: Tick[];
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

// How long ticks may sit in a client's outbound buffer before being flushed as
// one batch. This BATCHES, it never drops: every tick still reaches every
// subscribed client. 0 sends each tick in its own frame, as before.
const TICK_BATCH_MS = Number(process.env.WS_TICK_BATCH_MS ?? 40);

// How long engine events may sit in a client's buffer before being flushed.
// Small enough to stay imperceptible on a trade action, large enough that a
// client holding many positions gets one frame per window instead of one per
// position. Like TICK_BATCH_MS this batches, it never drops.
const EVT_BATCH_MS = Number(process.env.WS_EVT_BATCH_MS ?? 50);

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

/// Buffer one engine event for a client, coalescing where it is safe to.
///
/// Snapshot kinds (position, account) key by id so a later state replaces an
/// earlier one inside the same window - sending both would just render the
/// stale one first. Orders pass through unkeyed: each is a distinct transition
/// and dropping one loses the fill.
function queueEvt(c: ClientState, kind: 'position' | 'account' | 'order', key: string, body: unknown) {
  if (!c.wantsEvtBatch) {
    // Old client: unchanged one-frame-per-event behaviour.
    send(c.ws, { t: kind, d: body } as WsFrame);
    return;
  }
  if (kind === 'position') c.evtPos.set(key, body);
  else if (kind === 'account') c.evtAcct.set(key, body);
  else c.evtOrders.push(body);

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
  send(c.ws, frame as unknown as WsFrame);
}

function send(ws: WebSocket, frame: WsFrame) {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(frame));
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
  if (c.tickBuf.length === 0) return;
  const batch = c.tickBuf;
  c.tickBuf = [];
  if (!c.wantsCompact) {
    send(c.ws, { t: 'ticks', d: batch } as unknown as WsFrame);
    return;
  }
  const rows: Array<[number, number, number, number]> = [];
  for (const t of batch) {
    const id = c.symbolIds.get(t.symbol);
    if (id === undefined) continue; // never assigned: cannot be decoded
    rows.push([id, t.bid, t.ask, t.ts]);
  }
  if (rows.length > 0) send(c.ws, { t: 'k', d: rows } as unknown as WsFrame);
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
    send(c.ws, { t: 'sym', d: fresh } as unknown as WsFrame);
  }
}

// One pattern subscription; route by channel -> tenant.
sub.psubscribe(
  `bt:*:${Channels.TICKS}`,
  `bt:*:${Channels.CANDLES}`,
  `bt:*:${Channels.ENGINE_EVT}`,
);
sub.on('pmessage', (_pattern, channel, message) => {
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
    // Batch, do not drop.
    //
    // The feed carries roughly two thousand ticks a second. Sending each in its
    // own WebSocket frame means a separate parse, allocation and event-loop
    // wake-up per tick on the client. A desktop absorbs that; a phone cannot
    // keep up, its receive queue backs up, and — because a queue only grows —
    // the prices on screen fall further behind the market the longer the app
    // is open.
    //
    // Dropping ticks would fix the symptom and lose data the platform is
    // supposed to deliver. Batching fixes the same cost without losing a single
    // one: N ticks arrive as one frame and cost one parse instead of N. The
    // client unpacks the array and applies every tick in order, so day
    // high/low and anything else derived per tick stay exact.
    for (const c of byTenantSymbol.get(tkey(tenantId, tick.symbol)) ?? EMPTY) {
      if (TICK_BATCH_MS <= 0 || !c.wantsBatch) {
        send(c.ws, { t: 'tick', d: tick });
        continue;
      }
      c.tickBuf.push(tick);
      if (c.tickTimer === undefined) {
        c.tickTimer = setTimeout(() => flushTicks(c), TICK_BATCH_MS);
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
      send(c.ws, { t: 'candle', d: candle });
    }
    return;
  }

  if (kind === Channels.ENGINE_EVT) {
    const evt = JSON.parse(message);

    // A position event arrives in one of two shapes. emitLiveUpdates sends a
    // full snapshot under `position`; open / close / modify send only ids at
    // the top level. This used to require `evt.position`, so every one of the
    // second kind was silently dropped - a closed position simply stopped
    // updating on the client and sat there stale, because the close never
    // arrived. Route on whichever carries the account.
    const posBody =
      evt.kind === 'POSITION_UPDATE'
        ? evt.position ??
          (evt.accountId
            ? {
                id: evt.positionId,
                accountId: evt.accountId,
                status: evt.book === 'closed' ? 'CLOSED' : undefined,
                book: evt.book,
                stale: evt.book !== 'closed' && !evt.position,
              }
            : null)
        : null;
    const posAccount = posBody?.accountId;

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

wss.on('connection', (ws, req) => {
  const url = new URL(req.url ?? '', 'http://localhost');
  const token = url.searchParams.get('token') ?? '';
  let claims: { sub: string; tenantId: string; role?: string; accts?: string[] };
  try {
    claims = jwt.verify(token, JWT_SECRET) as any;
  } catch {
    ws.close(4401, 'unauthorized');
    return;
  }

  const state: ClientState = {
    ws,
    tenantId: claims.tenantId,
    userId: claims.sub,
    isAdmin: ADMIN_ROLES.has(claims.role ?? ''),
    ownedAccounts: new Set(claims.accts ?? []),
    symbols: new Set(),
    accountIds: new Set(),
    alive: true,
    tickBuf: [],
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
        // Authorize: admins may watch any account in their tenant; everyone else
        // only their own accounts (from the JWT). Silently ignore otherwise.
        if (msg.accountId && (state.isAdmin || state.ownedAccounts.has(msg.accountId))) {
          state.accountIds.add(msg.accountId);
          indexAdd(byAccount, tkey(state.tenantId, msg.accountId), state);
        }
        break;
      case 'unwatch_account':
        if (msg.accountId) {
          state.accountIds.delete(msg.accountId);
          indexRemove(byAccount, tkey(state.tenantId, msg.accountId), state);
        }
        break;
      case 'ping':
        send(ws, { t: 'pong', d: { ts: Date.now() } });
        break;
    }
  });

  ws.on('pong', () => (state.alive = true));
  ws.on('close', () => dropClient(state));
});

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

// eslint-disable-next-line no-console
console.log(`[ws-gateway] listening on :${PORT}`);
