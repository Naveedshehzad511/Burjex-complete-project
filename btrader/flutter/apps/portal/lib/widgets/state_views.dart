import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../crm/crm.dart';
import '../session/sessions.dart';

/// Whether the signed-in user has a trading account to show data for.
enum TradingAccountStatus {
  /// The CRM dashboard (the list of the user's accounts) has not answered yet - never shown as "none".
  loading,

  /// The CRM answered and the user has no trading account, and none is open through the "+" flow.
  none,

  /// There is an account (own or opened for trading), or it cannot be told yet because the request failed:
  /// an error is not the same as having no account, so it never produces the "create an account" message.
  available,
}

/// Source of truth is the CRM account list plus the open trading session - nothing is assumed.
final tradingAccountStatusProvider = Provider<TradingAccountStatus>((ref) {
  if (ref.watch(tradingSessionProvider.select((s) => s.accountId != null))) return TradingAccountStatus.available;
  final dash = ref.watch(crmDashboardProvider);
  final d = dash.valueOrNull;
  if (d == null) return dash.hasError ? TradingAccountStatus.available : TradingAccountStatus.loading;
  return d.accounts.isEmpty ? TradingAccountStatus.none : TradingAccountStatus.available;
});

/// Shown instead of Chart / Quotes / Trade / History when the user has no trading account yet.
class NoTradingAccountView extends StatelessWidget {
  const NoTradingAccountView({super.key, this.what = 'charts and market quotes'});
  final String what;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.account_balance_wallet_outlined, size: 54, color: Theme.of(context).hintColor),
          const SizedBox(height: 16),
          Text('Please create a trading account to view $what.',
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: () => context.push('/open-account'),
            icon: const Icon(Icons.add),
            label: const Text('Open trading account'),
            style: FilledButton.styleFrom(backgroundColor: cs.primary),
          ),
        ]),
      ),
    );
  }
}

/// A load failure, said in words that match the real cause, with a retry.
class LoadErrorView extends StatelessWidget {
  const LoadErrorView(this.error, {super.key, this.onRetry, this.title});
  final Object error;
  final VoidCallback? onRetry;
  final String? title;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (title != null) ...[Text(title!, style: const TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 6)],
            Text(crmMessage(error), textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
            if (onRetry != null) ...[const SizedBox(height: 12), OutlinedButton(onPressed: onRetry, child: const Text('Retry'))],
          ]),
        ),
      );
}
