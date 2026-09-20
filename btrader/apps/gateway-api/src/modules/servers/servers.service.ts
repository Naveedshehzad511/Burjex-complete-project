import { BadRequestException, ConflictException, Injectable, NotFoundException, UnauthorizedException } from '@nestjs/common';
import { createHash, timingSafeEqual } from 'crypto';
import { prisma } from '@btrader/db';
import { AuditService } from '../audit/audit.service';
import { deriveServerHealth, type HealthSettings } from './server-health';

const ROLES = ['PRIMARY', 'STANDBY'] as const;
const READINESS = ['NOT_READY', 'ONBOARDING', 'READY', 'ACTIVE', 'STANDBY', 'MAINTENANCE', 'ERROR'] as const;
const SERVICES = ['engine', 'marketData', 'ws', 'postgres', 'redis', 'crm'] as const;
type ServerRole = (typeof ROLES)[number];
type Readiness = (typeof READINESS)[number];

const numberInRange = (value: unknown, min = 0, max = 100): number | null => {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= min && parsed <= max ? parsed : null;
};

const cleanServices = (input: unknown): Record<string, boolean | string> | null => {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const out: Record<string, boolean | string> = {};
  for (const key of SERVICES) {
    const value = (input as Record<string, unknown>)[key];
    if (typeof value === 'boolean') out[key] = value;
    if (typeof value === 'string' && ['UP', 'DOWN', 'UNKNOWN'].includes(value.toUpperCase())) {
      out[key] = value.toUpperCase();
    }
  }
  return Object.keys(out).length ? out : null;
};

const cleanNetwork = (input: unknown): { rttMs?: number } | null => {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const rttMs = numberInRange((input as Record<string, unknown>).rttMs, 0, 60_000);
  return rttMs == null ? null : { rttMs };
};

@Injectable()
export class ServersService {
  constructor(private readonly audit: AuditService) {}

  private async settings(): Promise<HealthSettings & { maxHeartbeatsPerServer: number }> {
    return prisma.monitoringServerHealthSetting.upsert({
      where: { id: 'default' },
      update: {},
      create: { id: 'default' },
    });
  }

  private summary(row: any, settings: HealthSettings, now = new Date()) {
    const latest = row.heartbeats?.[0] ?? null;
    const health = deriveServerHealth(row, latest, settings, now);
    return {
      id: row.id,
      name: row.name,
      host: row.host,
      sshPort: row.sshPort,
      region: row.region,
      environment: row.environment,
      role: row.role,
      readiness: row.readiness,
      enabled: row.enabled,
      appVersion: row.appVersion,
      lastHeartbeatAt: row.lastHeartbeatAt,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      latestHeartbeat: latest
        ? {
            receivedAt: latest.receivedAt,
            cpuPercent: latest.cpuPercent,
            ramPercent: latest.ramPercent,
            diskPercent: latest.diskPercent,
            uptimeSeconds: latest.uptimeSeconds,
            appVersion: latest.appVersion,
            network: latest.network,
            services: latest.services,
          }
        : null,
      health,
    };
  }

  async list() {
    const [rows, settings] = await Promise.all([
      prisma.monitoringServer.findMany({
        include: { heartbeats: { orderBy: { receivedAt: 'desc' }, take: 1 } },
        orderBy: [{ role: 'asc' }, { name: 'asc' }],
      }),
      this.settings(),
    ]);
    return {
      settings,
      servers: rows.map((row) => this.summary(row, settings)),
    };
  }

  async detail(id: string) {
    const [row, settings] = await Promise.all([
      prisma.monitoringServer.findUnique({
        where: { id },
        include: {
          heartbeats: { orderBy: { receivedAt: 'desc' }, take: 50 },
          events: { orderBy: { createdAt: 'desc' }, take: 100 },
        },
      }),
      this.settings(),
    ]);
    if (!row) throw new NotFoundException('server not found');
    const latest = row.heartbeats[0] ?? null;
    return {
      ...this.summary({ ...row, heartbeats: latest ? [latest] : [] }, settings),
      heartbeats: row.heartbeats,
      events: row.events,
    };
  }

