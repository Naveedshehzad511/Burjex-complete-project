import assert from 'node:assert/strict';
import test from 'node:test';
import { deriveServerHealth, type HealthSettings } from './server-health';

const settings: HealthSettings = {
  cpuWarningPercent: 70,
  cpuCriticalPercent: 85,
  ramWarningPercent: 70,
  ramCriticalPercent: 85,
  diskWarningPercent: 70,
  diskCriticalPercent: 85,
  heartbeatWarningSeconds: 90,
  heartbeatOfflineSeconds: 180,
};

const now = new Date('2026-09-20T00:10:00.000Z');
const server = { enabled: true, readiness: 'READY' };

test('a stale heartbeat is warning before offline grace', () => {
  const health = deriveServerHealth(
    { ...server, lastHeartbeatAt: new Date('2026-09-20T00:08:20.000Z') },
    null,
    settings,
    now,
  );
  assert.equal(health.status, 'WARNING');
  assert.equal(health.online, true);
});

test('stale heartbeat becomes offline only after offline grace', () => {
  const health = deriveServerHealth(
    { ...server, lastHeartbeatAt: new Date('2026-09-20T00:06:59.000Z') },
    null,
    settings,
    now,
  );
  assert.equal(health.status, 'OFFLINE');
  assert.equal(health.online, false);
});

test('resource thresholds and a failed service surface actionable health', () => {
  const health = deriveServerHealth(
    { ...server, lastHeartbeatAt: new Date('2026-09-20T00:09:55.000Z') },
    {
      receivedAt: new Date('2026-09-20T00:09:55.000Z'),
      cpuPercent: 88,
      ramPercent: 20,
      diskPercent: 20,
      services: { gateway: 'DOWN' },
    },
    settings,
    now,
  );
  assert.equal(health.status, 'CRITICAL');
  assert.match(health.problems.join(' '), /CPU/);
  assert.match(health.problems.join(' '), /gateway service reports down/);
});

test('maintenance does not pretend the host is healthy', () => {
  const health = deriveServerHealth(
    { enabled: true, readiness: 'MAINTENANCE', lastHeartbeatAt: null },
    null,
    settings,
    now,
  );
  assert.equal(health.status, 'MAINTENANCE');
  assert.equal(health.online, false);
});
