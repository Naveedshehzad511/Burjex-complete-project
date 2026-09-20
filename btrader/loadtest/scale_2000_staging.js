/**
 * 2,000 concurrent-trader capacity scenario — STAGING ONLY.
 *
 * It logs in one disposable account per VU, keeps a WebSocket subscription
 * active, opens two market positions, modifies protection, and closes both.
 * It emits client-side ack/close/WS timings; service logs provide the
 * correlated gateway→matcher→Redis→WS hops via the returned traceId/orderId.
 *
 * Never target portal.burjexprime.net, api.burjexprime.net, 5.226.139.8, or a
 * production database. The preflight below rejects those hosts.
 *
 * Example:
 *   k6 run -e BASE_URL=http://127.0.0.1:5100 -e WS_URL=ws://127.0.0.1:5101 \
 *     -e TENANT=loadtest -e PASSWORD='disposable-only' -e LOGIN_BASE=700000 \
 *     btrader/loadtest/scale_2000_staging.js
 */
import http from 'k6/http';
import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const BASE = (__ENV.BASE_URL || 'http://127.0.0.1:5100').replace(/\/+$/, '');
const WS_URL = (__ENV.WS_URL || BASE.replace(/^http/, 'ws').replace(/:5100$/, ':5101')).replace(/\/+$/, '');
const TENANT = __ENV.TENANT || 'loadtest';
const PASSWORD = __ENV.PASSWORD || '';
const LOGIN_BASE = Number(__ENV.LOGIN_BASE || 700000);
const SYMBOL = (__ENV.SYMBOL || 'EURUSD').toUpperCase();
const VOLUME = Number(__ENV.VOLUME || 0.01);
const TARGET_VUS = Number(__ENV.VUS || 2000);
const HOLD = __ENV.HOLD || '5m';

const errors = new Rate('scale_errors');
const orderAckMs = new Trend('order_ack_ms', true);
const closeAckMs = new Trend('close_ack_ms', true);
const wsConnectMs = new Trend('ws_connect_ms', true);
const wsStateMs = new Trend('ws_state_ms', true);
const wsConnects = new Counter('ws_connects');

export const options = {
  scenarios: {
    traders: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '4m', target: TARGET_VUS },
        { duration: HOLD, target: TARGET_VUS },
        { duration: '2m', target: 0 },
      ],
      gracefulRampDown: '1m',
    },
  },
  thresholds: {
    scale_errors: ['rate<0.01'],
    http_req_failed: ['rate<0.01'],
    order_ack_ms: ['p(95)<250', 'p(99)<500'],
    close_ack_ms: ['p(95)<250', 'p(99)<500'],
    ws_connect_ms: ['p(95)<500'],
    ws_state_ms: ['p(95)<250', 'p(99)<500'],
  },
};

function assertSafeHost(raw) {
  const host = new URL(raw).hostname.toLowerCase();
  if (
    host === '5.226.139.8' ||
    host === 'portal.burjexprime.net' ||
    host === 'api.burjexprime.net' ||
    host === 'ws.burjexprime.net' ||
    host.endsWith('.burjexprime.net')
  ) {
    throw new Error(`Refusing to load test a production Burjex host: ${host}`);
  }
}

function headers(token) {
  return {
    'Content-Type': 'application/json',
    'X-BT-Tenant': TENANT,
    Authorization: `Bearer ${token}`,
    // Keep the staging-only override explicit and auditable when configured.
    ...( __ENV.LOAD_TEST_KEY ? { 'X-BT-Load-Test': __ENV.LOAD_TEST_KEY } : {}),
  };
}

function parse(res) {
  try { return res.json(); } catch (_) { return {}; }
}

function openSocket(token, accountId) {
  const started = Date.now();
  const result = ws.connect(`${WS_URL}/?token=${encodeURIComponent(token)}`, null, (socket) => {
    socket.on('open', () => {
      wsConnectMs.add(Date.now() - started);
      wsConnects.add(1);
      socket.send(JSON.stringify({ op: 'subscribe', symbols: [SYMBOL], batch: true, compact: true, evts: true }));
      socket.send(JSON.stringify({ op: 'watch_account', accountId }));
    });
    socket.on('message', (message) => {
      try {
        const frame = JSON.parse(message);
        if (frame.t === 'position' || frame.t === 'account' || frame.t === 'order' || frame.t === 'evts') {
          wsStateMs.add(Date.now() - started);
        }
      } catch (_) {
        errors.add(1);
      }
    });
    // Keep each VU's state connection present long enough to overlap the
    // trade mutation loop without leaving orphaned sockets after the test.
    socket.setTimeout(() => socket.close(), 20_000);
  });
  if (result && result.error) errors.add(1);
}

function request(token, method, path, body, metric) {
  const started = Date.now();
  const res = http.request(method, `${BASE}${path}`, body ? JSON.stringify(body) : null, { headers: headers(token) });
  metric.add(Date.now() - started);
  const ok = check(res, { [`${method} ${path} succeeded`]: (r) => r.status >= 200 && r.status < 300 });
  errors.add(ok ? 0 : 1);
  return ok ? parse(res) : null;
}

export function setup() {
  assertSafeHost(BASE);
  assertSafeHost(WS_URL.replace(/^ws/, 'http'));
  if (!PASSWORD) throw new Error('PASSWORD must be a disposable staging-account password');
  const health = http.get(`${BASE}/v1/health`, { headers: { 'X-BT-Tenant': TENANT } });
  if (health.status !== 200) throw new Error(`staging health check failed: ${health.status}`);
}

export default function () {
  const login = String(LOGIN_BASE + __VU);
  const loginRes = http.post(
    `${BASE}/v1/auth/account-login?tenant=${encodeURIComponent(TENANT)}`,
    JSON.stringify({ login, password: PASSWORD }),
    { headers: { 'Content-Type': 'application/json', 'X-BT-Tenant': TENANT } },
  );
  const session = parse(loginRes);
  if (loginRes.status < 200 || loginRes.status >= 300 || !session.accessToken || !session.accountId) {
    errors.add(1);
    sleep(1);
    return;
  }

  openSocket(session.accessToken, session.accountId);
  const common = { accountId: session.accountId, symbol: SYMBOL, type: 'MARKET', volume: VOLUME };
  const buy = request(session.accessToken, 'POST', '/v1/orders', { ...common, side: 'BUY', clientOrderId: `scale-${__VU}-${__ITER}-buy` }, orderAckMs);
  const sell = request(session.accessToken, 'POST', '/v1/orders', { ...common, side: 'SELL', clientOrderId: `scale-${__VU}-${__ITER}-sell` }, orderAckMs);

  for (const position of [buy, sell]) {
    if (!position || !position.positionId) continue;
    request(session.accessToken, 'PATCH', `/v1/positions/${position.positionId}`, { slPrice: null, tpPrice: null }, orderAckMs);
    request(session.accessToken, 'POST', `/v1/positions/${position.positionId}/close`, {}, closeAckMs);
  }
  sleep(1 + Math.random() * 2);
}
