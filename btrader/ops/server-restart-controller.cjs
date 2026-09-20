/*
 * Windows-host control plane for the weekend-only Admin restart action.
 *
 * This is intentionally outside the trading containers: it accepts only an
 * authenticated, pre-authorized request from the gateway and can restart only
 * the named application services in the one approved Compose project. It has
 * no API to touch volumes, Postgres, Redis, Windows, MT5, or a second matcher.
 */
const { createServer } = require('node:http');
const { createHash, timingSafeEqual, randomUUID } = require('node:crypto');
const { readFileSync, appendFileSync } = require('node:fs');
const { join } = require('node:path');
const { spawn } = require('node:child_process');

const root = process.env.BURJEX_ROOT || 'C:\\Burjex-complete-project';
const envPath = join(root, 'deploy', '.env.github');
const logPath = join(root, 'deploy', 'server-restart-controller.log');
const docker = process.env.DOCKER_EXE || 'C:\\Program Files\\Docker\\Docker\\resources\\bin\\docker.exe';
const allowedServerId = 'forexten-registry-only';
const services = ['btrader-matching', 'btrader-gateway', 'btrader-ws', 'btrader-market-data', 'btrader-engine'];
const port = Number(process.env.RESTART_CONTROL_PORT || 4150);
let restarting = false;

function envValue(key) {
  const line = readFileSync(envPath, 'utf8').split(/\r?\n/).find((value) => value.startsWith(`${key}=`));
  return line ? line.slice(key.length + 1).trim() : '';
}

function log(event, detail = {}) {
  appendFileSync(logPath, `${JSON.stringify({ at: new Date().toISOString(), event, ...detail })}\r\n`);
}

function tokenMatches(given) {
  const expected = envValue('RESTART_CONTROL_TOKEN');
  if (!expected || !given) return false;
  const expectedHash = createHash('sha256').update(expected).digest();
  const givenHash = createHash('sha256').update(given).digest();
  return timingSafeEqual(expectedHash, givenHash);
}

function json(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

function scheduleRestart(requestId) {
  restarting = true;
  log('restart_scheduled', { requestId, services });
  setTimeout(() => {
    const args = ['compose', '--env-file', 'deploy\\.env.github', '-f', 'deploy\\docker-compose.github.yml', '-p', 'burjex_net', 'restart', ...services];
    const child = spawn(docker, args, { cwd: root, windowsHide: true });
    let stderr = '';
    child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
    child.on('close', (code) => {
      restarting = false;
      log(code === 0 ? 'restart_completed' : 'restart_failed', {
        requestId,
        code,
        stderr: stderr.slice(-1000),
        services,
      });
    });
    child.on('error', (error) => {
      restarting = false;
      log('restart_failed', { requestId, error: error.message, services });
    });
  }, 2_000);
}

const server = createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') return json(res, 200, { ok: true, restarting });
  if (req.method !== 'POST' || req.url !== '/restart') return json(res, 404, { error: 'not found' });
  if (!tokenMatches(req.headers['x-restart-control-token'])) return json(res, 401, { error: 'unauthorized' });

  let raw = '';
  req.on('data', (chunk) => {
    raw += chunk;
    if (raw.length > 4096) req.destroy();
  });
  req.on('end', () => {
    let body;
    try {
      body = JSON.parse(raw);
    } catch {
      return json(res, 400, { error: 'invalid JSON' });
    }
    if (restarting) return json(res, 409, { error: 'restart already in progress' });
    if (body?.serverId !== allowedServerId) return json(res, 400, { error: 'unapproved server' });
    const requestId = typeof body?.requestId === 'string' && body.requestId ? body.requestId : randomUUID();
    scheduleRestart(requestId);
    return json(res, 202, { ok: true, scheduled: true, requestId, services });
  });
});

server.listen(port, '0.0.0.0', () => log('controller_started', { port }));
