/* eslint-disable no-console */
// Admin / demo users come from environment variables - never from hard-coded defaults.
//
//   BT_SUPER_ADMIN_EMAIL / BT_SUPER_ADMIN_PASSWORD     platform super admin (no tenant)
//   BT_TENANT_ADMIN_EMAIL / BT_TENANT_ADMIN_PASSWORD   admin of the tenant below (admin dashboard login)
//   BT_DEMO_TRADER_EMAIL / BT_DEMO_TRADER_PASSWORD     demo trader (+ its account, see below)
//   BT_DEMO_TRADER_ACCOUNT_LOGIN   login of the demo trader's account (default 500001)
//   BT_DEFAULT_TENANT              tenant slug the two tenant users belong to (default "demo")
//
// A pair is used only when BOTH halves are set. Re-running updates the password of an existing user
// to whatever the env says now, so changing the env and restarting changes the password. Changing an
// EMAIL creates a new user; the old one is left as it is (deactivate it in the admin if unwanted).
import * as crypto from 'crypto';
import type { PrismaClient } from '@prisma/client';

export function hashPassword(s: string): string {
  return crypto.createHash('sha256').update(s).digest('hex');
}

type Pair = { email: string; password: string } | null;

function pair(emailKey: string, passKey: string): Pair {
  const email = (process.env[emailKey] ?? '').trim().toLowerCase();
  const password = process.env[passKey] ?? '';
  if (!email && !password) return null;
  if (!email || !password) {
    console.warn(`[users] ${emailKey} and ${passKey} must both be set - skipped`);
    return null;
  }
  return { email, password };
}

async function upsertUser(
  prisma: PrismaClient,
  tenantId: string | null, // null = platform level (no tenant)
  p: { email: string; password: string },
  role: 'SUPER_ADMIN' | 'TENANT_ADMIN' | 'TRADER',
  firstName: string,
  lastName: string,
) {
  const passwordHash = hashPassword(p.password);
  // findFirst (not the compound unique) so that tenantId = null matches too.
  const existing = await prisma.user.findFirst({ where: { tenantId, email: p.email } });
  if (existing) {
    const changed = existing.passwordHash !== passwordHash || !existing.isActive || existing.role !== role;
    if (changed) {
      await prisma.user.update({ where: { id: existing.id }, data: { passwordHash, isActive: true, role } });
      console.log(`[users] updated ${role} ${p.email}`);
    } else {
      console.log(`[users] ${role} ${p.email} already up to date`);
    }
    return existing;
  }
  const created = await prisma.user.create({
    data: { ...(tenantId ? { tenantId } : {}), email: p.email, role, passwordHash, firstName, lastName, isActive: true },
  });
  console.log(`[users] created ${role} ${p.email}`);
  return created;
}

/** Super admin + (when the tenant exists) tenant admin and demo trader, all from the environment. */
export async function syncUsersFromEnv(prisma: PrismaClient): Promise<void> {
  const superAdmin = pair('BT_SUPER_ADMIN_EMAIL', 'BT_SUPER_ADMIN_PASSWORD');
  if (superAdmin) await upsertUser(prisma, null, superAdmin, 'SUPER_ADMIN', 'Platform', 'Admin');

  const tenantAdmin = pair('BT_TENANT_ADMIN_EMAIL', 'BT_TENANT_ADMIN_PASSWORD');
  const trader = pair('BT_DEMO_TRADER_EMAIL', 'BT_DEMO_TRADER_PASSWORD');
  if (!tenantAdmin && !trader) return;

  const slug = (process.env.BT_DEFAULT_TENANT ?? 'demo').trim() || 'demo';
  const tenant = await prisma.tenant.findUnique({ where: { slug } });
  if (!tenant) {
    console.warn(`[users] tenant "${slug}" does not exist yet - tenant admin / demo trader skipped (run the seed once)`);
    return;
  }

  if (tenantAdmin) await upsertUser(prisma, tenant.id, tenantAdmin, 'TENANT_ADMIN', 'Tenant', 'Admin');

  if (trader) {
    const user = await upsertUser(prisma, tenant.id, trader, 'TRADER', 'Demo', 'Trader');
    const login = (process.env.BT_DEMO_TRADER_ACCOUNT_LOGIN ?? '500001').trim() || '500001';
    await prisma.account.upsert({
      where: { tenantId_login: { tenantId: tenant.id, login } },
      update: {},
      create: { tenantId: tenant.id, userId: user.id, login, type: 'STANDARD', currency: 'USD', leverage: 100, balance: '10000' },
    });
  }
}
