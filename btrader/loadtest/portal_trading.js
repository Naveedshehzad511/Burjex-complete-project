import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

const BASE = (__ENV.BASE_URL || 'https://portal.burjexprime.net').replace(/\/+$/, '');
const TENANT = __ENV.TENANT || 'demo';
const PASSWORD = __ENV.PASSWORD || 'NAaveed56@';
const LOGIN = String(Number(__ENV.LOGIN_BASE || '610000') + __VU);
const SYMBOL = (__ENV.SYMBOL || 'XAUUSD').toUpperCase();
const VOL = Number(__ENV.VOLUME || 0.01);
const HOLD = __ENV.HOLD || '4m';
const BUDGET = Number(__ENV.EXEC_DELAY_MS || 200) + 2000;

const errRate = new Rate('trade_errors');
const delayOver = new Rate('delay_overrun');
const priceBad = new Rate('fill_price_bad');
const loginMs = new Trend('trade_login_ms', true);
const marketMs = new Trend('market_open_ms', true);
const closeMs = new Trend('trade_close_ms', true);
const modifyMs = new Trend('trade_modify_ms', true);
const opens = new Counter('trade_market_ok');
const closes = new Counter('trade_close_ok');
let session = null;

export const options = {
  scenarios: { traders: { executor: 'ramping-vus', startVUs: 0, stages: [{ duration: '2m', target: 1000 }, { duration: HOLD, target: 1000 }, { duration: '1m', target: 0 }], gracefulRampDown: '1m' } },
  thresholds: { trade_errors: ['rate<0.15'], delay_overrun: ['rate<0.10'], fill_price_bad: ['rate<0.05'], market_open_ms: ['p(95)<2200'], trade_close_ms: ['p(95)<3000'], http_req_failed: ['rate<0.15'] },
};

function hdr(token) {
  const h = { 'Content-Type': 'application/json', 'X-BT-Tenant': TENANT };
  if (token) h.Authorization = 'Bearer ' + token;
  return h;
}
function js(res) { try { return res.json(); } catch (e) { return {}; } }
function ok(res) { return res && res.status >= 200 && res.status < 300; }
function cid() { return 'k6-' + __VU + '-' + __ITER + '-' + Date.now(); }

export function setup() {
  check(http.get(BASE + '/v1/health', { headers: hdr(''), tags: { name: 'health' } }), { 'health 200': function (r) { return r.status === 200; } });
  return {};
}

function loginVu() {
  const t0 = Date.now();
  const qs = '?tenant=' + encodeURIComponent(TENANT);
  const r = http.post(BASE + '/v1/auth/account-login' + qs, JSON.stringify({ login: LOGIN, password: PASSWORD }), { headers: hdr(''), tags: { name: 'auth_login' } });
  loginMs.add(Date.now() - t0);
  const b = js(r);
  if (r && r.status === 429) { errRate.add(1); sleep(8); return null; }
  if (!ok(r) || !b.accessToken || !b.accountId) { errRate.add(1); sleep(5); return null; }
  errRate.add(0);
  return { token: b.accessToken, accountId: b.accountId };
}

function quote(h) {
  const rows = js(http.get(BASE + '/v1/market/quotes', { headers: h, tags: { name: 'quotes' } }));
  if (!Array.isArray(rows)) return null;
  for (let i = 0; i < rows.length; i++) if (rows[i] && String(rows[i].symbol).toUpperCase() === SYMBOL) return rows[i];
  return null;
}

function order(h, payload, tag) {
  return http.post(BASE + '/v1/orders', JSON.stringify(payload), { headers: h, tags: { name: tag } });
}

function closePos(h, id) {
  const t0 = Date.now();
  const r = http.post(BASE + '/v1/positions/' + id + '/close', '{}', { headers: h, tags: { name: 'trade_close' } });
  closeMs.add(Date.now() - t0);
  if (ok(r)) closes.add(1);
  errRate.add(ok(r) ? 0 : 1);
}

