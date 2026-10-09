import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../widgets/account_panel.dart';

/// MT5-style account history: closed trades (entry → exit, profit) and balance
/// operations (deposits/withdrawals) in one list, with a totals summary footer.
/// MT5 colour convention: profit/credit = blue, loss/debit = red.
enum _Period { today, week, month, threeMonths, year, all, custom }

extension on _Period {
  String get label => switch (this) {
        _Period.today => 'Today',
        _Period.week => 'Last week',
        _Period.month => 'Last month',
        _Period.threeMonths => 'Last 3 months',
        _Period.year => 'Last year',
        _Period.all => 'All time',
        _Period.custom => 'Custom period',
      };
}

/// The selected history window. `custom` uses [_customRangeProvider].
final _periodProvider = StateProvider<_Period>((_) => _Period.all);
final _customRangeProvider = StateProvider<DateTimeRange?>((_) => null);

/// (from, to) for the current selection, evaluated at fetch time so "Today" /
/// "Last week" are relative to now. Null bounds = unbounded.
(DateTime?, DateTime?) _window(_Period p, DateTimeRange? custom) {
  final now = DateTime.now();
  final midnight = DateTime(now.year, now.month, now.day);
  return switch (p) {
    _Period.today => (midnight, null),
    _Period.week => (now.subtract(const Duration(days: 7)), null),
    _Period.month => (DateTime(now.year, now.month - 1, now.day, now.hour, now.minute), null),
    _Period.threeMonths => (DateTime(now.year, now.month - 3, now.day, now.hour, now.minute), null),
    _Period.year => (DateTime(now.year - 1, now.month, now.day, now.hour, now.minute), null),
    _Period.all => (null, null),
    _Period.custom => custom == null
        ? (null, null)
        : (custom.start, DateTime(custom.end.year, custom.end.month, custom.end.day, 23, 59, 59)),
  };
}

/// The last history loaded for each (account, period window), kept OUTSIDE [_historyProvider].
/// A provider that is rebuilt because a trade closed while nobody was listening (History not on
/// screen) loses its previous value, so reopening History would show a loader although the rows were
/// already known. This cache lets the screen show them at once while the refetch runs behind them.
final _historyCacheProvider = StateProvider<Map<String, List<Deal>>>((_) => const {});

String _historyKey(String? account, _Period p, DateTimeRange? custom) =>
    '$account|${p.name}|${p == _Period.custom ? '${custom?.start.millisecondsSinceEpoch}-${custom?.end.millisecondsSinceEpoch}' : ''}';

final _historyProvider = FutureProvider.autoDispose<List<Deal>>((ref) async {
  ref.keepAlive(); // reopen on the last history instantly; trade events refetch it behind the list
  final id = ref.watch(activeAccountIdProvider);
  final period = ref.watch(_periodProvider);
  final custom = ref.watch(_customRangeProvider);
  // New fills / closes are pushed over the socket; refetch when one happens.
  ref.watch(tradeEventEpochProvider);
  if (id == null) return [];
  final api = ref.watch(apiClientProvider);
  final (from, to) = _window(period, custom);
  final data = await api.get('/history/deals', query: {
    'accountId': id,
    if (from != null) 'from': from.toUtc().toIso8601String(),
    if (to != null) 'to': to.toUtc().toIso8601String(),
  }) as List;
  final deals = data.map((e) => Deal.fromJson(e)).toList();
  final cache = ref.read(_historyCacheProvider);
  ref.read(_historyCacheProvider.notifier).state = {...cache, _historyKey(id, period, custom): deals};
  return deals;
});

