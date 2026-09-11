/**
 * k6 Grafana Cloud — public portal HTTP, READ-ONLY.
 *
 * Compatible with Grafana Cloud k6 editor/runtime: no open(), no SharedArray,
 * no local users.json. Credentials come from Cloud environment variables.
 *
 * Auth: each VU logs in once (VU-local session). Do not share one setup() token.
 * EMAIL/PASSWORD are required for a real run. Optional "{VU}" in EMAIL or
 * ACCOUNT_LOGIN becomes the VU number (user1, user2, ...).
 *
 * Access JWT ~15m: POST /v1/auth/refresh only. Never logout.
 *
 * Never called: POST /v1/orders, order close/modify, financial, CRM, admin,
 * demo-register, logout.
 *
 * Grafana Cloud variables:
 *   EMAIL, PASSWORD          defaulted in this script; env overrides them
 *   BASE_URL                default https://portal.burjexprime.net
 *   TENANT                  default demo
 *   ACCOUNT_LOGIN, ACCOUNT_PASSWORD   optional instead of email
 *   SYMBOL                  default EURUSD
 *   HOLD                    hold at 500 VUs (default 3m)
 *   LOAD_TEST_KEY           optional; must match gateway LOAD_TEST_KEY
 *
 * 429/401 are still failures (thresholds unchanged). After a 429 the VU waits
 * Retry-After (or ~30s) instead of retrying every 2s, which previously turned
 * one throttle window into tens of thousands of extra 429s.
 *
 * Load: ramp to 500 VUs, hold, then ramp down.
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

const BASE = (__ENV.BASE_URL || 'https://portal.burjexprime.net').replace(/\/+$/, '');
const TENANT = __ENV.TENANT || 'demo';
const EMAIL = __ENV.EMAIL || 'naveedshehzad511@gmail.com';
const PASSWORD = __ENV.PASSWORD || 'NAaveed56@';
const ACCOUNT_LOGIN = __ENV.ACCOUNT_LOGIN || '';
const ACCOUNT_PASSWORD = __ENV.ACCOUNT_PASSWORD || '';
const SYMBOL = __ENV.SYMBOL || 'EURUSD';
const HOLD = __ENV.HOLD || '3m';
const ACCESS_TTL_MS = Number(__ENV.ACCESS_TTL_MS || 15 * 60 * 1000);
const REFRESH_AFTER_MS = Math.floor(ACCESS_TTL_MS * 0.75);

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

function ramp(duration, target) {
  return { duration: duration, target: target };
}

export const options = {
  scenarios: {
    portal_readers: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        ramp('1m', 500),
        ramp(HOLD, 500),
        ramp('1m', 0),
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
  const h = {
    'Content-Type': 'application/json',
    'X-BT-Tenant': TENANT,
  };
  if (__ENV.LOAD_TEST_KEY) {
    h['X-BT-Load-Test'] = __ENV.LOAD_TEST_KEY;
  }
  if (token) {
    h.Authorization = 'Bearer ' + token;
  }
  return h;
}

function headerRetryAfterSec(res) {
  if (!res || !res.headers) {
    return 0;
  }
  const raw = res.headers['Retry-After'] || res.headers['Retry-after'] || res.headers['retry-after'];
  const sec = Number(raw);
  if (Number.isFinite(sec) && sec > 0) {
    return Math.min(sec, 90);
  }
  return 0;
}

function recordLoginStatus(res) {
  lastLoginStatus = res ? res.status : 0;
  lastRetryAfterSec = headerRetryAfterSec(res);
  if (lastLoginStatus === 429) login429.add(1);
  if (lastLoginStatus === 401) login401.add(1);
  if (lastLoginStatus === 502) login502.add(1);
}

function authRetrySleep() {
  if (lastLoginStatus === 429) {
    return lastRetryAfterSec > 0 ? lastRetryAfterSec : 25 + Math.random() * 20;
  }
  if (lastLoginStatus === 401) {
    return 20 + Math.random() * 15;
  }
  if (lastLoginStatus === 502) {
    return 5 + Math.random() * 5;
  }
  return 2 + Math.random();
}

function applyVu(value) {
  if (!value) {
    return value;
  }
  return String(value).split('{VU}').join(String(__VU));
}

function vuEmail() {
  return applyVu(EMAIL);
}

function vuAccountLogin() {
  return applyVu(ACCOUNT_LOGIN);
}

export function setup() {
  const health = http.get(BASE + '/v1/health', {
    headers: jsonHeaders(''),
    tags: { name: 'health' },
  });
  check(health, { 'setup health 200': function (r) { return r.status === 200; } });
  return { maxVus: 500 };
}

let session = null;

function parseBody(res) {
  try {
    return res.json();
  } catch (e) {
    return {};
  }
}

function loginThisVu() {
  const t0 = Date.now();
  let res;
  const tenantQs = '?tenant=' + encodeURIComponent(TENANT);
  const acct = vuAccountLogin();
  if (acct && ACCOUNT_PASSWORD) {
    res = http.post(
      BASE + '/v1/auth/account-login' + tenantQs,
      JSON.stringify({ login: acct, password: ACCOUNT_PASSWORD }),
      { headers: jsonHeaders(''), tags: { name: 'auth_login' } },
    );
  } else if (vuEmail() && PASSWORD) {
    res = http.post(
      BASE + '/v1/auth/login' + tenantQs,
      JSON.stringify({ email: vuEmail(), password: PASSWORD }),
      { headers: jsonHeaders(''), tags: { name: 'auth_login' } },
    );
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
  const me = http.get(BASE + '/v1/accounts/me', {
    headers: jsonHeaders(token),
    tags: { name: 'accounts_me' },
  });
  if (check(me, { 'login me 200': function (r) { return r.status === 200; } })) {
    const list = parseBody(me);
    if (!accountId && list && list.length) {
      accountId = list[0].id;
    }
  }

  return {
    token: token,
    refreshToken: body.refreshToken,
    accountId: accountId,
    issuedAt: Date.now(),
  };
}

function refreshIfNeeded() {
  if (!session || !session.refreshToken) {
    return;
  }
  if (Date.now() - session.issuedAt < REFRESH_AFTER_MS) {
    return;
  }
  const res = http.post(
    BASE + '/v1/auth/refresh',
    JSON.stringify({ refreshToken: session.refreshToken }),
    { headers: jsonHeaders(''), tags: { name: 'auth_refresh' } },
  );
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

function req(method, url, headers, name) {
  return {
    method: method,
    url: url,
    params: { headers: headers, tags: { name: name } },
  };
}

function allOk(res) {
  return check(res, {
    'status 200': function (r) {
      return r && r.status === 200;
    },
  });
}

function coldStart(headers) {
  const t0 = Date.now();
  const batch = [];
  batch.push(req('GET', BASE + '/v1/public/branding', jsonHeaders(''), 'branding'));
  batch.push(req('GET', BASE + '/v1/accounts/me', headers, 'accounts_me'));
  batch.push(req('GET', BASE + '/v1/symbols?enabled=true', headers, 'symbols'));
  batch.push(req('GET', BASE + '/v1/market/quotes', headers, 'quotes'));
  batch.push(req('GET', BASE + '/v1/market/clock', headers, 'clock'));
  if (session.accountId) {
    batch.push(req('GET', BASE + '/v1/orders?accountId=' + session.accountId, headers, 'orders'));
    batch.push(
      req('GET', BASE + '/v1/positions?accountId=' + session.accountId + '&status=OPEN', headers, 'positions'),
    );
  }
  const out = http.batch(batch);
  coldMs.add(Date.now() - t0);

  let ok = true;
  let i = 0;
  ok = allOk(out[i]) && ok;
  i += 1;
  ok = allOk(out[i]) && ok;
  i += 1;
  ok = allOk(out[i]) && ok;
  i += 1;
  ok = allOk(out[i]) && ok;
  i += 1;
  ok = allOk(out[i]) && ok;
  i += 1;
  if (session.accountId) {
    ok = allOk(out[i]) && ok;
    i += 1;
    ok = allOk(out[i]) && ok;
  }

  const candles = http.get(
    BASE + '/v1/market/candles?symbol=' + encodeURIComponent(SYMBOL) + '&tf=5m&limit=50',
    { headers: headers, tags: { name: 'candles' } },
  );
  ok = allOk(candles) && ok;
  errRate.add(ok ? 0 : 1);
}

function poll(headers) {
  const t0 = Date.now();
  const batch = [];
  batch.push(req('GET', BASE + '/v1/accounts/me', headers, 'accounts_me'));
  if (session.accountId) {
    batch.push(
      req('GET', BASE + '/v1/positions?accountId=' + session.accountId + '&status=OPEN', headers, 'positions'),
    );
    batch.push(req('GET', BASE + '/v1/orders?accountId=' + session.accountId, headers, 'orders'));
  }
  const roll = Math.random();
  if (roll < 0.25) {
    batch.push(req('GET', BASE + '/v1/market/quotes', headers, 'quotes'));
  }
  if (roll < 0.12) {
    batch.push(
      req(
        'GET',
        BASE + '/v1/market/candles?symbol=' + encodeURIComponent(SYMBOL) + '&tf=5m&limit=50',
        headers,
        'candles',
      ),
    );
  }
  if (roll < 0.08 && session.accountId) {
    batch.push(req('GET', BASE + '/v1/history/deals?accountId=' + session.accountId, headers, 'deals'));
  }
  const out = http.batch(batch);
  pollMs.add(Date.now() - t0);

  let ok = true;
  for (let i = 0; i < out.length; i++) {
    ok = check(out[i], {
      'poll 200': function (r) {
        return r && r.status === 200;
      },
    }) && ok;
  }
  errRate.add(ok ? 0 : 1);
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
  console.log('portal_readonly teardown 500 VUs hold=' + HOLD);
}