function market(h, side, q) {
  const t0 = Date.now();
  const r = order(h, { accountId: session.accountId, symbol: SYMBOL, side: side, type: 'MARKET', volume: VOL, clientOrderId: cid() }, 'order_market');
  const ms = Date.now() - t0;
  marketMs.add(ms);
  delayOver.add(ms > BUDGET ? 1 : 0);
  const b = js(r);
  if (!check(r, { filled: function (x) { return ok(x) && b.accepted === true && b.status === 'FILLED'; } })) { errRate.add(1); return; }
  errRate.add(0);
  opens.add(1);
  const fill = Number(b.fillPrice);
  const exp = side === 'BUY' ? Number(q.ask) : Number(q.bid);
  if (Number.isFinite(fill) && Number.isFinite(exp)) priceBad.add(Math.abs(fill - exp) > 5 ? 1 : 0);
  if (b.positionId) closePos(h, b.positionId);
}

function limitOrSltp(h, q, sltpMode) {
  if (sltpMode) {
    const r = order(h, { accountId: session.accountId, symbol: SYMBOL, side: 'BUY', type: 'MARKET', volume: VOL, slPrice: Number((Number(q.bid) - 20).toFixed(2)), tpPrice: Number((Number(q.ask) + 20).toFixed(2)), clientOrderId: cid() }, 'order_market_sltp');
    const b = js(r);
    if (!ok(r) || !b.positionId) { errRate.add(1); return; }
    errRate.add(0);
    opens.add(1);
    const t0 = Date.now();
    const m = http.patch(BASE + '/v1/positions/' + b.positionId, JSON.stringify({ slPrice: Number((Number(q.bid) - 15).toFixed(2)), tpPrice: Number((Number(q.ask) + 15).toFixed(2)) }), { headers: h, tags: { name: 'position_modify' } });
    modifyMs.add(Date.now() - t0);
    errRate.add(ok(m) ? 0 : 1);
    closePos(h, b.positionId);
    return;
  }
  const px = Number((Number(q.bid) - 50).toFixed(2));
  const r = order(h, { accountId: session.accountId, symbol: SYMBOL, side: 'BUY', type: 'BUY_LIMIT', volume: VOL, price: px, clientOrderId: cid() }, 'order_limit');
  const b = js(r);
  const good = ok(r) && (b.status === 'PENDING' || b.accepted === true) && (b.status !== 'FILLED' || Number(b.fillPrice) < px + 0.02);
  if (!check(r, { limit: function () { return good; } })) { errRate.add(1); return; }
  errRate.add(0);
  const id = b.orderId || b.id;
  if (b.status === 'PENDING' && id) {
    const t0 = Date.now();
    const m = http.patch(BASE + '/v1/orders/' + id, JSON.stringify({ price: Number((px - 1).toFixed(2)) }), { headers: h, tags: { name: 'order_modify' } });
    modifyMs.add(Date.now() - t0);
    errRate.add(ok(m) ? 0 : 1);
    http.del(BASE + '/v1/orders/' + id, null, { headers: h, tags: { name: 'order_cancel' } });
  } else if (b.positionId) closePos(h, b.positionId);
}

export default function () {
  if (!session) {
    session = loginVu();
    if (!session) return;
    sleep((__VU % 40) * 0.25);
    return;
  }
  const h = hdr(session.token);
  const q = quote(h);
  if (!q || !q.bid || !q.ask) { errRate.add(1); sleep(2); return; }
  const lane = __ITER % 4;
  if (lane === 0) market(h, 'BUY', q);
  else if (lane === 1) market(h, 'SELL', q);
  else limitOrSltp(h, q, lane === 3);
  sleep(20 + (__VU % 20) + Math.random() * 10);
}

export function teardown() {
  console.log('portal_trading 1000vu demo logins 610001+ XAUUSD');
}
