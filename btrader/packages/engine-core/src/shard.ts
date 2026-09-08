/** Tenant → engine shard. Matches docs/08: one replica owns a tenant's tick book. */

export function engineShard(): number {
  return Math.max(0, Number(process.env.ENGINE_SHARD ?? 0) || 0);
}

export function engineShardCount(): number {
  return Math.max(1, Number(process.env.ENGINE_SHARD_COUNT ?? 1) || 1);
}

export function shardOfTenant(tenantId: string, count = engineShardCount()): number {
  let h = 0;
  for (let i = 0; i < tenantId.length; i++) h = (Math.imul(h, 31) + tenantId.charCodeAt(i)) >>> 0;
  return h % count;
}

export function tenantOwnedByThisShard(tenantId: string): boolean {
  const n = engineShardCount();
  if (n <= 1) return true;
  return shardOfTenant(tenantId, n) === engineShard();
}

export function engineLockKey(): string {
  const n = engineShardCount();
  if (n <= 1) return 'bt:engine:instance-lock';
  return `bt:engine:instance-lock:${engineShard()}`;
}
