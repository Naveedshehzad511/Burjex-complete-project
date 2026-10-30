import 'dart:async';

import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../crm/crm.dart';
import '../main.dart' show kNavy;
import '../session/sessions.dart';
import '../state/live_figures.dart';
import '../state/movers.dart';
import '../widgets/account_actions.dart';
import '../widgets/economic_calendar.dart';
import '../widgets/manage_accounts.dart';
import '../widgets/market_movers.dart';
import '../widgets/market_news.dart';
import '../widgets/portal_drawer.dart';
import '../state/crypto_policy.dart';
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
  Timer? _eventRefresh;

  /// The account each category's slider is on (kept while the 12 s refresh rebuilds the page).
  final _selected = <bool, String?>{};

  @override
  void initState() {
    super.initState();
    _restorePrefs();
    // The CRM ledger has no push channel; a light refresh keeps balances current. Until KYC is approved the
    // profile is re-read on the same beat, so an approval / rejection by the administrator shows on this
    // screen without leaving it (it used to wait for the app to come back to the foreground).
    _poll = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!mounted) return;
      ref.invalidate(crmDashboardProvider);
      _refreshKycIfPending();
      ref.read(moversProvider.notifier).refresh(); // Top Gainers / Losers ride the same beat
    });
    // Home is rebuilt every time the user comes back from another tab, and its dashboard is kept from before: what is
    // shown is as old as the last time Home was on screen. Fetch once on arrival. Silent: the dashboard below keeps
    // showing the old figures while the new ones load. Skipped on the very first load (a fetch is already running).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final d = ref.read(crmDashboardProvider);
      if (d.hasValue && !d.isLoading) ref.invalidate(crmDashboardProvider);
    });
  }

  /// A trade opened, closed or filled: the balance changed. Fetch the dashboard once, shortly after the last event of a
  /// burst (Close All is many events), in the background - no loader, the figures simply change when it answers.
  void _refreshSoon() {
    _eventRefresh?.cancel();
    _eventRefresh = Timer(const Duration(milliseconds: 800), () {
      if (mounted) ref.invalidate(crmDashboardProvider);
    });
  }

  void _refreshKycIfPending() {
    final profile = ref.read(crmProfileProvider).valueOrNull;
    if (profile == null || !profile.kycApproved) refreshCrmProfile(ref);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _eventRefresh?.cancel();
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

  /// Choose any account, Real or Demo, from one list: the category and the slider both follow it.
  Future<void> _pickAccount(List<CrmAccount> all) async {
    final picked = await showModalBottomSheet<CrmAccount>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => Consumer(builder: (ctx, ref, _) {
        // The balances follow the dashboard while the sheet is open (a trade, the 12 s beat), not the list captured at
        // the moment it was opened.
        final current = ref.watch(crmDashboardProvider).valueOrNull?.accounts ?? all;
        final groups = [for (final demo in const [false, true]) (demo, current.where((a) => a.isDemo == demo).toList())];
        return SafeArea(
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
            for (final (demo, list) in groups)
              if (list.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                  child: Text(demo ? 'Demo' : 'Real', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
                ),
                for (final a in list)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    title: Text('${a.plan} #${a.login}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: a.platform.isEmpty ? null : Text(a.platform),
                    trailing: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(_hidden ? '••••' : '${_net(a.balance, _pendingOf(ref, a)).toStringAsFixed(2)} ${a.currency}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      if (!_hidden && _pendingOf(ref, a) > 0)
                        Text('Pending withdrawal ${_pendingOf(ref, a).toStringAsFixed(2)}', style: TextStyle(fontSize: 11, color: Theme.of(ctx).hintColor)),
                    ]),
                    selected: a.isDemo == _demo && a.login == (_selected[_demo] ?? list.first.login),
                    onTap: () => Navigator.pop(ctx, a),
                  ),
              ],
          ]),
        );
      }),
    );
    if (picked == null || !mounted) return;
    _selected[picked.isDemo] = picked.login;
    if (picked.isDemo != _demo) {
      await _setDemo(picked.isDemo);
    } else {
      setState(() {});
    }
  }

  Future<void> _toggleHidden() async {
    setState(() => _hidden = !_hidden);
    (await SharedPreferences.getInstance()).setBool(_kHideBalanceKey, _hidden);
  }

  @override
  Widget build(BuildContext context) {
    final dash = ref.watch(crmDashboardProvider);
    // Opens, fills, closes (manual, SL / TP, other devices) and partial closes all bump this one counter.
    ref.listen<int>(tradeEventEpochProvider, (_, __) => _refreshSoon());
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
            _refreshKycIfPending();
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
                    equity: allLive ? known.fold<double>(0, (s, t) => s + t.liveEquity) : base.equity,
                    openPnl: allLive ? known.fold<double>(0, (s, t) => s + t.floatingPL) : base.openPnl,
                    withdrawable: base.withdrawable,
                    margin: known.fold<double>(0, (s, t) => s + t.margin),
                    pendingWithdraw: allLive ? known.fold<double>(0, (s, t) => s + t.reservedWithdraw) : base.pendingWithdraw,
                  );
                  // The active account's floating P/L moves with the market (as on the Trade tab), not with the
                  // engine's 5 s snapshot: it is folded in by the stats row itself, so only those three figures
                  // rebuild on a price change, not this whole page.
                  // Whether the other accounts are known to the trading side or not (the CRM lists every account, the
                  // trading session may hold just the one in use), the active account is carried to the tick: what
                  // the card holds for it now is swapped for its live figures.
                  final activeId = ref.watch(activeAccountIdProvider);
                  _LiveSwap? liveSwap;
                  for (var i = 0; i < accounts.length; i++) {
                    final t = tAccts[i];
                    if (t == null || t.id != activeId) continue;
                    liveSwap = allLive
                        ? _LiveSwap(t.id, t.liveEquity, t.floatingPL) // the snapshot is what the sums hold
                        : _LiveSwap(t.id, accounts[i].equity, accounts[i].equity - accounts[i].balance); // the CRM row is
                    break;
                  }
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (ref.watch(crmDashboardOfflineProvider)) const _OfflineBanner(),
                    _PerformanceCard(demo: _demo, metrics: metrics, hidden: _hidden, onToggleHidden: _toggleHidden, liveSwap: liveSwap),
                    if (profile != null && !profile.kycApproved) ...[const SizedBox(height: 10), _KycNotice(profile.kycStatus)],
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
                      // Real / Demo each slide through their own accounts; the card on screen is the selected one.
                      _AccountSlider(
                        key: ValueKey(_demo),
                        accounts: accounts,
                        selected: _selected[_demo],
                        onSelected: (login) => _selected[_demo] = login,
                        cardBuilder: (a) => _AccountCard(
                          account: a,
                          hidden: _hidden,
                          onPick: d.accounts.length > 1 ? () => _pickAccount(d.accounts) : null,
                        ),
                      ),
                  ]);
                },
              ),
              // Market sections load on their own: a slow or failed dashboard never hides them, and they never
              // wait for it. (Order: account list, Top Gainers, Top Losers, Major News / Events calendar, Market news.)
              const MoversSection(side: MoversSide.gainers),
              const MoversSection(side: MoversSide.losers),
              const EconomicCalendarSection(),
              const MarketNewsSection(),
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
/// Held by the engine for pending withdrawal requests: the trading side's live figure when it knows the account, else
/// the CRM's. Still part of the balance, but not available.
double _pendingOf(WidgetRef ref, CrmAccount a) => _tradingByLogin(ref, a.login)?.reservedWithdraw ?? a.pendingWithdraw;

