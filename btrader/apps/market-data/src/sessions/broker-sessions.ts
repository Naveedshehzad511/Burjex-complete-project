import { FeedSource, SymbolSessionsIn } from '../adapters/mt5-ingest-adapter';

// ── Broker trade sessions (MT5 EA v8 → symbols.brokerSessions) ─────────────
// Last stored copy per tenant|symbol, so the table is only written when the broker's schedule (or its UTC
// conversion, after a DST switch) actually changes. The timestamp is still refreshed every hour so a
// silent EA is noticed (sessions older than 3 days are not used).
const storedSessions = new Map<string, { json: string; at: number }>();
const SESSIONS_TOUCH_MS = 60 * 60_000;

export async function storeBrokerSessions(
  source: FeedSource,
  list: SymbolSessionsIn[],
  resolve: (tenantId: string | null, raw: string) => Array<{ tenantId: string; symbol: string }>,
  write: (tenantId: string, symbol: string, json: string) => Promise<number>,
  now = Date.now(),
): Promise<number> {
  let written = 0;
  for (const e of list) {
    const json = JSON.stringify(e.sessions);
    for (const t of resolve(source.tenantId, e.symbol)) {
      const k = `${t.tenantId}|${t.symbol}`;
      const prev = storedSessions.get(k);
      if (prev && prev.json === json && now - prev.at < SESSIONS_TOUCH_MS) continue;
      try {
        const n = await write(t.tenantId, t.symbol, json);
        if (n > 0) {
          if (!prev || prev.json !== json) {
            console.log(`[market-data] broker sessions ${prev ? 'changed' : 'stored'} for ${t.symbol} (${t.tenantId}, ${source.code})`);
          }
          storedSessions.set(k, { json, at: now });
          written++;
        }
      } catch (err) {
        console.warn(`[market-data] broker sessions write failed for ${t.symbol}: ${(err as Error).message}`);
      }
    }
  }
  return written;
}
