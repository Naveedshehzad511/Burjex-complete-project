/* eslint-disable no-console */
import { PrismaClient, InstrumentClass } from '@prisma/client';
import { syncUsersFromEnv } from './user-env';

const prisma = new PrismaClient();

async function main() {
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

  // ── Users: super admin / tenant admin / demo trader come from BT_* env variables (no defaults) ──
  await syncUsersFromEnv(prisma);

  console.log('Seed complete: tenant=%s symbols=%d', tenant.slug, seedSymbols.length);
  console.log('Users were created/updated from the BT_* environment variables (see prisma/user-env.ts).');
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
