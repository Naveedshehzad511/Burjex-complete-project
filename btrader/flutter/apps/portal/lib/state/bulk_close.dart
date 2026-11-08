/// MT5's bulk operations on the Trade tab's "..." menu. They are the existing Close All with a narrower reach:
/// the server runs the same close-all (same group delay, same checks, same closing code) and only skips the positions
/// outside the chosen category, judging by its own live floating P/L.
enum BulkClose { all, profitable, losing }

extension BulkCloseApi on BulkClose {
  /// The original Close All keeps its own route and its empty body, exactly as before. The two narrower operations use
  /// a route of their own (`close-scoped`): a server that predates it answers 404 and closes nothing, so a scope can
  /// never be ignored (which would close every position).
  String path(String accountId) => this == BulkClose.all ? '/accounts/$accountId/close-all' : '/accounts/$accountId/close-scoped';

  /// The request body: empty for Close All.
  Map<String, Object> get body => switch (this) {
        BulkClose.all => const {},
        BulkClose.profitable => const {'scope': 'profitable'},
        BulkClose.losing => const {'scope': 'losing'},
      };

  String get menuLabel => switch (this) {
        BulkClose.all => 'Close all positions',
        BulkClose.profitable => 'Close all profitable positions',
        BulkClose.losing => 'Close all losing positions',
      };

  /// "No profitable positions to close." (only for the two narrower operations).
  String get nothingToClose => 'No ${this == BulkClose.profitable ? 'profitable' : 'losing'} positions to close.';
}

/// Profit or loss is judged on the cents shown on screen, so a position at 0.00 is neither profitable nor losing.
bool isProfit(double pl) => (pl * 100).round() > 0;
bool isLoss(double pl) => (pl * 100).round() < 0;

bool inBulkScope(BulkClose scope, double pl) => switch (scope) {
      BulkClose.all => true,
      BulkClose.profitable => isProfit(pl),
      BulkClose.losing => isLoss(pl),
    };

/// Which bulk operations the menu offers for these live profits / losses: Close all is always there when something
/// is open (the caller hides the whole menu otherwise); a category appears only when a position is in it.
({bool profitable, bool losing}) bulkCloseOptions(Iterable<double> pls) {
  var profitable = false, losing = false;
  for (final pl in pls) {
    if (isProfit(pl)) profitable = true;
    if (isLoss(pl)) losing = true;
  }
  return (profitable: profitable, losing: losing);
}
