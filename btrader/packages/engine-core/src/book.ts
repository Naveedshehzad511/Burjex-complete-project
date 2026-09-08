import { BookType } from '@btrader/shared';

/**
 * Resolve the execution book for an order using the dealer hierarchy:
 *
 *   1. symbol.forceBook   — if set, wins (e.g. force risky instruments to A-book)
 *   2. account.book       — the per-client switch the admin toggles
 *   3. group.defaultBook  — the symbol group's default
 *   4. fallback 'B'       — warehouse if nothing configured
 *
 * Pure and side-effect free so it can be unit-tested and called on the hot path.
 */
export function resolveBook(input: {
  accountBook: BookType | null | undefined;
  symbolForceBook: BookType | null | undefined;
  groupDefaultBook: BookType | null | undefined;
}): BookType {
  return (
    input.symbolForceBook ??
    input.accountBook ??
    input.groupDefaultBook ??
    'B'
  );
}
