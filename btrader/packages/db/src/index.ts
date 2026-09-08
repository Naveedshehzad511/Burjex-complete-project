export * from '@prisma/client';
import { PrismaClient } from '@prisma/client';

/**
 * Singleton Prisma client. In dev we attach to globalThis to survive HMR.
 * Every B-Trader service imports `prisma` from here so connection pooling is shared
 * per-process.
 */
declare global {
  // eslint-disable-next-line no-var
  var __btraderPrisma: PrismaClient | undefined;
}

export const prisma: PrismaClient =
  global.__btraderPrisma ??
  new PrismaClient({
    log: process.env.LOG_LEVEL === 'debug' ? ['query', 'warn', 'error'] : ['warn', 'error'],
  });

if (process.env.NODE_ENV !== 'production') global.__btraderPrisma = prisma;
