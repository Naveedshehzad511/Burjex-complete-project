/**
 * k6 load test — concurrent market open/close against B-Trader gateway.
 *
 * This is the Node-stack substitute for the checklist "K6 / Locust" item.
 * It does NOT prove 15k production capacity by itself — run against a sized
 * staging stack and raise VUs until p95/errors break your SLA.
 *
 * Usage:
 *   k6 run -e BASE_URL=https://api.burjexprime.net -e TOKEN=... -e ACCOUNT_ID=... \
 *          -e SYMBOL=EURUSD btrader/loadtest/concurrent_orders.js
 *
 * Env:
 *   BASE_URL      gateway origin (no trailing slash)
 *   TOKEN         Bearer access JWT
 *   ACCOUNT_ID    trading account id
 *   SYMBOL        default EURUSD
 *   VOLUME        default 0.01
 *   VUS           virtual users (default 100) — climb toward 15k only on fat hardware
 *   DURATION      e.g. 2m
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'http://127.0.0.1:6100';
const TOKEN = __ENV.TOKEN || '';
const ACCOUNT_ID = __ENV.ACCOUNT_ID || '';
const SYMBOL = __ENV.SYMBOL || 'EURUSD';
const VOLUME = Number(__ENV.VOLUME || 0.01);
const VUS = Number(__ENV.VUS || 100);
const DURATION = __ENV.DURATION || '1m';

const errRate = new Rate('trade_errors');
const openMs = new Trend('order_open_ms', true);
const closeMs = new Trend('order_close_ms', true);

export const options = {
  scenarios: {
    traders: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
    },
  },
  thresholds: {
    trade_errors: ['rate<0.01'],
    order_open_ms: ['p(95)<500'],
    order_close_ms: ['p(95)<500'],
    http_req_failed: ['rate<0.01'],
  },
};

function headers() {
  return {
    Authorization: `Bearer ${TOKEN}`,
    'Content-Type': 'application/json',
  };
}

export default function () {
  if (!TOKEN || !ACCOUNT_ID) {
    errRate.add(1);
    return;
  }

  const openPayload = JSON.stringify({
    accountId: ACCOUNT_ID,
    symbol: SYMBOL,
    side: 'BUY',
    type: 'MARKET',
    volume: VOLUME,
    clientOrderId: `k6-${__VU}-${__ITER}-${Date.now()}`,
  });

  const t0 = Date.now();
  const openRes = http.post(`${BASE}/v1/orders`, openPayload, { headers: headers() });
  openMs.add(Date.now() - t0);
  const openOk = check(openRes, {
    'open status 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  if (!openOk) {
    errRate.add(1);
    sleep(0.2);
    return;
  }
  errRate.add(0);

  let positionId = null;
  try {
    const body = openRes.json();
    positionId = body.positionId || (body.data && body.data.positionId);
  } catch (_) {
    /* ignore */
  }

  if (positionId) {
    const t1 = Date.now();
    const closeRes = http.post(
      `${BASE}/v1/positions/${positionId}/close`,
      JSON.stringify({}),
      { headers: headers() },
    );
    closeMs.add(Date.now() - t1);
    const closeOk = check(closeRes, {
      'close status 2xx': (r) => r.status >= 200 && r.status < 300,
    });
    errRate.add(closeOk ? 0 : 1);
  }

  sleep(0.05 + Math.random() * 0.1);
}