const _balanceTypes = {'DEPOSIT', 'WITHDRAWAL', 'BONUS', 'DIVIDEND', 'CREDIT', 'BALANCE'};

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  // Which trade's MT5-style detail box is open — at most one, per the app's
  // existing single-panel pattern (e.g. the chart's order ticket).
  String? _expandedId;

  Future<void> _pickPeriod(_Period p) async {
    if (p == _Period.custom) {
      final now = DateTime.now();
      final r = await showDateRangePicker(
        context: context,
        firstDate: DateTime(now.year - 10),
        lastDate: now,
        initialDateRange: ref.read(_customRangeProvider),
      );
      if (r == null || !mounted) return;
      ref.read(_customRangeProvider.notifier).state = r;
    }
    ref.read(_periodProvider.notifier).state = p;
  }

  String _periodText(_Period p, DateTimeRange? custom) {
    if (p == _Period.custom && custom != null) {
      String d(DateTime x) => '${x.year}.${x.month.toString().padLeft(2, '0')}.${x.day.toString().padLeft(2, '0')}';
      return '${d(custom.start)} – ${d(custom.end)}';
    }
    return p.label;
  }

  @override
  Widget build(BuildContext context) {
    final fetched = ref.watch(_historyProvider);
    final period = ref.watch(_periodProvider);
    final customRange = ref.watch(_customRangeProvider);
    // Loading with nothing to show yet, but this account / period was loaded before: show those rows
    // (the refetch lands behind them). A loader is only for a genuine first load, and an error is
    // never replaced by old rows.
    final cached = ref.watch(_historyCacheProvider)[_historyKey(ref.watch(activeAccountIdProvider), period, customRange)];
    final history = (fetched.isLoading && !fetched.hasValue && cached != null) ? AsyncData<List<Deal>>(cached) : fetched;
    final tc = Theme.of(context).extension<TradeColors>()!;

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        // Period filter (MT5's calendar menu). History itself refetches on trade events.
        actions: [
          PopupMenuButton<_Period>(
            tooltip: 'Period',
            icon: const Icon(Icons.calendar_month_outlined),
            initialValue: ref.watch(_periodProvider),
            onSelected: _pickPeriod,
            itemBuilder: (_) => [
              for (final p in _Period.values)
                CheckedPopupMenuItem(value: p, checked: p == ref.watch(_periodProvider), child: Text(p.label)),
            ],
          ),
        ],
      ),
      body: history.when(
        // A refetch (every closed trade triggers one) keeps the current rows on screen and swaps
        // the new list in; the loader is only for the very first load.
        skipLoadingOnReload: true,
        skipLoadingOnRefresh: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (all) {
          final rows = all.where((d) => d.isTrade || _balanceTypes.contains(d.type)).toList();
          if (rows.isEmpty) {
            return Center(
                child: Text(period == _Period.all ? 'No history yet.' : 'No history for this period.',
                    style: TextStyle(color: Theme.of(context).hintColor)));
          }

          double deposit = 0, withdrawal = 0, profit = 0, swap = 0, commission = 0;
          for (final d in all) {
            if (d.isTrade) {
              profit += d.profit;
              swap += d.swap;
              commission += d.commission;
            } else if (d.type == 'WITHDRAWAL') {
              withdrawal += d.amount;
            } else if (_balanceTypes.contains(d.type)) {
              deposit += d.amount;
            }
          }
          final balance = all.isNotEmpty ? all.first.balanceAfter : 0;

          final suffix = ref.watch(clientSuffixProvider);
          return ListView(children: [
            Container(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(_periodText(period, customRange),
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Theme.of(context).hintColor)),
            ),
            for (final d in rows)
              _HistoryRow(
                d: d,
                tc: tc,
                suffix: suffix,
                expanded: d.isTrade && _expandedId == d.id,
                onTap: d.isTrade ? () => setState(() => _expandedId = _expandedId == d.id ? null : d.id) : null,
              ),
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Column(children: [
                _sumRow(context, 'Deposit', mt5Money(deposit), tc.up),
                _sumRow(context, 'Withdrawal', mt5Money(withdrawal), withdrawal < 0 ? tc.down : null),
                _sumRow(context, 'Profit', mt5Money(profit), profit >= 0 ? tc.up : tc.down),
                _sumRow(context, 'Swap', mt5Money(swap), null),
                _sumRow(context, 'Commission', mt5Money(commission), commission < 0 ? tc.down : null),
                const SizedBox(height: 4),
                _sumRow(context, 'Balance', mt5Money(balance), null, bold: true),
              ]),
            ),
          ]);
        },
      ),
    );
  }

  Widget _sumRow(BuildContext context, String k, String v, Color? color, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          // Same type as the Trade screen's account summary.
          Text(k, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, fontSize: 16, height: 1.2)),
          Text(v,
              style: TextStyle(
                  fontSize: 16,
                  height: 1.2,
                  fontWeight: FontWeight.w800,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
      );
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.d, required this.tc, required this.suffix, this.expanded = false, this.onTap});
  final Deal d;
  final String suffix;
  final TradeColors tc;

  /// Whether this trade's MT5-style detail box is currently open.
  final bool expanded;

  /// Toggles [expanded] for this row. Null for non-trade (balance) rows,
  /// which aren't expandable.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final faint = Theme.of(context).hintColor;
    final ts = dateTime(d.createdAt);

    if (d.isTrade) {
      final side = (d.side ?? '').toLowerCase();
      final pl = d.profit;
      final entryExit =
          '${d.openPrice != null ? price(d.openPrice!, d.digits) : '—'} → ${d.price != null ? price(d.price!, d.digits) : '—'}';
      return InkWell(
        onTap: onTap,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(text: d.symbol == null ? '—' : symbolDisplay(d.symbol!, suffix), style: const TextStyle(fontWeight: FontWeight.w800)),
                      const TextSpan(text: ' '),
                      TextSpan(text: '$side ${d.volume?.toStringAsFixed(2) ?? ''}', style: TextStyle(color: side == 'buy' ? tc.up : tc.down, fontWeight: FontWeight.w600)),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16),
                  ),
                  Text(entryExit, style: TextStyle(fontSize: 14, color: faint, fontFeatures: const [FontFeature.tabularFigures()])),
                ]),
              ),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(mt5Money(pl), style: TextStyle(fontSize: 14, color: pl >= 0 ? tc.up : tc.down, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
                Text(ts, style: TextStyle(fontSize: 12.5, color: faint, fontFeatures: const [FontFeature.tabularFigures()])),
              ]),
            ]),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: _DealDetails(d: d),
            crossFadeState: expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 160),
            sizeCurve: Curves.easeInOut,
          ),
        ]),
      );
    }

    final amt = d.amount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Balance', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            Text(d.comment ?? d.type, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: faint)),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(mt5Money(amt), style: TextStyle(fontSize: 14, color: amt >= 0 ? tc.up : tc.down, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
          Text(ts, style: TextStyle(fontSize: 12.5, color: faint, fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
      ]),
    );
  }
}