/// A balance less what is held for pending withdrawals (never below zero).
double _net(double balance, double held) => balance > held ? balance - held : 0.0;

Account? _tradingByLogin(WidgetRef ref, String login) {
  final accts = ref.watch(accountsProvider).valueOrNull ?? const <Account>[];
  final live = ref.watch(liveAccountProvider);
  for (final t in accts) {
    if (t.login == login) return live[t.id] ?? t;
  }
  return null;
}

/// Equity of one account card. The active account's is the live one (balance + credit + floating P/L as on the Trade
/// tab); any other account's is its last engine snapshot, or the CRM's figure when the trading side has none.
double _accountEquity(WidgetRef ref, CrmAccount a) {
  final t = _tradingByLogin(ref, a.login);
  if (t == null) return a.equity;
  if (t.id != ref.watch(activeAccountIdProvider)) return t.liveEquity; // only the active account follows the ticks
  final f = ref.watch(activeLiveFiguresProvider);
  return f != null && f.accountId == t.id ? f.equity : t.liveEquity;
}

/// The single large account card: mode, Open Account, balance (+ eye), performance.
class _PerformanceCard extends StatelessWidget {
  const _PerformanceCard({required this.demo, required this.metrics, required this.hidden, required this.onToggleHidden, this.liveSwap});
  final bool demo;
  final CrmMetrics metrics;
  final bool hidden;
  final VoidCallback onToggleHidden;

