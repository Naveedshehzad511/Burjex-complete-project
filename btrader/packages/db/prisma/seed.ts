/* eslint-disable no-console */
import { PrismaClient, InstrumentClass } from '@prisma/client';
import * as crypto from 'crypto';

const prisma = new PrismaClient();

function hash(s: string) {
  return crypto.createHash('sha256').update(s).digest('hex');
}

async function main() {
  // ── Platform super admin ───────────────────────────────────────────────
  await prisma.user.upsert({
    where: { tenantId_email: { tenantId: '', email: 'super@btrader.io' } as any },
    update: {},
    create: {
      email: 'super@btrader.io',
      role: 'SUPER_ADMIN',
      passwordHash: hash('ChangeMe123!'),
      firstName: 'Platform',
      lastName: 'Admin',
      isActive: true,
    },
  });

  // ── Demo tenant: "Demo Broker" ──────────────────────────────────────────────
  const tenant = await prisma.tenant.upsert({
    where: { slug: 'demo' },
    update: {},
    create: {
      name: 'Demo Broker',
      slug: 'demo',
      domain: 'demofx.com',
      status: 'ACTIVE',
      baseCurrency: 'USD',
      branding: {
        create: { appName: 'Demo Trader', primaryColor: '#1652F0', accentColor: '#0BB07B' },
      },
    },
  });

  // ── Symbol group + a few instruments across classes (no hardcoding in app) ─
  const fx = await prisma.symbolGroup.upsert({
    where: { tenantId_name: { tenantId: tenant.id, name: 'Forex Majors' } },
    update: {},
    create: { tenantId: tenant.id, name: 'Forex Majors' },
  });

  const seedSymbols: Array<{
    symbol: string;
    desc: string;
    cls: InstrumentClass;
    base: string;
    quote: string;
    digits: number;
    pip: string;
    contract: string;
  }> = [
    { symbol: 'EURUSD', desc: 'Euro vs US Dollar', cls: 'FOREX', base: 'EUR', quote: 'USD', digits: 5, pip: '0.0001', contract: '100000' },
    { symbol: 'GBPUSD', desc: 'Pound vs US Dollar', cls: 'FOREX', base: 'GBP', quote: 'USD', digits: 5, pip: '0.0001', contract: '100000' },
    { symbol: 'XAUUSD', desc: 'Gold vs US Dollar', cls: 'METALS', base: 'XAU', quote: 'USD', digits: 2, pip: '0.01', contract: '100' },
    { symbol: 'BTCUSD', desc: 'Bitcoin vs US Dollar', cls: 'CRYPTO', base: 'BTC', quote: 'USD', digits: 2, pip: '0.01', contract: '1' },
  ];

  for (const [i, s] of seedSymbols.entries()) {
    await prisma.symbol.upsert({
      where: { tenantId_symbol: { tenantId: tenant.id, symbol: s.symbol } },
      update: {},
      create: {
        tenantId: tenant.id,
        groupId: s.cls === 'FOREX' ? fx.id : null,
        symbol: s.symbol,
        description: s.desc,
        class: s.cls,
        baseCurrency: s.base,
        quoteCurrency: s.quote,
        digits: s.digits,
        pipSize: s.pip,
        contractSize: s.contract,
        slippagePoints: 0, // default slippage = 0
        sortOrder: i,
      },
    });
  }

  // ── Demo trader + account ───────────────────────────────────────────────
  const trader = await prisma.user.upsert({
    where: { tenantId_email: { tenantId: tenant.id, email: 'trader@demofx.com' } },
    update: {},
    create: {
      tenantId: tenant.id,
      email: 'trader@demofx.com',
      role: 'TRADER',
      passwordHash: hash('Trader123!'),
      firstName: 'Demo',
      lastName: 'Trader',
      isActive: true,
    },
  });

  await prisma.account.upsert({
    where: { tenantId_login: { tenantId: tenant.id, login: '500001' } },
    update: {},
    create: {
      tenantId: tenant.id,
      userId: trader.id,
      login: '500001',
      type: 'STANDARD',
      currency: 'USD',
      leverage: 100,
      balance: '10000',
    },
  });

  // ── Tenant admin (for the admin dashboard login) ────────────────────────
  await prisma.user.upsert({
    where: { tenantId_email: { tenantId: tenant.id, email: 'admin@demofx.com' } },
    update: {},
    create: {
      tenantId: tenant.id,
      email: 'admin@demofx.com',
      role: 'TENANT_ADMIN',
      passwordHash: hash('Admin123!'),
      firstName: 'Demo',
      lastName: 'Admin',
      isActive: true,
    },
  });

  console.log('Seed complete: tenant=%s symbols=%d', tenant.slug, seedSymbols.length);
  console.log('Logins → super@btrader.io / ChangeMe123!  ·  admin@demofx.com / Admin123!  ·  trader@demofx.com / Trader123!');
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