/// MT5-style expanded trade detail: a compact two-column box —
/// ticket/open time, S-L/swap, T-P/commission — plus a comment line only when
/// the API actually returned one. Every value comes straight off [Deal];
/// nothing here is invented when the backend didn't provide it.
class _DealDetails extends StatelessWidget {
  const _DealDetails({required this.d});
  final Deal d;

  /// The real position/deal id, shortened for display the same way the rest
  /// of the app shortens ids for on-screen tickets (never a fabricated number).
  String _ticket() {
    final raw = d.ticket ?? d.positionId ?? d.id;
    final compact = raw.replaceAll('-', '');
    return '#${(compact.length > 8 ? compact.substring(0, 8) : compact).toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labelStyle = TextStyle(fontSize: 11, color: Theme.of(context).hintColor, fontWeight: FontWeight.w600);
    final valueStyle = TextStyle(fontSize: 12, color: cs.onSurface, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]);

    // Fixed-width columns (not two Expanded halves) so a value sits right next
    // to its own label instead of being stretched across half the box, while
    // the second label/value pair still lines up the same way on every row.
    const labelW = 48.0, valueW = 78.0, label2W = 84.0;
    Widget line(String l1, String v1, String l2, String v2, {bool boldV1 = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(children: [
            SizedBox(width: labelW, child: Text(l1, style: labelStyle, maxLines: 1, overflow: TextOverflow.ellipsis)),
            SizedBox(
              width: valueW,
              child: Text(v1,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: boldV1 ? valueStyle.copyWith(fontWeight: FontWeight.w800) : valueStyle),
            ),
            SizedBox(width: label2W, child: Text(l2, style: labelStyle, maxLines: 1, overflow: TextOverflow.ellipsis)),
            Expanded(child: Text(v2, maxLines: 1, overflow: TextOverflow.ellipsis, style: valueStyle)),
          ]),
        );

    final sl = d.slPrice != null ? price(d.slPrice!, d.digits) : '—';
    final tp = d.tpPrice != null ? price(d.tpPrice!, d.digits) : '—';
    final open = d.openedAt != null ? dateTime(d.openedAt!) : '—';
    final comment = _displayComment(d.comment);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        // Ticket starts at the far left (same edge as "S / L:"); "Open:" keeps the
        // same column as Swap / Commission below.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(children: [
            SizedBox(
              width: labelW + valueW,
              child: Text(_ticket(), maxLines: 1, overflow: TextOverflow.ellipsis, style: valueStyle.copyWith(fontWeight: FontWeight.w800)),
            ),
            SizedBox(width: label2W, child: Text('Open:', style: labelStyle, maxLines: 1, overflow: TextOverflow.ellipsis)),
            Expanded(child: Text(open, maxLines: 1, overflow: TextOverflow.ellipsis, style: valueStyle)),
          ]),
        ),
        line('S / L:', sl, 'Swap:', money(d.swap)),
        line('T / P:', tp, 'Commission:', money(d.commission)),
        if (comment != null) ...[
          const SizedBox(height: 2),
          Text(comment, style: labelStyle.copyWith(fontStyle: FontStyle.italic)),
        ],
      ]),
    );
  }

  /// The engine writes machine-readable execution metadata (a JSON blob —
  /// fill price, trigger, exec kind, etc.) into the same `comment` field a
  /// human-authored note would use. Only the latter belongs in this MT5-style
  /// detail box, so anything that looks like serialized data is suppressed.
  static String? _displayComment(String? raw) {
    final c = raw?.trim() ?? '';
    if (c.isEmpty) return null;
    if (c.startsWith('{') || c.startsWith('[')) return null;
    return c;
  }
}
