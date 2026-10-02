#!/usr/bin/env node
/**
 * End-to-end check of the rapid Buy/Sell requirement against a running stack (local by default).
 *
 *   LOGIN=500004 PASSWORD=... node btrader/loadtest/rapid_orders_e2e.cjs
 *
 * What it does
 *   1. logs in (account number + password) and reads the account's group execution rule
 *      from the engine's own audit comment on each fill (never from a hardcoded value);
 *   2. opens a WebSocket for the account and records when each `opened` event arrives;
 *   3. fires COUNT market orders CONCURRENTLY (each with its own clientOrderId), like 12 fast
 *      clicks that are not blocked by one another;
 *   4. polls GET /positions to record when the confirmed count reached 1..COUNT;
 *   5. prints per-order latency, the count timeline and the checks below, then closes ONLY the
 *      positions it opened (never close-all: the account may hold the tester's own trades).
 *
 * Checks (exit code 1 if any fails)
 *   - every accepted order produced exactly one position, and the list ends with all of them
 *   - no order was rejected as "account busy" / rate limited
 *   - Instant group:   every order is confirmed within MAX_INSTANT_MS (default 1500)
 *   - Delay group:     no order is confirmed EARLIER than the configured delay, and the whole burst
 *                      finishes well inside COUNT x delay (it is not processed one after another)
 *
 * Env: LOGIN, PASSWORD (required) | BASE (default http://localhost:6500) | SYMBOL (default EURUSD)
 *      SIDE (BUY|SELL, default BUY) | VOLUME (default 0.01) | COUNT (default 12) | TENANT (X-BT-Tenant)
 *      EXPECT_DELAY_MS (optional: assert the group delay equals this) | KEEP=1 (leave trades open)
 */
const BASE = (process.env.BASE || 'http://localhost:6500').replace(/\/$/, '');
const LOGIN = process.env.LOGIN;
const PASSWORD = process.env.PASSWORD;
const SYMBOL = process.env.SYMBOL || 'EURUSD';
const SIDE = (process.env.SIDE || 'BUY').toUpperCase();
const VOLUME = Number(process.env.VOLUME || 0.01);
const COUNT = Number(process.env.COUNT || 12);
const TENANT = process.env.TENANT || 'demo';
const MAX_INSTANT_MS = Number(process.env.MAX_INSTANT_MS || 1500);

if (!LOGIN || !PASSWORD) {
  console.error('Set LOGIN and PASSWORD (a test trading account).');
  process.exit(2);
}

const now = () => Number(process.hrtime.bigint() / 1000000n);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, path, body, token) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      'content-type': 'application/json',
      'x-bt-tenant': TENANT,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body == null ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { message: text };
  }
  return { status: res.status, json };
}

function loadWs() {
  try {
    return require('ws');
  } catch {
    /* pnpm layout: look next to the workspace */
  }
  const fs = require('fs');
  const path = require('path');
  const pnpm = path.join(__dirname, '..', 'node_modules', '.pnpm');
  const hit = fs.existsSync(pnpm) && fs.readdirSync(pnpm).find((d) => d.startsWith('ws@'));
  return hit ? require(path.join(pnpm, hit, 'node_modules', 'ws')) : null;
}

