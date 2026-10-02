import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../crm/crm.dart';
import '../main.dart' show kNavy;
import '../session/sessions.dart';
import '../widgets/manage_accounts.dart';
import '../widgets/portal_drawer.dart';
import '../widgets/portal_ui.dart';

const _kHideBalanceKey = 'bx_hide_balance';
const _kHomeTabKey = 'bx_home_tab';
const _kGreen = Color(0xFF22C55E);

/// Dashboard. Built only from the CRM's own account list, so signing into another
/// client's account through Trade → "+" can never change what is shown here.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _scaffold = GlobalKey<ScaffoldState>();
  bool _demo = false;
  bool _hidden = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _restorePrefs();
    // The CRM ledger has no push channel; a light refresh keeps balances current.
    _poll = Timer.periodic(const Duration(seconds: 12), (_) {
      if (mounted) ref.invalidate(crmDashboardProvider);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _restorePrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _hidden = p.getBool(_kHideBalanceKey) ?? false;
      _demo = p.getString(_kHomeTabKey) == 'demo';
    });
  }

  Future<void> _setDemo(bool v) async {
    setState(() => _demo = v);
    (await SharedPreferences.getInstance()).setString(_kHomeTabKey, v ? 'demo' : 'real');
  }

  Future<void> _toggleHidden() async {
    setState(() => _hidden = !_hidden);
    (await SharedPreferences.getInstance()).setBool(_kHideBalanceKey, _hidden);
  }

  @override
  Widget build(BuildContext context) {
    final dash = ref.watch(crmDashboardProvider);
    final profile = ref.watch(crmProfileProvider).valueOrNull;
    final dark = Theme.of(context).brightness == Brightness.dark;

    // Header scales with screen width: compact on phones, roomier on tablet/desktop.
    final sw = MediaQuery.sizeOf(context).width;
    final btn = (sw * 0.095).clamp(34.0, 44.0);
    final titleSize = (sw * 0.058).clamp(20.0, 30.0);

    Widget iconBtn(IconData i, VoidCallback onTap, String tip) => Padding(
          padding: EdgeInsets.only(left: sw < 400 ? 6 : 8),
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Theme.of(context).dividerColor)),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: Tooltip(message: tip, child: SizedBox(width: btn, height: btn, child: Icon(i, size: btn * 0.5))),
            ),
          ),
        );

    return Scaffold(
      key: _scaffold,
      drawer: const PortalDrawer(),
      // The rest of the screen stays visible, just dimmed enough to give the menu focus.
      drawerScrimColor: Colors.black.withValues(alpha: 0.45),
      backgroundColor: dark ? null : const Color(0xFFF4F6F9),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(crmDashboardProvider);
            await ref.read(crmDashboardProvider.future).catchError((_) => const CrmDashboard(real: CrmMetrics(), demo: CrmMetrics(), accounts: [], userName: '', walletBalance: 0));
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Row(children: [
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text('Dashboard', maxLines: 1, style: TextStyle(fontSize: titleSize, fontWeight: FontWeight.w800, height: 1.1)),
                  ),
                ),
                iconBtn(Icons.person_outline, () => context.push('/profile'), 'Profile'),
                iconBtn(Icons.menu, () => _scaffold.currentState?.openDrawer(), 'Menu'),
              ]),
              const SizedBox(height: 14),
              dash.when(
                // The 12s poll and pull-to-refresh reload in the background: keep the
                // dashboard on screen instead of flashing a loader.
                skipLoadingOnReload: true,
                skipLoadingOnRefresh: true,
                loading: () => const _HomeSkeleton(),
                error: (e, _) => _OfflineCard(onRetry: () => ref.invalidate(crmDashboardProvider)),
                data: (d) {
                  final accounts = d.accounts.where((a) => a.isDemo == _demo).toList();
                  // The CRM figures refresh every ~12 s. Overlay the live trading-account
                  // values (pushed over the socket) so Equity / Open PnL / Margin move
                  // with the market; fall back to the CRM numbers for any account the
                  // trading side does not know.
                  final base = _demo ? d.demo : d.real;
                  final tAccts = [for (final a in accounts) _tradingByLogin(ref, a.login)];
                  final known = tAccts.whereType<Account>().toList();
                  final allLive = accounts.isNotEmpty && known.length == accounts.length;
                  final metrics = CrmMetrics(
                    balance: base.balance,
                    equity: allLive ? known.fold<double>(0, (s, t) => s + t.equity) : base.equity,
                    openPnl: allLive ? known.fold<double>(0, (s, t) => s + t.floatingPL) : base.openPnl,
                    withdrawable: base.withdrawable,
                    margin: known.fold<double>(0, (s, t) => s + t.margin),
                  );
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (ref.watch(crmDashboardOfflineProvider)) const _OfflineBanner(),
                    _PerformanceCard(demo: _demo, metrics: metrics, hidden: _hidden, onToggleHidden: _toggleHidden),
                    if (profile != null && !profile.kycApproved) ...[const SizedBox(height: 10), const _KycNotice()],
                    const ViewingOtherAccountNotice(),
                    const SizedBox(height: 22),
                    Row(children: [
                      const Expanded(child: Text('Account List', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800))),
                      _ModeCard(label: 'Real', selected: !_demo, onTap: () => _setDemo(false)),
                      const SizedBox(width: 8),
                      _ModeCard(label: 'Demo', selected: _demo, onTap: () => _setDemo(true)),
                    ]),
                    const SizedBox(height: 12),
                    if (accounts.isEmpty)
                      InfoCard(
                        child: Column(children: [
                          Text(_demo ? 'No demo accounts yet.' : 'No real accounts yet.', style: const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 10),
                          FilledButton(
                            onPressed: () => context.push('/open-account?type=${_demo ? 'demo' : 'real'}'),
                            style: navyButton(),
                            child: Text(_demo ? '+ Open Demo Account' : '+ Open Real Account'),
                          ),
                        ]),
                      )
                    else
                      for (final a in accounts) _AccountCard(account: a, hidden: _hidden),
                  ]);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The live trading account behind a CRM account (matched by login): the socket-pushed
