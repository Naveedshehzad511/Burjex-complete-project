import { Injectable, BadRequestException } from '@nestjs/common';
import { prisma } from '@btrader/db';
import { ServerOverview } from './hq.service';

export interface CompanyStatus {
  id: string;
  name: string;
  baseUrl: string;
  enabled: boolean;
  ok: boolean;
  error: string | null;
  overview: ServerOverview | null;
}

/**
 * Central-side registry of company deployments (the HQ dashboard's data
 * source). Each row is a remote B-Trader server + its HQ_TOKEN; `companies()`
 * fans out to every enabled server's read-only /v1/hq/overview and returns
 * whatever answered, with per-server errors instead of one failure killing
 * the whole board.
 */
@Injectable()
export class HqRegistryService {
  list() {
    // Never returns the stored token — the admin UI doesn't need it back.
    return prisma.hqServer.findMany({
      select: { id: true, name: true, baseUrl: true, enabled: true, createdAt: true },
      orderBy: { createdAt: 'asc' },
    });
  }

  async create(body: { name?: string; baseUrl?: string; token?: string }) {
    const name = (body.name ?? '').trim();
    const baseUrl = (body.baseUrl ?? '').trim().replace(/\/+$/, '');
    const token = (body.token ?? '').trim();
    if (!name || !baseUrl || !token) throw new BadRequestException('name, baseUrl and token are required');
    if (!/^https?:\/\//.test(baseUrl)) throw new BadRequestException('baseUrl must start with http(s)://');
    const row = await prisma.hqServer.create({ data: { name, baseUrl, token } });
    return { id: row.id, name: row.name, baseUrl: row.baseUrl, enabled: row.enabled };
  }

  async update(id: string, body: { name?: string; baseUrl?: string; token?: string; enabled?: boolean }) {
    const data: Record<string, unknown> = {};
    if (body.name != null) data.name = String(body.name).trim();
    if (body.baseUrl != null) data.baseUrl = String(body.baseUrl).trim().replace(/\/+$/, '');
    if (body.token != null && String(body.token).trim() !== '') data.token = String(body.token).trim();
    if (body.enabled != null) data.enabled = !!body.enabled;
    const row = await prisma.hqServer.update({ where: { id }, data });
    return { id: row.id, name: row.name, baseUrl: row.baseUrl, enabled: row.enabled };
  }

  remove(id: string) {
    return prisma.hqServer.delete({ where: { id }, select: { id: true } });
  }

  /** Poll every enabled company server; per-server errors, 5s timeout each. */
  async companies(): Promise<CompanyStatus[]> {
    const servers = await prisma.hqServer.findMany({ orderBy: { createdAt: 'asc' } });
    return Promise.all(
      servers.map(async (s): Promise<CompanyStatus> => {
        const base = { id: s.id, name: s.name, baseUrl: s.baseUrl, enabled: s.enabled };
        if (!s.enabled) return { ...base, ok: false, error: 'disabled', overview: null };
        try {
          const res = await fetch(`${s.baseUrl}/v1/hq/overview`, {
            headers: { 'X-HQ-Token': s.token },
            signal: AbortSignal.timeout(5000),
          });
          if (!res.ok) return { ...base, ok: false, error: `HTTP ${res.status}`, overview: null };
          const overview = (await res.json()) as ServerOverview;
          return { ...base, ok: true, error: null, overview };
        } catch (e: any) {
          return { ...base, ok: false, error: e?.name === 'TimeoutError' ? 'timeout' : String(e?.message ?? e), overview: null };
        }
      }),
    );
  }
}