(async () => {
  const login = await api('POST', '/v1/auth/account-login', { login: LOGIN, password: PASSWORD });
  const token = login.json.accessToken;
  if (!token) {
    console.error('login failed', login.status, JSON.stringify(login.json).slice(0, 200));
    process.exit(2);
  }
  const accts = await api('GET', '/v1/accounts/me', null, token);
  const account = (Array.isArray(accts.json) ? accts.json : []).find((a) => String(a.login) === String(LOGIN)) || accts.json[0];
  const accountId = account.id;
  const before = await api('GET', `/v1/positions?accountId=${accountId}&status=OPEN&fresh=1`, null, token);
  const preexisting = new Set(before.json.map((p) => p.id));
  console.log(`account ${LOGIN} (${accountId})  open positions before: ${preexisting.size}`);

  // --- WebSocket: when does each confirmed open reach a client? ---------------------------
  const wsEvents = new Map(); // positionId -> ms
  let t0 = 0;
  const WS = loadWs();
  let ws;
  if (WS) {
    const wsUrl = BASE.replace(/^http/, 'ws') + `/?token=${token}`;
    ws = new WS(wsUrl);
    await new Promise((res) => {
      ws.on('open', () => {
        ws.send(JSON.stringify({ op: 'watch_account', accountId }));
        ws.send(JSON.stringify({ op: 'subscribe', symbols: [SYMBOL], batch: true, evts: true, compact: true }));
        res();
      });
      ws.on('error', res);
      setTimeout(res, 3000);
    });
    ws.on('message', (raw) => {
      let f;
      try {
        f = JSON.parse(raw.toString());
      } catch {
        return;
      }
      const list = f.t === 'evts' ? f.d.p || [] : f.t === 'position' ? [f.d] : [];
      for (const p of list) {
        if (p && p.opened === true && p.id && !wsEvents.has(p.id)) wsEvents.set(p.id, now() - t0);
      }
    });
    await sleep(300);
  } else {
    console.log('(ws module not found - skipping WebSocket timing)');
  }

  // --- poll the positions list while the burst runs ---------------------------------------
  const countAt = []; // [ms, count of NEW positions]
  let polling = true;
  const poller = (async () => {
    let last = -1;
    while (polling) {
      const r = await api('GET', `/v1/positions?accountId=${accountId}&status=OPEN&fresh=1`, null, token);
      const n = (r.json || []).filter((p) => !preexisting.has(p.id)).length;
      if (n !== last) {
        countAt.push([now() - t0, n]);
        last = n;
      }
      await sleep(40);
    }
  })();

  // --- the burst --------------------------------------------------------------------------
  t0 = now();
  const results = await Promise.all(
    Array.from({ length: COUNT }, async (_, i) => {
      const sent = now() - t0;
      const r = await api(
        'POST',
        '/v1/orders',
        {
          accountId,
          symbol: SYMBOL,
          side: SIDE,
          type: 'MARKET',
          volume: VOLUME,
          oneClick: true,
          clientOrderId: `e2e-${Date.now()}-${i}-${Math.random().toString(16).slice(2)}`,
        },
        token,
      );
      return { i, sent, done: now() - t0, status: r.status, body: r.json };
    }),
  );
  const burstMs = now() - t0;
  await sleep(500); // let the last events / list refresh land
  polling = false;
  await poller;
  if (ws) ws.close();

  const accepted = results.filter((r) => r.body && r.body.accepted === true);
  const rejected = results.filter((r) => !(r.body && r.body.accepted === true));
  console.log(`\n${COUNT} orders sent in parallel -> accepted ${accepted.length}, rejected/failed ${rejected.length}, burst finished in ${burstMs} ms`);
  console.log('\n #  sent(ms)  answered(ms)  status  result');
  for (const r of results.sort((a, b) => a.done - b.done)) {
    const b = r.body || {};
    console.log(
      `${String(r.i + 1).padStart(2)}  ${String(r.sent).padStart(8)}  ${String(r.done).padStart(12)}  ${String(r.status).padStart(6)}  ` +
        (b.accepted ? `FILLED @ ${b.fillPrice} pos=${String(b.positionId).slice(0, 8)}` : `REJECTED ${b.reason || b.message || ''}`),
    );
  }
  console.log('\nconfirmed positions visible in GET /positions over time (ms -> count):');
  console.log('  ' + countAt.map(([t, n]) => `${t}->${n}`).join('  '));
  if (WS) {
    const ev = [...wsEvents.values()].sort((a, b) => a - b);
    console.log(`WS "opened" events received: ${ev.length}  first/last at ${ev[0] ?? '-'} / ${ev[ev.length - 1] ?? '-'} ms`);
  }

  // --- the group rule actually applied, taken from the engine's own audit comment ----------
  const deals = await api('GET', `/v1/history/deals?accountId=${accountId}`, null, token);
  let delayMs = null;
  for (const d of deals.json || []) {
    if (accepted.some((a) => a.body.positionId === d.positionId) && d.comment) {
      try {
        delayMs = JSON.parse(d.comment).delayMs;
        break;
      } catch {
        /* comment is not JSON */
      }
    }
  }
  console.log(`\ngroup execution delay applied by the engine (from its audit record): ${delayMs == null ? 'unknown' : delayMs + ' ms'}`);

  // --- checks -----------------------------------------------------------------------------
  const fails = [];
  const ids = new Set(accepted.map((a) => a.body.positionId));
  const finalList = (await api('GET', `/v1/positions?accountId=${accountId}&status=OPEN&fresh=1`, null, token)).json;
  const visible = finalList.filter((p) => ids.has(p.id)).length;
  if (ids.size !== accepted.length) fails.push('two accepted orders returned the same position');
  if (visible !== accepted.length) fails.push(`only ${visible} of ${accepted.length} accepted trades are in the positions list`);
  const busy = rejected.filter((r) => /busy|rate limit/i.test(JSON.stringify(r.body)));
  if (busy.length) fails.push(`${busy.length} order(s) rejected as busy / rate limited`);
  if (process.env.EXPECT_DELAY_MS != null && delayMs !== Number(process.env.EXPECT_DELAY_MS)) {
    fails.push(`expected delay ${process.env.EXPECT_DELAY_MS} ms but the engine applied ${delayMs}`);
  }
  const lat = accepted.map((a) => a.done);
  if (delayMs === 0) {
    if (Math.max(...lat) > MAX_INSTANT_MS) fails.push(`Instant group but slowest order took ${Math.max(...lat)} ms (> ${MAX_INSTANT_MS})`);
  } else if (delayMs > 0) {
    if (Math.min(...lat) < delayMs - 15) fails.push(`an order was confirmed in ${Math.min(...lat)} ms, before the configured ${delayMs} ms`);
    if (Math.max(...lat) > delayMs + 1500) fails.push(`slowest order took ${Math.max(...lat)} ms: well beyond the configured ${delayMs} ms`);
    if (burstMs > delayMs * COUNT * 0.5) fails.push(`burst took ${burstMs} ms - orders are being processed one after another`);
  }
  console.log(fails.length ? '\nFAIL\n - ' + fails.join('\n - ') : '\nPASS: all checks held');

  // --- cleanup: only what this run opened -------------------------------------------------
  if (!process.env.KEEP) {
    let closed = 0;
    for (const pid of ids) {
      const r = await api('POST', `/v1/positions/${pid}/close`, {}, token);
      if (r.status < 300) closed++;
    }
    await sleep(800);
    const hist = await api('GET', `/v1/history/deals?accountId=${accountId}`, null, token);
    const closeDeals = (hist.json || []).filter((d) => ids.has(d.positionId) && (d.type === 'CLOSE' || d.type === 'PARTIAL_CLOSE')).length;
    console.log(`cleanup: closed ${closed}/${ids.size} test trades; History shows ${closeDeals} matching CLOSE deals`);
    if (closeDeals !== ids.size) {
      console.log('WARN: History does not list every closed test trade yet');
      process.exitCode = 1;
    }
  }
  if (fails.length) process.exitCode = 1;
})().catch((e) => {
  console.error(e);
  process.exit(2);
});
