import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

const BASE = (__ENV.BASE_URL || 'https://portal.burjexprime.net').replace(/\/+$/, '');
const TENANT = __ENV.TENANT || 'demo';
const EMAIL = __ENV.EMAIL || 'naveedshehzad511@gmail.com';
const PASSWORD = __ENV.PASSWORD || 'NAaveed56@';
const ACCOUNT_LOGIN = __ENV.ACCOUNT_LOGIN || '';
const ACCOUNT_PASSWORD = __ENV.ACCOUNT_PASSWORD || '';
const SYMBOL = __ENV.SYMBOL || 'XAUUSD';
const HOLD = __ENV.HOLD || '3m';
const REFRESH_AFTER_MS = Math.floor(Number(__ENV.ACCESS_TTL_MS || 15 * 60 * 1000) * 0.75);

const errRate = new Rate('portal_errors');
const loginMs = new Trend('portal_login_ms', true);
const coldMs = new Trend('portal_cold_start_ms', true);
const pollMs = new Trend('portal_poll_ms', true);
const loginCount = new Counter('portal_logins');
const refreshCount = new Counter('portal_token_refresh');
const login429 = new Counter('portal_login_429');
const login401 = new Counter('portal_login_401');
const login502 = new Counter('portal_login_502');

let lastLoginStatus = 0;
let lastRetryAfterSec = 0;
let session = null;

export const options = {
  scenarios: {
    portal_readers: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 500 },
        { duration: HOLD, target: 500 },
        { duration: '1m', target: 0 },
      ],
      gracefulRampDown: '1m',
    },
  },
  thresholds: {
    portal_errors: ['rate<0.05'],
    portal_login_ms: ['p(95)<2000'],
    portal_cold_start_ms: ['p(95)<2500'],
    portal_poll_ms: ['p(95)<1500'],
    http_req_failed: ['rate<0.05'],
  },
};

function jsonHeaders(token) {
  const h = { 'Content-Type': 'application/json', 'X-BT-Tenant': TENANT };
  if (__ENV.LOAD_TEST_KEY) h['X-BT-Load-Test'] = __ENV.LOAD_TEST_KEY;
  if (token) h.Authorization = 'Bearer ' + token;
  return h;
}

function applyVu(value) {
  if (!value) return value;
  return String(value).split('{' + 'VU}').join(String(__VU));
}

function recordLoginStatus(res) {
  lastLoginStatus = res ? res.status : 0;
  const raw = res && res.headers ? res.headers['Retry-After'] || res.headers['retry-after'] : 0;
  const sec = Number(raw);
  lastRetryAfterSec = Number.isFinite(sec) && sec > 0 ? Math.min(sec, 90) : 0;
  if (lastLoginStatus === 429) login429.add(1);
  if (lastLoginStatus === 401) login401.add(1);
  if (lastLoginStatus === 502) login502.add(1);
}

function authRetrySleep() {
  if (lastLoginStatus === 429) return lastRetryAfterSec > 0 ? lastRetryAfterSec : 25 + Math.random() * 20;
  if (lastLoginStatus === 401) return 20 + Math.random() * 15;
  if (lastLoginStatus === 502) return 5 + Math.random() * 5;
  return 2 + Math.random();
}

function parseBody(res) {
  try {
    return res.json();
  } catch (e) {
    return {};
  }
}

function req(method, url, headers, name) {
  return { method: method, url: url, params: { headers: headers, tags: { name: name } } };
}

function allOk(res) {
  return check(res, {
    'status 200': function (r) {
      return r && r.status === 200;
    },
  });
}

function batchOk(out) {
  let ok = true;
  for (let i = 0; i < out.length; i++) ok = allOk(out[i]) && ok;
  return ok;
}

export function setup() {
  const health = http.get(BASE + '/v1/health', { headers: jsonHeaders(''), tags: { name: 'health' } });
  check(health, {
    'setup health 200': function (r) {
      return r.status === 200;
    },
  });
  return { maxVus: 500 };
}

