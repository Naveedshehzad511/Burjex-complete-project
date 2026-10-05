/* eslint-disable no-console */
// Runs on every gateway start (see deploy/docker-compose.live.yml): makes the admin / demo users match the
// BT_* environment variables. Idempotent, touches only those users, and never aborts startup.
import { PrismaClient } from '@prisma/client';
import { syncUsersFromEnv } from './user-env';

const prisma = new PrismaClient();

syncUsersFromEnv(prisma)
  .catch((e) => {
    console.error('[users] sync failed:', e?.message ?? e);
  })
  .finally(() => prisma.$disconnect());
