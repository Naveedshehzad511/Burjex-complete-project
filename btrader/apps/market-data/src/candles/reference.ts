/**
 * Which tenant's tick stream a symbol's chart bar follows.
 *
 * A tenant's price (the client's Bid / Ask, the price line, fills) is the quote that tenant's own pricing
 * chose: its primary provider, or the best spread among its providers with hysteresis. The chart bar used
 * to be built from a DIFFERENT choice - the tightest quote across every source of every tenant, re-picked
 * on each tick - so whenever those two choices differed (several liquidity sources, a fast market where
 * their quotes diverge) the price line and the forming candle sat at different prices.
 *
 * The bar is now built from the very quote that is published to a tenant, inside the same call that
 * publishes the tick. One bar series exists per symbol (bars are stored once, then given each tenant's
 * markup at publish time), so exactly ONE tenant's stream feeds it. That tenant is chosen
 * deterministically - the smallest tenant id routed for the symbol - so the choice is stable across
 * ticks and restarts. With a single tenant (the usual deployment) the bar and that tenant's tick are the
 * same stream; other tenants receive the bar with their own markup, as before.
 */
export function referenceTenant(targets: ReadonlyArray<{ tenantId: string }> | undefined): string | null {
  if (!targets || targets.length === 0) return null;
  let best = targets[0]!.tenantId;
  for (const t of targets) if (t.tenantId < best) best = t.tenantId;
  return best;
}
