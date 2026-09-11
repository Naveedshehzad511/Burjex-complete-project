/** First hop in a comma-separated forwarded header. */
function firstHop(value: unknown): string {
  if (typeof value !== 'string' || !value.trim()) return '';
  return value.split(',')[0].trim().replace(/^::ffff:/, '');
}

/**
 * Client IP behind Caddy. Prefer X-Real-IP / X-Forwarded-For over the socket
 * peer (which is always the reverse proxy when trust proxy is unset).
 */
export function clientIp(req: { headers?: Record<string, unknown>; ip?: string }): string {
  const headers = req.headers ?? {};
  const real = firstHop(headers['x-real-ip']);
  if (real) return real;
  const forwarded = firstHop(headers['x-forwarded-for']);
  if (forwarded) return forwarded;
  return String(req.ip || 'anonymous').replace(/^::ffff:/, '');
}
