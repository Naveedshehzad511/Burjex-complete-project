import { BookType, LpExecDriver, InstrumentClass, VenueMode } from '@btrader/shared';

/**
 * One routing rule, reduced to just the fields resolution needs (DB-agnostic so
 * this stays pure and unit-testable). Pass ENABLED rules only.
 */
export interface RoutingRuleLike {
  id: string;
  tradingGroupId: string | null;
  symbolId: string | null;
  instrumentClass: InstrumentClass | null;
  book: BookType;
  venueMode: VenueMode;
  lpProviderId: string | null;
  lpDriver: LpExecDriver | null;
  coverageRatio: number;
  priority: number;
  /** Tiebreak among equally-specific, equal-priority rules (oldest wins). */
  createdAt?: Date | string | number;
}

/** Everything about an order needed to evaluate the rules + book fallbacks. */
export interface RoutingContext {
  /** The account's TradingGroup id (account.groupId). */
  accountGroupId: string | null | undefined;
  symbolId: string;
  symbolClass: InstrumentClass;
  // Existing book hierarchy used when no rule resolves the book.
  accountBook: BookType | null | undefined;
  symbolForceBook: BookType | null | undefined;
  symbolGroupDefaultBook: BookType | null | undefined;
}

export interface RoutingResolution {
  book: BookType;
  /** How the A-book venue is chosen (from the matched rule; FIXED if none). */
  venueMode: VenueMode;
  /** FIXED venue provider from the matched rule; null = fall back. */
  lpProviderId: string | null;
  /** Legacy driver-level venue from the matched rule; null = tenant default. */
  lpDriver: LpExecDriver | null;
  /** % of an A-book order to cover to the LP at open (100 = full STP). */
  coverageRatio: number;
  matchedRuleId: string | null;
  reason: string;
}

/** A rule matches an order when every SET scope field equals the order's. */
function matches(rule: RoutingRuleLike, ctx: RoutingContext): boolean {
  if (rule.tradingGroupId != null && rule.tradingGroupId !== (ctx.accountGroupId ?? null)) return false;
  if (rule.symbolId != null && rule.symbolId !== ctx.symbolId) return false;
  if (rule.instrumentClass != null && rule.instrumentClass !== ctx.symbolClass) return false;
  return true;
}

/** Most-specific-wins score: symbol (4) > trading group (2) > class (1). */
function specificity(rule: RoutingRuleLike): number {
  return (rule.symbolId != null ? 4 : 0) + (rule.tradingGroupId != null ? 2 : 0) + (rule.instrumentClass != null ? 1 : 0);
}

function ms(v: Date | string | number | undefined): number {
  if (v == null) return 0;
  if (typeof v === 'number') return v;
  return new Date(v).getTime() || 0;
}

/**
 * Pick the winning rule for an order: highest specificity, then highest
 * priority, then oldest. Returns null when nothing matches.
 */
export function pickRoutingRule(rules: RoutingRuleLike[], ctx: RoutingContext): RoutingRuleLike | null {
  let best: RoutingRuleLike | null = null;
  let bestScore = -1;
  for (const r of rules) {
    if (!matches(r, ctx)) continue;
    const score = specificity(r);
    if (best == null || score > bestScore) {
      best = r;
      bestScore = score;
      continue;
    }
    if (score === bestScore) {
      if (r.priority > best.priority || (r.priority === best.priority && ms(r.createdAt) < ms(best.createdAt))) {
        best = r;
      }
    }
  }
  return best;
}

/**
 * Resolve the effective execution book + LP venue for an order.
 *
 * Book authority (most→least): symbol.forceBook (hard safety override) > matched
 * routing rule > account.book > symbol-group default > 'B'. The LP venue comes
 * from the matched rule; a null venue means "use the tenant default" and is left
 * for the caller (engine) to fill from LpExecutionConfig.
 */
export function resolveRouting(rules: RoutingRuleLike[], ctx: RoutingContext): RoutingResolution {
  const matched = pickRoutingRule(rules, ctx);

  let book: BookType;
  let bookReason: string;
  if (ctx.symbolForceBook != null) {
    book = ctx.symbolForceBook;
    bookReason = `symbol force-book ${book}`;
  } else if (matched != null) {
    book = matched.book;
    bookReason = `rule ${matched.id} → book ${book}`;
  } else if (ctx.accountBook != null) {
    book = ctx.accountBook;
    bookReason = `account book ${book}`;
  } else if (ctx.symbolGroupDefaultBook != null) {
    book = ctx.symbolGroupDefaultBook;
    bookReason = `symbol-group default ${book}`;
  } else {
    book = 'B';
    bookReason = 'default B (warehouse)';
  }

  const venueMode: VenueMode = matched?.venueMode ?? 'FIXED';
  const lpProviderId = matched?.lpProviderId ?? null;
  const lpDriver = matched?.lpDriver ?? null;
  // Coverage ratio applies only to A-book; clamp to 0–100 (default full STP).
  const rawRatio = matched?.coverageRatio ?? 100;
  const coverageRatio = book === 'A' ? Math.max(0, Math.min(100, rawRatio)) : 0;
  const venueReason =
    book !== 'A'
      ? 'no LP venue (B-book)'
      : venueMode === 'BEST_PRICE'
        ? 'venue = best price (active source)'
        : lpProviderId != null
          ? 'venue = fixed provider from rule'
          : lpDriver != null
            ? `venue ${lpDriver} from rule`
            : 'venue = tenant default';

  return {
    book,
    venueMode,
    lpProviderId,
    lpDriver,
    coverageRatio,
    matchedRuleId: matched?.id ?? null,
    reason: book === 'A' && coverageRatio < 100
      ? `${bookReason} (${coverageRatio}% covered); ${venueReason}`
      : `${bookReason}; ${venueReason}`,
  };
}