function loginThisVu() {
  const t0 = Date.now();
  const qs = '?tenant=' + encodeURIComponent(TENANT);
  const acct = applyVu(ACCOUNT_LOGIN);
  let res;
  if (acct && ACCOUNT_PASSWORD) {
    res = http.post(BASE + '/v1/auth/account-login' + qs, JSON.stringify({ login: acct, password: ACCOUNT_PASSWORD }), {
      headers: jsonHeaders(''),
      tags: { name: 'auth_login' },
    });
  } else if (applyVu(EMAIL) && PASSWORD) {
    res = http.post(BASE + '/v1/auth/login' + qs, JSON.stringify({ email: applyVu(EMAIL), password: PASSWORD }), {
      headers: jsonHeaders(''),
      tags: { name: 'auth_login' },
    });
  } else {
    errRate.add(1);
    lastLoginStatus = 0;
    return null;
  }
  recordLoginStatus(res);
  loginMs.add(Date.now() - t0);
  const ok = check(res, {
    'vu login 2xx': function (r) {
      return r.status >= 200 && r.status < 300;
    },
  });
  if (!ok) {
    errRate.add(1);
    return null;
  }
  errRate.add(0);
  loginCount.add(1);
  const body = parseBody(res);
  const token = body.accessToken;
  if (!token) {
    errRate.add(1);
    return null;
  }
  let accountId = body.accountId || null;
  const me = http.get(BASE + '/v1/accounts/me', { headers: jsonHeaders(token), tags: { name: 'accounts_me' } });
  if (
    check(me, {
      'login me 200': function (r) {
        return r.status === 200;
      },
    })
  ) {
    const list = parseBody(me);
    if (!accountId && list && list.length) accountId = list[0].id;
  }
  return { token: token, refreshToken: body.refreshToken, accountId: accountId, issuedAt: Date.now() };
}

function refreshIfNeeded() {
  if (!session || !session.refreshToken) return;
  if (Date.now() - session.issuedAt < REFRESH_AFTER_MS) return;
  const res = http.post(BASE + '/v1/auth/refresh', JSON.stringify({ refreshToken: session.refreshToken }), {
    headers: jsonHeaders(''),
    tags: { name: 'auth_refresh' },
  });
  const ok = check(res, {
    'refresh 2xx': function (r) {
      return r.status >= 200 && r.status < 300;
    },
  });
  if (!ok) {
    errRate.add(1);
    session = loginThisVu();
    return;
  }
  errRate.add(0);
  refreshCount.add(1);
  const body = parseBody(res);
  if (body.accessToken) session.token = body.accessToken;
  if (body.refreshToken) session.refreshToken = body.refreshToken;
  session.issuedAt = Date.now();
}

function coldStart(headers) {
  const t0 = Date.now();
  const batch = [
    req('GET', BASE + '/v1/public/branding', jsonHeaders(''), 'branding'),
    req('GET', BASE + '/v1/accounts/me', headers, 'accounts_me'),
    req('GET', BASE + '/v1/symbols?enabled=true', headers, 'symbols'),
    req('GET', BASE + '/v1/market/quotes', headers, 'quotes'),
    req('GET', BASE + '/v1/market/clock', headers, 'clock'),
  ];
  if (session.accountId) {
    batch.push(req('GET', BASE + '/v1/orders?accountId=' + session.accountId, headers, 'orders'));
    batch.push(req('GET', BASE + '/v1/positions?accountId=' + session.accountId + '&status=OPEN', headers, 'positions'));
  }
  const out = http.batch(batch);
  coldMs.add(Date.now() - t0);
  let ok = batchOk(out);
  const candles = http.get(BASE + '/v1/market/candles?symbol=' + encodeURIComponent(SYMBOL) + '&tf=5m&limit=50', {
    headers: headers,
    tags: { name: 'candles' },
  });
  errRate.add(allOk(candles) && ok ? 0 : 1);
}

function poll(headers) {
  const t0 = Date.now();
  const batch = [req('GET', BASE + '/v1/accounts/me', headers, 'accounts_me')];
  if (session.accountId) {
    batch.push(req('GET', BASE + '/v1/positions?accountId=' + session.accountId + '&status=OPEN', headers, 'positions'));
    batch.push(req('GET', BASE + '/v1/orders?accountId=' + session.accountId, headers, 'orders'));
  }
  const roll = Math.random();
  if (roll < 0.25) batch.push(req('GET', BASE + '/v1/market/quotes', headers, 'quotes'));
  if (roll < 0.12) {
    batch.push(
      req('GET', BASE + '/v1/market/candles?symbol=' + encodeURIComponent(SYMBOL) + '&tf=5m&limit=50', headers, 'candles'),
    );
  }
  if (roll < 0.08 && session.accountId) {
    batch.push(req('GET', BASE + '/v1/history/deals?accountId=' + session.accountId, headers, 'deals'));
  }
  pollMs.add(Date.now() - t0);
  errRate.add(batchOk(http.batch(batch)) ? 0 : 1);
}

export default function () {
  if (!session) {
    session = loginThisVu();
    if (!session) {
      sleep(authRetrySleep());
      return;
    }
    coldStart(jsonHeaders(session.token));
    sleep(3 + Math.random() * 4);
    return;
  }
  refreshIfNeeded();
  if (!session) {
    sleep(2);
    return;
  }
  poll(jsonHeaders(session.token));
  sleep(8 + Math.random() * 10);
}

export function teardown() {
  console.log('portal_readonly 500 VUs hold=' + HOLD);
}