  private validateServer(body: any, { creating }: { creating: boolean }) {
    for (const disallowed of ['password', 'sshPassword', 'privateKey', 'token', 'secret']) {
      if (body?.[disallowed] != null) throw new BadRequestException(`${disallowed} must not be stored in server monitoring`);
    }
    const data: Record<string, unknown> = {};
    if (creating || body.name != null) {
      const name = String(body?.name ?? '').trim();
      if (!name || name.length > 120) throw new BadRequestException('name is required and must be at most 120 characters');
      data.name = name;
    }
    if (creating || body.host != null) {
      const host = String(body?.host ?? '').trim();
      if (!host || host.length > 253 || /:\/\/|@|\s/.test(host)) throw new BadRequestException('host must be a hostname or IP address');
      data.host = host;
    }
    if (creating || body.sshPort != null) {
      const port = Number(body?.sshPort ?? 22);
      if (!Number.isInteger(port) || port < 1 || port > 65535) throw new BadRequestException('sshPort must be 1–65535');
      data.sshPort = port;
    }
    for (const field of ['region', 'environment'] as const) {
      if (creating || body?.[field] != null) {
        const value = String(body?.[field] ?? '').trim();
        if (field === 'environment' && !value) throw new BadRequestException('environment is required');
        data[field] = value || null;
      }
    }
    if (body?.enabled != null) data.enabled = !!body.enabled;
    if (body?.readiness != null) {
      const readiness = String(body.readiness).toUpperCase();
      if (!(READINESS as readonly string[]).includes(readiness)) throw new BadRequestException('invalid readiness');
      data.readiness = readiness;
    }
    return data;
  }

  async create(body: any, actorId: string, ip?: string) {
    const data = this.validateServer(body, { creating: true });
    const requestedRole = String(body?.role ?? 'STANDBY').toUpperCase();
    if (!(ROLES as readonly string[]).includes(requestedRole)) throw new BadRequestException('invalid role');
    if (requestedRole === 'PRIMARY') {
      const primary = await prisma.monitoringServer.findFirst({ where: { role: 'PRIMARY' }, select: { id: true } });
      if (primary) throw new ConflictException('a PRIMARY server is already labelled; use the confirmed Set Primary action instead');
    }
    const row = await prisma.monitoringServer.create({
      data: { ...data, role: requestedRole as ServerRole, readiness: (data.readiness ?? 'NOT_READY') as Readiness },
    });
    await this.event(row.id, 'SERVER_ADDED', 'INFO', 'Server registry entry created; it is not an active trading server.', { actorId });
    await this.audit.log(null, actorId, 'CREATE', 'monitoringServer', row.id, { after: { name: row.name, host: row.host }, ip });
    return this.detail(row.id);
  }

  async update(id: string, body: any, actorId: string, ip?: string) {
    const existing = await prisma.monitoringServer.findUnique({ where: { id }, select: { id: true, readiness: true } });
    if (!existing) throw new NotFoundException('server not found');
    const data = this.validateServer(body, { creating: false });
    if (body?.role != null) throw new BadRequestException('use the confirmed Set Primary action to change a server role');
    const row = await prisma.monitoringServer.update({ where: { id }, data });
    await this.event(id, 'SERVER_UPDATED', 'INFO', 'Server registry settings updated.', { actorId, fields: Object.keys(data) });
    await this.audit.log(null, actorId, 'UPDATE', 'monitoringServer', id, { after: data, ip });
    return this.detail(row.id);
  }

  async updateSettings(body: any, actorId: string, ip?: string) {
    const fields = [
      'cpuWarningPercent', 'cpuCriticalPercent',
      'ramWarningPercent', 'ramCriticalPercent',
      'diskWarningPercent', 'diskCriticalPercent',
      'heartbeatWarningSeconds', 'heartbeatOfflineSeconds',
      'maxHeartbeatsPerServer',
    ] as const;
    const data: Record<string, number> = {};
    for (const field of fields) {
      if (body?.[field] == null) continue;
      const value = Number(body[field]);
      const max = field === 'maxHeartbeatsPerServer' ? 100_000 : field.includes('Seconds') ? 86_400 : 100;
      if (!Number.isInteger(value) || value < 1 || value > max) throw new BadRequestException(`${field} is out of range`);
      data[field] = value;
    }
    const candidate = { ...(await this.settings()), ...data };
    for (const resource of ['cpu', 'ram', 'disk'] as const) {
      if (candidate[`${resource}WarningPercent` as keyof typeof candidate] >= candidate[`${resource}CriticalPercent` as keyof typeof candidate]) {
        throw new BadRequestException(`${resource} warning threshold must be lower than critical`);
      }
    }
    if (candidate.heartbeatWarningSeconds >= candidate.heartbeatOfflineSeconds) {
      throw new BadRequestException('heartbeat warning grace must be shorter than offline grace');
    }
    const row = await prisma.monitoringServerHealthSetting.upsert({
      where: { id: 'default' }, create: { id: 'default', ...data }, update: data,
    });
    await this.audit.log(null, actorId, 'UPDATE', 'monitoringServerHealthSettings', 'default', { after: data, ip });
    return row;
  }