  /// The account (one of those summed in [metrics]) whose figures are carried to the latest tick.
  final _LiveSwap? liveSwap;

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
              child: Text(_money(_net(metrics.balance, metrics.pendingWithdraw)), style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1.1)),
            ),
          ),
          const SizedBox(width: 8),
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('USD', style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 15))),
        ]),
        if (metrics.pendingWithdraw > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('Pending withdrawal ${_money(metrics.pendingWithdraw)}', style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 12.5)),
          ),
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
        _LiveStatsRow(metrics: metrics, hidden: hidden, liveSwap: liveSwap),
      ]),
    );
  }
}

/// What the card's sums currently hold for the active account, to be replaced by its live figures.
class _LiveSwap {
  const _LiveSwap(this.accountId, this.equity, this.floating);
  final String accountId;
  final double equity, floating;
}

/// Equity / Margin / Open PnL of the card. The summed figures come from the engine's snapshots; for the active
/// account the floating P/L is replaced by the live one (the same figure the Trade tab shows), so equity and open PnL
/// move with every price change and match the Trade tab. Only this row watches the live figures.
class _LiveStatsRow extends ConsumerWidget {
  const _LiveStatsRow({required this.metrics, required this.hidden, required this.liveSwap});
  final CrmMetrics metrics;
  final bool hidden;
  final _LiveSwap? liveSwap;

  String _money(double v) => hidden ? '••••••' : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final swap = liveSwap;
    final f = swap == null ? null : ref.watch(activeLiveFiguresProvider);
    final live = f != null && swap != null && f.accountId == swap.accountId;
    // The account's old share of the sums out, its live figures in.
    final equity = live ? metrics.equity - swap.equity + f.equity : metrics.equity;
    final openPnl = live ? metrics.openPnl - swap.floating + f.floating : metrics.openPnl;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _Stat('Equity', _money(equity)),
      _StatDivider(),
      _Stat('Margin', _money(metrics.margin)),
      _StatDivider(),
      _Stat('Open PnL', _money(openPnl)),
    ]);
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
  const _KycNotice(this.status);
  final String status;

  /// What the CRM's KYC status means for the client (PENDING / REJECTED / EXPIRED; anything else is "pending").
  String get _message {
    if (hideFunding) {
      // iPhone / iPad: there are no withdrawals in the app, so they are not what KYC unlocks here.
      switch (status.toUpperCase()) {
        case 'REJECTED':
          return 'KYC was rejected — resubmit your documents.';
        case 'EXPIRED':
          return 'KYC has expired — renew it.';
        default:
          return 'KYC is pending — complete your verification.';
      }
    }
    switch (status.toUpperCase()) {
      case 'REJECTED':
        return 'KYC was rejected — resubmit your documents to unlock withdrawals.';
      case 'EXPIRED':
        return 'KYC has expired — renew it to unlock withdrawals.';
      default:
        return 'KYC is pending — complete it to unlock withdrawals.';
    }
  }

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
              child: Text(_message,
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

/// The accounts of one category as a horizontal swipe slider (one card each, dots under it). Keeps the card the
/// client is on when the list refreshes, and follows [selected] when it is changed from outside (the picker).
class _AccountSlider extends StatefulWidget {
  const _AccountSlider({super.key, required this.accounts, required this.selected, required this.onSelected, required this.cardBuilder});
  final List<CrmAccount> accounts;
  final String? selected;
  final ValueChanged<String> onSelected;
  final Widget Function(CrmAccount) cardBuilder;

  @override
  State<_AccountSlider> createState() => _AccountSliderState();
}

class _AccountSliderState extends State<_AccountSlider> {
  late int _i = _indexOf(widget.selected);
  late String _login = widget.accounts[_i].login;
  late final PageController _c = PageController(initialPage: _i);

  int _indexOf(String? login) {
    final i = widget.accounts.indexWhere((a) => a.login == login);
    return i < 0 ? 0 : i;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_AccountSlider old) {
    super.didUpdateWidget(old);
    if (widget.selected != old.selected && widget.selected != _login) {
      // Chosen elsewhere (the account picker): slide to it.
      final to = _indexOf(widget.selected);
      _i = to;
      _login = widget.accounts[to].login;
      if (_c.hasClients) _c.animateToPage(to, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
      return;
    }
    // A refresh: stay on the same account even if the list changed around it.
    final at = widget.accounts.indexWhere((a) => a.login == _login);
    final to = at >= 0 ? at : _i.clamp(0, widget.accounts.length - 1);
    if (to != _i || at < 0) {
      _i = to;
      _login = widget.accounts[to].login;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _c.hasClients) _c.jumpToPage(to);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = widget.accounts;
    final n = accounts.length;
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      // The invisible card gives the slider its height (it follows the text size and the width); the pages fill it.
      Stack(children: [
        Visibility(
          visible: false,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: widget.cardBuilder(accounts[_i.clamp(0, n - 1)]),
        ),
        Positioned.fill(
          child: PageView.builder(
            controller: _c,
            itemCount: n,
            onPageChanged: (i) {
              _login = accounts[i].login;
              widget.onSelected(_login);
              setState(() => _i = i);
            },
            itemBuilder: (_, i) => Padding(
              padding: EdgeInsets.symmetric(horizontal: n > 1 ? 2 : 0),
              child: widget.cardBuilder(accounts[i]),
            ),
          ),
        ),
      ]),
      if (n > 1)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < n; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _i ? 18 : 7,
                height: 7,
                decoration: BoxDecoration(
                  color: i == _i ? kNavy : cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ]),
        ),
    ]);
  }
}