/// snapshot when there is one, else the last REST one. Null when the trading side has no
/// such account.
Account? _tradingByLogin(WidgetRef ref, String login) {
  final accts = ref.watch(accountsProvider).valueOrNull ?? const <Account>[];
  final live = ref.watch(liveAccountProvider);
  for (final t in accts) {
    if (t.login == login) return live[t.id] ?? t;
  }
  return null;
}

/// The single large account card: mode, Open Account, balance (+ eye), performance.
class _PerformanceCard extends StatelessWidget {
  const _PerformanceCard({required this.demo, required this.metrics, required this.hidden, required this.onToggleHidden});
  final bool demo;
  final CrmMetrics metrics;
  final bool hidden;
  final VoidCallback onToggleHidden;

  String _money(double v) => hidden ? '••••••' : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final pct = metrics.performancePct;
    final up = (pct ?? 0) >= 0;
    final perfColor = up ? _kGreen : const Color(0xFFFF6B6B);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF071A33), kNavy, Color(0xFF0B3F73)]),
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [BoxShadow(color: Color(0x33002D58), blurRadius: 24, offset: Offset(0, 10))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
            child: Text(demo ? 'Demo Account' : 'Real Account', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
          ),
          const SizedBox(width: 8),
          const Spacer(),
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => context.push('/open-account?type=${demo ? 'demo' : 'real'}'),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
              ),
              child: const Text('+ Open Account', maxLines: 1, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12.5)),
            ),
          ),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Text('TOTAL BALANCE', style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1)),
          const SizedBox(width: 6),
          InkWell(
            onTap: onToggleHidden,
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 19, color: Colors.white.withValues(alpha: 0.85)),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(_money(metrics.balance), style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1.1)),
            ),
          ),
          const SizedBox(width: 8),
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('USD', style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 15))),
        ]),
        const SizedBox(height: 12),
        // Performance indicator — open PnL as a share of balance, drawn as a green
        // meter. Real data only: it is empty when there is no balance to compare to.
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: perfColor.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: perfColor.withValues(alpha: 0.4)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(up ? Icons.trending_up : Icons.trending_down, size: 15, color: perfColor),
              const SizedBox(width: 5),
              Text(
                hidden ? '•••' : (pct == null ? '—' : '${up ? '+' : ''}${pct.toStringAsFixed(2)}%'),
                style: TextStyle(color: perfColor, fontWeight: FontWeight.w800, fontSize: 12.5),
              ),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: hidden || pct == null ? 0 : (pct.abs() / 5).clamp(0.04, 1.0),
                backgroundColor: Colors.white.withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation(perfColor),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 16),
        Container(height: 1, color: Colors.white.withValues(alpha: 0.12)),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Stat('Equity', _money(metrics.equity)),
          _StatDivider(),
          _Stat('Margin', _money(metrics.margin)),
          _StatDivider(),
          _Stat('Open PnL', _money(metrics.openPnl)),
        ]),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(label, maxLines: 1, style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, maxLines: 1, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
          ),
        ]),
      );
}

class _StatDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 44, margin: const EdgeInsets.symmetric(horizontal: 10), color: Colors.white.withValues(alpha: 0.12));
}

/// Understated KYC reminder — visible, but no longer a red banner over the page.
class _KycNotice extends StatelessWidget {
  const _KycNotice();
  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => context.push('/kyc'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(children: [
            const Icon(Icons.info_outline, size: 16, color: Color(0xFFB7791F)),
            const SizedBox(width: 6),
            Expanded(
              child: Text('KYC is pending — complete it to unlock withdrawals.',
                  style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor, fontWeight: FontWeight.w500)),
            ),
            Text('Verify', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.primary)),
            Icon(Icons.chevron_right, size: 16, color: Theme.of(context).colorScheme.primary),
          ]),
        ),
      );
}

/// Real / Demo selector. Both are the same navy card; the selected one is solid
/// with a bright edge, the other is toned down — same function, same colour.
/// Shown (instead of a spinner) while the very first dashboard load is in flight.
class _HomeSkeleton extends StatefulWidget {
  const _HomeSkeleton();
  @override
  State<_HomeSkeleton> createState() => _HomeSkeletonState();
}