  async action(id: string, body: any, actorId: string, ip?: string) {
    const action = String(body?.action ?? '').toUpperCase();
    const confirmation = String(body?.confirmation ?? '').trim().toUpperCase();
    const server = await prisma.monitoringServer.findUnique({ where: { id } });
    if (!server) throw new NotFoundException('server not found');
    if (action === 'RESTART') {
      if (confirmation !== 'RESTART') throw new BadRequestException('confirmation must be RESTART');
      await this.event(id, 'RESTART_REQUESTED', 'WARNING', 'Restart requested and recorded only; no host, container, bridge, or engine was restarted.', { actorId });
      await this.audit.log(null, actorId, 'UPDATE', 'monitoringServerAction', id, {
        after: { action, simulated: true, execution: 'none' }, ip,
      });
      return { ok: true, simulated: true, message: 'Restart request recorded only. No live action was performed.' };
    }
    if (action === 'SET_PRIMARY') {
      if (confirmation !== 'SET PRIMARY') throw new BadRequestException('confirmation must be SET PRIMARY');
      await prisma.$transaction(async (tx) => {
        const other = await tx.monitoringServer.findFirst({ where: { role: 'PRIMARY', id: { not: id } }, select: { id: true } });
        if (other) throw new ConflictException('another server is already labelled PRIMARY; clear it before labelling a second server');
        await tx.monitoringServer.update({ where: { id }, data: { role: 'PRIMARY' } });
      });
      await this.event(id, 'PRIMARY_LABELLED', 'WARNING', 'PRIMARY label changed only; no matcher was started, stopped, or failed over.', { actorId });
      await this.audit.log(null, actorId, 'UPDATE', 'monitoringServerAction', id, {
        after: { action, simulated: true, execution: 'none' }, ip,
      });
      return { ok: true, simulated: true, message: 'PRIMARY label updated only. No live failover was performed.' };
    }
    if (action === 'MAINTENANCE') {
      if (confirmation !== 'MAINTENANCE') throw new BadRequestException('confirmation must be MAINTENANCE');
      await prisma.monitoringServer.update({ where: { id }, data: { readiness: 'MAINTENANCE' } });
      await this.event(id, 'MAINTENANCE_ENABLED', 'WARNING', 'Maintenance label enabled; monitoring and execution were not changed.', { actorId });
      await this.audit.log(null, actorId, 'UPDATE', 'monitoringServerAction', id, { after: { action, execution: 'none' }, ip });
      return { ok: true, simulated: true, message: 'Maintenance label enabled only.' };
    }
    throw new BadRequestException('unsupported action');
  }

  async heartbeat(body: any, agentToken: string | undefined) {
    this.verifyAgentToken(agentToken);
    const serverId = String(body?.serverId ?? '');
    const server = await prisma.monitoringServer.findUnique({ where: { id: serverId }, select: { id: true, enabled: true } });
    if (!server) throw new NotFoundException('server not found');
    if (!server.enabled) throw new BadRequestException('server monitoring is disabled');
    const reportedAt = body?.reportedAt ? new Date(body.reportedAt) : null;
    if (reportedAt && Number.isNaN(reportedAt.getTime())) throw new BadRequestException('reportedAt is invalid');
    const metrics = {
      cpuPercent: numberInRange(body?.cpuPercent),
      ramPercent: numberInRange(body?.ramPercent),
      diskPercent: numberInRange(body?.diskPercent),
      uptimeSeconds: numberInRange(body?.uptimeSeconds, 0, 2_147_483_647),
      appVersion: typeof body?.appVersion === 'string' ? body.appVersion.slice(0, 120) : null,
      network: cleanNetwork(body?.network),
      services: cleanServices(body?.services),
    };
    const settings = await this.settings();
    const count = await prisma.monitoringServerHeartbeat.count({ where: { serverId } });
    const now = new Date();
    await prisma.monitoringServer.update({
      where: { id: serverId },
      data: { lastHeartbeatAt: now, appVersion: metrics.appVersion ?? undefined },
    });
    if (count >= settings.maxHeartbeatsPerServer) {
      await this.event(serverId, 'HEARTBEAT_CAP_REACHED', 'WARNING', 'Heartbeat storage cap reached; a new snapshot was not stored. No historic data was deleted.', {
        maxHeartbeatsPerServer: settings.maxHeartbeatsPerServer,
      });
      return { ok: true, captured: false, reason: 'heartbeat storage cap reached' };
    }
    await prisma.monitoringServerHeartbeat.create({
      data: { serverId, reportedAt, ...metrics },
    });
    return { ok: true, captured: true };
  }

  private verifyAgentToken(given: string | undefined) {
    const configured = process.env.SERVER_MONITOR_AGENT_TOKEN;
    if (!configured || !given) throw new UnauthorizedException('server agent token is not configured');
    const expected = createHash('sha256').update(configured).digest();
    const actual = createHash('sha256').update(given).digest();
    if (!timingSafeEqual(expected, actual)) throw new UnauthorizedException('invalid server agent token');
  }

  private event(serverId: string, kind: string, severity: string, message: string, detail?: Record<string, unknown>) {
    return prisma.monitoringServerEvent.create({
      data: { serverId, kind, severity, message, detail },
    });
  }
}
