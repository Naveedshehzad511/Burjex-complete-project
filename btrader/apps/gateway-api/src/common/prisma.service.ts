import { Injectable, OnModuleInit } from '@nestjs/common';
import { prisma } from '@btrader/db';

/**
 * Thin Nest-injectable wrapper around the shared Prisma singleton so services
 * can `constructor(private prisma: PrismaService)` while pooling stays shared.
 */
@Injectable()
export class PrismaService implements OnModuleInit {
  readonly client = prisma;
  async onModuleInit() {
    await this.client.$connect();
  }
}
