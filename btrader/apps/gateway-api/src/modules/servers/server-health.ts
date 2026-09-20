export type ServerHealthStatus =
  | 'HEALTHY'
  | 'WARNING'
  | 'DEGRADED'
  | 'CRITICAL'
  | 'OFFLINE'
  | 'MAINTENANCE';

export interface HealthSettings {
  cpuWarningPercent: number;
  cpuCriticalPercent: number;
  ramWarningPercent: number;
  ramCriticalPercent: number;
  diskWarningPercent: number;
  diskCriticalPercent: number;
  heartbeatWarningSeconds: number;
  heartbeatOfflineSeconds: number;
}

export interface HeartbeatSnapshot {
  receivedAt: Date;
  cpuPercent: number | null;
  ramPercent: number | null;
  diskPercent: number | null;
  services: unknown;
}

export interface ServerHealthInput {
  enabled: boolean;
  readiness: string;
  lastHeartbeatAt: Date | null;
}

export interface ServerHealth {
  status: ServerHealthStatus;
  online: boolean;
  heartbeatAgeSeconds: number | null;
  problems: string[];
}

const serviceEntries = (services: unknown): Array<[string, unknown]> =>
  services && typeof services === 'object' && !Array.isArray(services)
    ? Object.entries(services as Record<string, unknown>)
    : [];

const serviceIsDown = (value: unknown) =>
  value === false ||
  value === 'DOWN' ||
  value === 'OFFLINE' ||
  (value && typeof value === 'object' && (value as { ok?: unknown }).ok === false);

/**
 * Pure status derivation shared by list/detail endpoints. A single missed
 * heartbeat is never OFFLINE: WARNING and OFFLINE each have their own grace.
 */
export function deriveServerHealth(
  server: ServerHealthInput,
  latest: HeartbeatSnapshot | null,
  settings: HealthSettings,
  now = new Date(),
): ServerHealth {
  if (server.readiness === 'MAINTENANCE') {
    return { status: 'MAINTENANCE', online: false, heartbeatAgeSeconds: null, problems: ['Maintenance mode is enabled.'] };
  }
  if (!server.enabled) {
    return { status: 'OFFLINE', online: false, heartbeatAgeSeconds: null, problems: ['Monitoring is disabled for this server.'] };
  }
  const beatAt = server.lastHeartbeatAt ?? latest?.receivedAt ?? null;
  if (!beatAt) {
    return { status: 'OFFLINE', online: false, heartbeatAgeSeconds: null, problems: ['No heartbeat has been received.'] };
  }
  const age = Math.max(0, Math.floor((now.getTime() - beatAt.getTime()) / 1000));
  if (age >= settings.heartbeatOfflineSeconds) {
    return { status: 'OFFLINE', online: false, heartbeatAgeSeconds: age, problems: [`Heartbeat overdue by ${age}s.`] };
  }

  const problems: string[] = [];
  let status: ServerHealthStatus = 'HEALTHY';
  const applyMetric = (name: string, value: number | null, warning: number, critical: number) => {
    if (value == null) return;
    if (value >= critical) {
      status = 'CRITICAL';
      problems.push(`${name} is ${value.toFixed(1)}% (critical threshold ${critical}%).`);
    } else if (value >= warning && status !== 'CRITICAL') {
      status = 'WARNING';
      problems.push(`${name} is ${value.toFixed(1)}% (warning threshold ${warning}%).`);
    }
  };
  applyMetric('CPU', latest?.cpuPercent ?? null, settings.cpuWarningPercent, settings.cpuCriticalPercent);
  applyMetric('RAM', latest?.ramPercent ?? null, settings.ramWarningPercent, settings.ramCriticalPercent);
  applyMetric('Disk', latest?.diskPercent ?? null, settings.diskWarningPercent, settings.diskCriticalPercent);

  for (const [name, value] of serviceEntries(latest?.services)) {
    if (serviceIsDown(value)) {
      if ((status as ServerHealthStatus) !== 'CRITICAL') status = 'DEGRADED';
      problems.push(`${name} service reports down.`);
    }
  }
  if (age >= settings.heartbeatWarningSeconds && status === 'HEALTHY') {
    status = 'WARNING';
    problems.push(`Heartbeat is stale (${age}s); offline grace is ${settings.heartbeatOfflineSeconds}s.`);
  }
  return { status, online: true, heartbeatAgeSeconds: age, problems };
}