class _HomeSkeletonState extends State<_HomeSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.onSurface;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final a = 0.05 + 0.06 * _c.value;
        Widget block(double h, {double? w, double r = 12}) => Container(
              height: h,
              width: w,
              decoration: BoxDecoration(color: base.withValues(alpha: a), borderRadius: BorderRadius.circular(r)),
            );
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          block(230, r: 24),
          const SizedBox(height: 22),
          Row(children: [block(24, w: 130), const Spacer(), block(34, w: 58), const SizedBox(width: 8), block(34, w: 58)]),
          const SizedBox(height: 14),
          block(150, r: 16),
        ]);
      },
    );
  }
}

/// Small pill above the dashboard while it is showing the last saved copy.
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0x1AF59E0B),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x66F59E0B)),
        ),
        child: Row(children: [
          const Icon(Icons.cloud_off_outlined, size: 16, color: Color(0xFFF59E0B)),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Connection is slow or offline \u2014 showing your last saved data. Reconnecting\u2026',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85))),
          ),
        ]),
      );
}

/// First-ever load with no network and nothing saved yet: a calm card + retry
/// (the screen keeps retrying on its own every few seconds too).
class _OfflineCard extends StatelessWidget {
  const _OfflineCard({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => InfoCard(
        child: Column(children: [
          Icon(Icons.wifi_off_rounded, size: 34, color: Theme.of(context).hintColor),
          const SizedBox(height: 10),
          const Text('Waiting for connection', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('Your dashboard will load automatically as soon as the network is back.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
          const SizedBox(height: 12),
          OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh, size: 18), label: const Text('Retry')),
        ]),
      );
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 58,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: selected ? kNavy : kNavy.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: selected ? const Color(0xFF6FA8E8) : Colors.transparent, width: 1.6),
            ),
            alignment: Alignment.center,
            child: Text(label, style: TextStyle(color: Colors.white, fontWeight: selected ? FontWeight.w800 : FontWeight.w600, fontSize: 12.5)),
          ),
        ),
      );
}

class _AccountCard extends ConsumerWidget {
  const _AccountCard({required this.account, required this.hidden});
  final CrmAccount account;
  final bool hidden;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = account;
    String v(double x) => hidden ? '••••' : x.toStringAsFixed(2);
    Widget tag(String t, {Color? bg, Color? fg}) => Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: bg ?? Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: (fg ?? Theme.of(context).dividerColor).withValues(alpha: 0.4)),
          ),
          child: Text(t, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
        );
    // Label on top, number large, currency small underneath — each stat gets its own
    // column (flex by content) so values never run into each other.
    Widget stat(String l, String val, {String? unit, int flex = 1}) => Expanded(
          flex: flex,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(l, maxLines: 1, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            ),
            const SizedBox(height: 3),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(val, maxLines: 1, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
            if (unit != null)
              Text(unit, maxLines: 1, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Theme.of(context).hintColor)),
          ]),
        );
    Widget statDivider() => Container(
          width: 1,
          height: 42,
          margin: const EdgeInsets.symmetric(horizontal: 10),
          color: Theme.of(context).dividerColor,
        );
    Widget action(String label, IconData icon, Color color, VoidCallback? onTap) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: FilledButton.icon(
              onPressed: onTap,
              icon: Icon(icon, size: 15),
              label: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
              style: FilledButton.styleFrom(
                backgroundColor: color,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        );
    final live = a.status.toUpperCase() == 'ACTIVE' && a.tradingEnabled;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kNavy.withValues(alpha: 0.55), width: 1.4),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(runSpacing: 6, children: [
          tag(a.isDemo ? 'Demo' : 'Real', bg: const Color(0x1A22C55E), fg: const Color(0xFF178F45)),
          // Order: Real/Demo · account number · plan (Standard) [· status when not live].
          tag(a.login, bg: live ? const Color(0x1A22C55E) : null, fg: live ? const Color(0xFF178F45) : null),
          tag(a.plan),
          if (!live) tag(a.status),
        ]),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            stat('Balance', v(a.balance), flex: 5),
            statDivider(),
            stat('Equity', v(_tradingByLogin(ref, a.login)?.equity ?? a.equity), flex: 5),
            statDivider(),
            stat('Leverage', '1:${a.leverage}', flex: 4),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          if (!a.isDemo) action('Deposit', Icons.add_circle_outline, kNavy, a.depositEnabled ? () => context.push('/deposit') : null),
          if (!a.isDemo) action('Withdraw', Icons.remove_circle_outline, const Color(0xFFD33F3A), a.withdrawEnabled ? () => context.push('/withdraw') : null),
          action('Trade', Icons.show_chart, kNavy, live
              ? () async {
                  // Open this account for trading (credentials come from the CRM), then go to Trade.
                  unawaited(ref.read(tradingSessionProvider.notifier).openOwn(a.login));
                  context.go('/trade');
                }
              : null),
        ]),
      ]),
    );
  }
}
