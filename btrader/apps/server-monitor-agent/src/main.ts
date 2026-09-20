import { cpus, freemem, homedir, totalmem, uptime } from 'node:os';
import { statfs } from 'node:fs/promises';

const apiBase = required('SERVER_MONITOR_API_URL').replace(/\/+$/, '');
const serverId = required('SERVER_MONITOR_SERVER_ID');
const token = required('SERVER_MONITOR_AGENT_TOKEN');
const intervalMs = positiveInt(process.env.SERVER_MONITOR_INTERVAL_MS, 30_000);
const version = process.env.SERVER_MONITOR_APP_VERSION?.slice(0, 120) ?? null;
const serviceUrls = parseServiceUrls(process.env.SERVER_MONITOR_SERVICE_URLS_JSON);

let previousCpu = cpuTimes();

function required(name: string) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function positiveInt(raw: string | undefined, fallback: number) {
  const value = Number(raw);
  return Number.isInteger(value) && value >= 10_000 && value <= 3_600_000 ? value : fallback;
}

function parseServiceUrls(raw: string | undefined): Record<string, string> {
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {};
    return Object.fromEntries(
      Object.entries(parsed).filter(([key, value]) =>
        ['engine', 'marketData', 'ws', 'postgres', 'redis', 'crm'].includes(key) &&
        typeof value === 'string' &&
        /^https?:\/\//.test(value),
      ),
    ) as Record<string, string>;
  } catch {
    throw new Error('SERVER_MONITOR_SERVICE_URLS_JSON must be a JSON object of HTTP health URLs');
  }
}

function cpuTimes() {
  return cpus().reduce(
    (total, cpu) => {
      for (const [key, value] of Object.entries(cpu.times)) total[key] = (total[key] ?? 0) + value;
      return total;
    },
    {} as Record<string, number>,
  );
}

function cpuPercent() {
  const next = cpuTimes();
  const previousTotal = Object.values(previousCpu).reduce((sum, value) => sum + value, 0);
  const nextTotal = Object.values(next).reduce((sum, value) => sum + value, 0);
  const idle = (next.idle ?? 0) - (previousCpu.idle ?? 0);
  previousCpu = next;
  return nextTotal > previousTotal ? Number((((nextTotal - previousTotal - idle) / (nextTotal - previousTotal)) * 100).toFixed(1)) : 0;
}

async function serviceHealth(url: string): Promise<'UP' | 'DOWN'> {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(4_000) });
    return response.ok ? 'UP' : 'DOWN';
  } catch {
    return 'DOWN';
  }
}

async function heartbeat() {
  const started = Date.now();
  const fs = await statfs(homedir());
  const diskPercent = fs.blocks > 0 ? Number((((fs.blocks - fs.bfree) / fs.blocks) * 100).toFixed(1)) : null;
  const services = Object.fromEntries(await Promise.all(
    Object.entries(serviceUrls).map(async ([name, url]) => [name, await serviceHealth(url)]),
  ));
  const response = await fetch(`${apiBase}/v1/monitoring/heartbeat`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-server-agent-token': token },
    body: JSON.stringify({
      serverId,
      reportedAt: new Date().toISOString(),
      cpuPercent: cpuPercent(),
      ramPercent: Number((((totalmem() - freemem()) / totalmem()) * 100).toFixed(1)),
      diskPercent,
      uptimeSeconds: Math.floor(uptime()),
      appVersion: version,
      network: { rttMs: Date.now() - started },
      services,
    }),
    signal: AbortSignal.timeout(8_000),
  });
  if (!response.ok) throw new Error(`heartbeat rejected: HTTP ${response.status}`);
}

async function run() {
  try {
    await heartbeat();
  } catch (error) {
    // The agent is deliberately decoupled from the engine. A failed report must
    // never affect matching, gateway, market data, or service health endpoints.
    console.error('[server-monitor-agent] heartbeat failed:', error instanceof Error ? error.message : error);
  }
}

void run();
setInterval(() => void run(), intervalMs);
