import { describe, expect, it, vi } from 'vitest';

vi.mock('@btrader/db', () => ({ prisma: {} }));
vi.mock('@btrader/shared', () => ({ latency: { time: (_: string, f: () => unknown) => f() } }));

import { isPrivateIp, tradeClientIp } from './trading.controller';

describe('trade IP', () => {
  it('takes the visitor IP Cloudflare sends, not the Docker gateway', () => {
    const req = { headers: { 'cf-connecting-ip': '103.21.4.10', 'x-real-ip': '172.21.0.1', 'x-forwarded-for': '172.21.0.1' }, ip: '172.21.0.1' };
    expect(tradeClientIp(req)).toBe('103.21.4.10');
  });

  it('records nothing when only a proxy / private address is known', () => {
    expect(tradeClientIp({ headers: { 'x-real-ip': '172.21.0.1' }, ip: '172.21.0.1' })).toBeNull();
    expect(tradeClientIp({ headers: {}, ip: '::ffff:10.0.0.5' })).toBeNull();
  });

  it('uses X-Real-IP off Cloudflare when it is public', () => {
    expect(tradeClientIp({ headers: { 'x-real-ip': '49.36.10.25' } })).toBe('49.36.10.25');
  });

  it('knows private ranges', () => {
    for (const ip of ['10.1.2.3', '127.0.0.1', '192.168.1.4', '172.16.0.1', '172.31.255.1', '::1', 'fd00::1', 'fe80::1']) expect(isPrivateIp(ip)).toBe(true);
    for (const ip of ['172.15.0.1', '172.32.0.1', '103.10.0.10', '2401:4900::1']) expect(isPrivateIp(ip)).toBe(false);
  });
});