/// One trading account, laid out like the client's reference, compact: account chip + status + Real/Demo, then
/// Balance / Equity / Leverage in one row, then the actions - Deposit (down arrow) and Withdraw (up arrow) on the
/// first row, Manage and Trade on the second. Only values the CRM returns are shown. Amounts follow Home's
/// hide / show button (the card has none of its own).
class _AccountCard extends ConsumerWidget {
  const _AccountCard({required this.account, required this.hidden, this.onPick});
  final CrmAccount account;
  final bool hidden;

  /// Opens the account picker; null when there is only one account (nothing to choose).
  final VoidCallback? onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = account;
    final live = a.status.toUpperCase() == 'ACTIVE' && a.tradingEnabled;
    String v(double x) => hidden ? '••••' : x.toStringAsFixed(2);
    final whiteFaint = Colors.white.withValues(alpha: 0.75);

    // One equal-width third: a small label with its value directly below, thin divider before the 2nd and 3rd.
    // Label and value shrink rather than wrap or clip.
    Widget statColumn(String label, String value, {bool divider = false}) => Expanded(
          child: Container(
            padding: EdgeInsets.only(left: divider ? 10 : 0),
            decoration: divider ? BoxDecoration(border: Border(left: BorderSide(color: Colors.white.withValues(alpha: 0.18)))) : null,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(label, maxLines: 1, style: TextStyle(color: whiteFaint, fontSize: 11.5, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 3),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, maxLines: 1, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800, height: 1.1)),
              ),
            ]),
          ),
        );
    Widget action(String label, IconData icon, VoidCallback? onTap, {required bool primary}) =>
        Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: _CardAction(label: label, icon: icon, onTap: onTap, primary: primary)));
    // "Manage" is the old 3-dot menu (trading password / investor password / leverage) on a button. It is the same
    // button as the others (identical size and style); the menu opens on tap through the wrapper.
    final manage = Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: AccountMenuButton(
          account: a,
          child: const IgnorePointer(child: SizedBox(width: double.infinity, child: _CardAction(label: 'Manage', icon: Icons.tune, onTap: _noop, primary: false))),
        ),
      ),
    );
    final trade = action(
      'Trade',
      Icons.show_chart,
      live
          ? () async {
              // Open this account for trading (credentials come from the CRM), then go to Trade.
              unawaited(ref.read(tradingSessionProvider.notifier).openOwn(a.login));
              context.go('/trade');
            }
          : null,
      primary: true,
    );

    return MediaQuery.withClampedTextScaling(
      // A large system font must not break the card: text may grow a little, not enough to overflow.
      minScaleFactor: 1.0,
      maxScaleFactor: 1.12,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: a.isDemo ? const [Color(0xFF1B2A6B), Color(0xFF14397A), Color(0xFF0B6A8F)] : const [Color(0xFF071A33), kNavy, Color(0xFF0B5FA8)],
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [BoxShadow(color: Color(0x33002D58), blurRadius: 18, offset: Offset(0, 6))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          LayoutBuilder(builder: (context, box) {
            // The green dot says "active"; the words "Account active" only appear on a wide card, so the account
            // chip never has to shrink for them. A blocked account gets its words on their own line below.
            final showWords = live && box.maxWidth >= 400;
            return Row(children: [
              // Chip + status take whatever the Real / Demo badge leaves; the chip keeps its room first.
              Expanded(
                child: Row(children: [
                  Flexible(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: onPick,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(20)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Flexible(
                            child: Text('${a.plan.toUpperCase()} • #${a.login}',
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w800)),
                          ),
                          if (onPick != null) const Icon(Icons.keyboard_arrow_down, size: 18, color: Colors.white),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: live ? const Color(0xFF34D399) : const Color(0xFFF5A524))),
                  if (showWords) ...[
                    const SizedBox(width: 5),
                    Text('Account active', maxLines: 1, style: TextStyle(color: whiteFaint, fontSize: 12, fontWeight: FontWeight.w600)),
                  ],
                ]),
              ),
              const SizedBox(width: 8),
              // Real or Demo, from the account itself.
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
                child: Text(a.isDemo ? 'Demo' : 'Real', maxLines: 1, style: const TextStyle(color: kNavy, fontSize: 13, fontWeight: FontWeight.w800)),
              ),
            ]);
          }),
          // A blocked account says why (the dot above is orange).
          if (!live) ...[
            const SizedBox(height: 6),
            Text(a.status.toUpperCase() == 'ACTIVE' ? 'Trading disabled' : 'Account ${a.status.toLowerCase()}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFF5A524), fontSize: 12, fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 12),
          // Balance, Equity and Leverage: one row, three equal columns, label above value.
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            statColumn('Balance', v(_net(a.balance, _pendingOf(ref, a)))),
            statColumn('Equity', v(_accountEquity(ref, a)), divider: true),
            statColumn('Leverage', '1:${a.leverage}', divider: true),
          ]),
          if (_pendingOf(ref, a) > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Pending withdrawal ${v(_pendingOf(ref, a))}', style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 12)),
            ),
          const SizedBox(height: 12),
          if (!a.isDemo && !hideFunding) ...[
            Row(children: [
              action('Deposit', Icons.arrow_downward, a.depositEnabled ? () => context.push('/deposit?account=${a.login}') : null, primary: true),
              action('Withdraw', Icons.arrow_upward, a.withdrawEnabled ? () => context.push('/withdraw') : null, primary: false),
            ]),
            const SizedBox(height: 8),
            Row(children: [manage, trade]),
          ] else
            Row(children: [manage, trade]),
        ]),
      ),
    );
  }
}

void _noop() {}

/// One action pill of the account card. Same height, shape and type for every action, so they always line up: a
/// primary action is solid white, a secondary one translucent; a disabled one fades instead of disappearing.
class _CardAction extends StatelessWidget {
  const _CardAction({required this.label, required this.icon, required this.onTap, required this.primary});
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final bg = !enabled ? Colors.white.withValues(alpha: 0.12) : (primary ? Colors.white : Colors.white.withValues(alpha: 0.16));
    final fg = !enabled ? Colors.white.withValues(alpha: 0.4) : (primary ? kNavy : Colors.white);
    return Material(
      color: bg,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 42,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 6),
                  Text(label, maxLines: 1, style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 14)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
