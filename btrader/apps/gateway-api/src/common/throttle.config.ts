/** Parse a positive integer env var; ignore 0/NaN so production defaults stay in force. */
export function envPositiveInt(name: string, fallback: number): number {
  const n = Number(process.env[name]);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

/** Sliding window for both the default and login throttles. */
export const THROTTLE_TTL_MS = envPositiveInt('THROTTLE_TTL_MS', 60_000);

/**
 * Per-IP budget for authenticated reads (quotes, positions, …).
 * 300/min is enough for a single client IP. NAT of hundreds of VUs (Grafana Cloud
 * k6, a large office) must raise THROTTLE_LIMIT on that stack — do not raise this default.
 */
export const THROTTLE_LIMIT = envPositiveInt('THROTTLE_LIMIT', 300);

/**
 * Stricter per-IP budget for password endpoints. Lower than the old global 300 so
 * credential stuffing is not granted the same budget as market polls.
 */
export const THROTTLE_AUTH_LIMIT = envPositiveInt('THROTTLE_AUTH_LIMIT', 60);

export const THROTTLE_AUTH_TTL_MS = envPositiveInt('THROTTLE_AUTH_TTL_MS', THROTTLE_TTL_MS);
