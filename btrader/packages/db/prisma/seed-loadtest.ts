/* eslint-disable no-console */
import { PrismaClient } from '@prisma/client';
import { createHash, randomUUID } from 'crypto';

const prisma = new PrismaClient();
const count = Number(process.env.LOADTEST_ACCOUNT_COUNT ?? 2000);
const loginBase = Number(process.env.LOADTEST_LOGIN_BASE ?? 700000);
const password = process.env.LOADTEST_PASSWORD ?? '';
const tenantSlug = process.env.LOADTEST_TENANT ?? 'demo';

function sha256(value: string): string {
  return createHash('sha256').update(value).digest('hex');
}

async function main() {
  if (process.env.LOADTEST_SEED !== 'isolated-staging') {
    throw new Error('Refusing to seed accounts: set LOADTEST_SEED=isolated-staging');
  }
  if (!Number.isSafeInteger(count) || count < 1 || count > 10_000) {
    throw new Error('LOADTEST_ACCOUNT_COUNT must be an integer between 1 and 10000');
  }
  if (!Number.isSafeInteger(loginBase) || loginBase < 1) {
    throw new Error('LOADTEST_LOGIN_BASE must be a positive integer');
  }
  if (password.length < 8) {
    throw new Error('LOADTEST_PASSWORD must be a disposable password of at least 8 characters');
  }

  const tenant = await prisma.tenant.findUnique({ where: { slug: tenantSlug } });
  if (!tenant) throw new Error(`Tenant ${tenantSlug} was not found; run db:seed first`);

  const rows = Array.from({ length: count }, (_, i) => {
    const login = String(loginBase + i + 1);
    return { login, email: `loadtest-${login}@invalid.example`, userId: randomUUID() };
  });
  const passwordHash = sha256(password);

  await prisma.user.createMany({
    data: rows.map((row) => ({
      id: row.userId,
      tenantId: tenant.id,
      email: row.email,
      role: 'TRADER',
      firstName: 'Load',
      lastName: `Test ${row.login}`,
      passwordHash,
      isActive: true,
    })),
    skipDuplicates: true,
  });

  const users = await prisma.user.findMany({
    where: { tenantId: tenant.id, email: { in: rows.map((row) => row.email) } },
    select: { id: true, email: true },
  });
  const userIdByEmail = new Map(users.map((user) => [user.email, user.id]));

  await prisma.account.createMany({
    data: rows.flatMap((row) => {
      const userId = userIdByEmail.get(row.email);
      return userId
        ? [{
            tenantId: tenant.id,
            userId,
            login: row.login,
            passwordHash,
            type: 'DEMO',
            isDemo: true,
            book: 'B',
            currency: 'USD',
            leverage: 100,
            balance: 100_000,
          }]
        : [];
    }),
    skipDuplicates: true,
  });

  const accounts = await prisma.account.count({
    where: { tenantId: tenant.id, login: { gte: String(loginBase + 1), lte: String(loginBase + count) } },
  });
  if (accounts !== count) {
    throw new Error(`Expected ${count} disposable accounts, found ${accounts}`);
  }
  console.log(`Seeded ${accounts} isolated load-test accounts for tenant ${tenantSlug}`);
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
