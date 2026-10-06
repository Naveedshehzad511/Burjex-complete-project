import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../nav.dart';
import '../services/sound_service.dart';
import '../state/pending_orders.dart';
import '../session/sessions.dart';
import '../widgets/account_panel.dart';
import '../widgets/manage_accounts.dart';

/// MT5-style account summary + open positions. Header shows floating P/L (blue
/// in profit, red in loss); rows show Balance / Equity / Credit / Margin / Free
/// margin; an accounts strip switches the active account; open trades list below
/// is sortable (newest / oldest / by symbol) and scrolls for long lists.
enum _Sort { newest, oldest, symbol }

class TradeScreen extends ConsumerStatefulWidget {
  const TradeScreen({super.key, this.symbol});
  final String? symbol;
  @override
  ConsumerState<TradeScreen> createState() => _TradeScreenState();
}

class _TradeScreenState extends ConsumerState<TradeScreen> {
  _Sort _sort = _Sort.newest;

  @override
  Widget build(BuildContext context) {
    final tc = Theme.of(context).extension<TradeColors>()!;
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const <Account>[];
    final liveAcc = ref.watch(liveAccountProvider);
    final id = ref.watch(activeAccountIdProvider);
    final positions = ref.watch(openPositionsProvider);
    final livePL = ref.watch(livePositionProvider);
    final quotes = ref.watch(quotesProvider);
    final symbols = ref.watch(symbolsProvider).valueOrNull ?? const <TradeSymbol>[];
    final api = ref.read(apiClientProvider);
    final readonly = ref.watch(tradingSessionProvider.select((t) => t.readonly));
    final orders = ref.watch(pendingOrdersProvider).valueOrNull ?? const <PendingOrder>[];

    Account? base;
    for (final a in accounts) {
      if (a.id == id) base = a;
    }
    final acc = (id != null ? liveAcc[id] : null) ?? base;

    // Derive the money figures from the ACTUAL open positions the user sees, so
    // the header can never disagree with the trades list (e.g. show floating P/L
    // while "No open trades"). Prefer engine WS P/L; else estimate from live quotes
    // so the row never sticks at 0.00 while the market moves.
    final posList = positions.valueOrNull ?? const <Position>[];
    final balanceV = base?.balance ?? acc?.balance ?? 0;
    final creditV = base?.credit ?? acc?.credit ?? 0;
    double floatingV = 0;
    for (final p in posList) {
      floatingV += resolvePositionPl(p, livePl: livePL, quotes: quotes, symbols: symbols);
    }
    final marginV = posList.isEmpty ? 0.0 : (base?.margin ?? acc?.margin ?? 0);
    final equityV = balanceV + creditV + floatingV;
    final freeMarginV = equityV - marginV;
    final marginLevelV = marginV > 0 ? equityV / marginV * 100 : 0.0;

    Future<void> refresh() async {
      ref.invalidate(openPositionsProvider);
      ref.invalidate(accountsProvider);
    }

    Future<void> close(String pid, {double? volume}) async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await api.post('/positions/$pid/close', volume != null ? {'volume': volume} : {});
        SoundService.instance.tradeClose();
        await refresh();
      } catch (_) {
        SoundService.instance.error();
        messenger.showSnackBar(const SnackBar(content: Text('Close failed')));
      }
    }

    // Partial close: the client chooses how many lots of the open volume to
    // close (stepped by the symbol's lot step, clamped to the open volume).
    void partialClose(Position p) {
      final symbols = ref.read(symbolsProvider).valueOrNull ?? const <TradeSymbol>[];
      final specs = symbols.where((s) => s.symbol == p.symbol);
      final spec = specs.isEmpty ? null : specs.first;
      final step = spec?.lotStep ?? 0.01;
      final minLot = spec?.minLot ?? 0.01;
      final maxV = p.volume;
      double vol = double.parse((p.volume / 2).clamp(minLot, maxV).toStringAsFixed(2));
      final ctrl = TextEditingController(text: vol.toStringAsFixed(2));
      final display = symbolDisplay(p.symbol, ref.read(clientSuffixProvider));
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
          void setVol(double v) {
            vol = double.parse(v.clamp(minLot, maxV).toStringAsFixed(2));
            ctrl.text = vol.toStringAsFixed(2);
            ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
            setSheet(() {});
          }

          Widget frac(String label, double f) => Expanded(
                child: OutlinedButton(
                  onPressed: () => setVol(double.parse((maxV * f).toStringAsFixed(2))),
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 8)),
                  child: Text(label),
                ),
              );

          return Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(child: Text('Partial close $display', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
              const SizedBox(height: 2),
              Center(child: Text('Open volume ${p.volume.toStringAsFixed(2)}', style: TextStyle(color: Theme.of(ctx).hintColor, fontSize: 12))),
              const SizedBox(height: 14),
              Row(children: [
                Text('Lots to close', style: TextStyle(color: Theme.of(ctx).hintColor)),
                const Spacer(),
                IconButton.filledTonal(onPressed: () => setVol(vol - step), icon: const Icon(Icons.remove)),
                SizedBox(
                  width: 78,
                  child: TextField(
                    controller: ctrl,
                    textAlign: TextAlign.center,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8)),
                    onChanged: (v) {
                      final d = double.tryParse(v);
                      if (d != null) vol = d;
                    },
                    onEditingComplete: () {
                      setVol(vol);
                      FocusScope.of(ctx).unfocus();
                    },
                  ),
                ),
                IconButton.filledTonal(onPressed: () => setVol(vol + step), icon: const Icon(Icons.add)),
              ]),
              const SizedBox(height: 10),
              Row(children: [frac('25%', 0.25), const SizedBox(width: 8), frac('50%', 0.5), const SizedBox(width: 8), frac('75%', 0.75), const SizedBox(width: 8), frac('Max', 1.0)]),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: () {
                  final v = double.parse(vol.clamp(minLot, maxV).toStringAsFixed(2));
                  Navigator.pop(ctx);
                  // Closing the whole open volume is a full close.
                  close(p.id, volume: v >= maxV ? null : v);
                },
                style: FilledButton.styleFrom(backgroundColor: tc.loss, padding: const EdgeInsets.symmetric(vertical: 14)),
                child: Text('Close ${vol.toStringAsFixed(2)} lots'),
              ),
            ]),
          );
        }),
      );
    }

    // Tap a running trade → actions popup: close / modify / add / chart.
    void showActions(Position p) {
      final display = symbolDisplay(p.symbol, ref.read(clientSuffixProvider));
      showModalBottomSheet(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        useRootNavigator: true,
        builder: (ctx) => SafeArea(
          top: false,
          child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Live header: rebuilt from the same tick / P&L streams as the list, so the
            // price and P/L move while the sheet is open (never a snapshot from tap time).
            Consumer(builder: (ctx, ref, _) {
              final q = ref.watch(quotesProvider.select((m) => m[p.symbol]));
              final live = ref.watch(livePositionProvider);
              final syms = ref.watch(symbolsProvider).valueOrNull ?? const <TradeSymbol>[];
              final spec = syms.where((x) => x.symbol == p.symbol);
              final open = spec.isEmpty || isSymbolTradableNow(spec.first, DateTime.now().toUtc());
              // A long closes at the Bid, a short at the Ask (same rule as the P/L resolver).
              final cur = q == null ? null : (p.side == 'BUY' ? q.bid : q.ask);
              final plNow = resolvePositionPl(p, livePl: live, quotes: ref.watch(quotesProvider), symbols: syms);
              final hint = Theme.of(ctx).hintColor;
              final String priceText;
              if (!open) {
                priceText = '@ ${price(p.openPrice, p.digits)} · Market closed';
              } else if (cur == null) {
                priceText = '@ ${price(p.openPrice, p.digits)} → —';
              } else {
                priceText = '@ ${price(p.openPrice, p.digits)} → ${price(cur, p.digits)}';
              }
              return ListTile(
                title: Row(children: [
                  Text(display, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Text('${p.side} ${p.volume.toStringAsFixed(2)}',
                      style: TextStyle(color: p.side == 'BUY' ? tc.buy : tc.sell, fontWeight: FontWeight.w600, fontSize: 13)),
                ]),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(priceText, style: TextStyle(color: hint, fontFeatures: const [FontFeature.tabularFigures()])),
                  // MT5's "Δ = -514 (-0.12%)": move since open, in points and percent, from the live price.
                  if (cur != null && open) ...[
                    Builder(builder: (_) {
                      final dir = p.side == 'BUY' ? 1.0 : -1.0;
                      final move = (cur - p.openPrice) * dir;
                      final pts = (move / math.pow(10, -p.digits)).round();
                      final pc = p.openPrice == 0 ? 0.0 : move / p.openPrice * 100;
                      return Text('Δ = $pts (${pc >= 0 ? '' : '-'}${pc.abs().toStringAsFixed(2)}%)',
                          style: TextStyle(fontSize: 12.5, color: move >= 0 ? tc.profit : tc.loss, fontFeatures: const [FontFeature.tabularFigures()]));
                    }),
                  ],
                ]),
                trailing: Text(mt5Money(plNow),
                    style: TextStyle(color: plNow >= 0 ? tc.profit : tc.loss, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
              );
            }),
            _PositionDetails(p: p),
            const Divider(height: 1),
            if (!readonly) ListTile(
              leading: Icon(Icons.close, color: tc.loss),
              title: Text('Close trade', style: TextStyle(color: tc.loss, fontWeight: FontWeight.w600)),
              trailing: Consumer(builder: (ctx, ref, _) {
                final plNow = resolvePositionPl(p,
                    livePl: ref.watch(livePositionProvider),
                    quotes: ref.watch(quotesProvider),
                    symbols: ref.watch(symbolsProvider).valueOrNull ?? const <TradeSymbol>[]);
                return Text(mt5Money(plNow), style: TextStyle(color: plNow >= 0 ? tc.profit : tc.loss, fontFeatures: const [FontFeature.tabularFigures()]));
              }),
              onTap: () {
                Navigator.pop(ctx);
                close(p.id);
              },
            ),
            ListTile(
              leading: const Icon(Icons.candlestick_chart_outlined),
              title: const Text('Chart'),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(chartSymbolProvider.notifier).set(p.symbol);
                TraderNav.openChart(context, p.symbol);
              },
            ),
            if (!readonly) ListTile(
              leading: const Icon(Icons.add_chart_outlined),
              title: const Text('Add position'),
              subtitle: Text('New order on ${symbolDisplay(p.symbol, ref.read(clientSuffixProvider))}'),
              onTap: () {
                Navigator.pop(ctx);
                TraderNav.openTrade(context, p.symbol);
              },
            ),
            if (!readonly) ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Modify position'),
              subtitle: const Text('Set stop loss / take profit'),
              onTap: () {
                Navigator.pop(ctx);
                _modify(context, ref, p, refresh);
              },
            ),
            if (!readonly) ListTile(
              leading: const Icon(Icons.call_split),
              title: const Text('Partial close'),
              subtitle: const Text('Choose how many lots to close'),
              onTap: () {
                Navigator.pop(ctx);
                partialClose(p);
              },
            ),
            const SizedBox(height: 8),
          ]),
          ),
        ),
      );
    }

    final fpl = floatingV;
    final plColor = fpl >= 0 ? tc.up : tc.down;

    return Scaffold(
      appBar: AppBar(
        // Trade is a tab, not a pushed page, so an implied back arrow would be
        // dead weight on first open.
        automaticallyImplyLeading: false,
        centerTitle: true,
        title: Text('${mt5Money(fpl)} ${acc?.currency ?? 'USD'}',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: plColor, fontFeatures: const [FontFeature.tabularFigures()])),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            // 30 px visual circle inside a 48 px touch target.
            child: Tooltip(
              message: 'Manage another account',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => showManageAccountDialog(context),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      shape: const CircleBorder(),
                      elevation: 1.5,
                      shadowColor: Colors.black26,
                      child: const SizedBox(width: 30, height: 30, child: Icon(Icons.add, size: 18)),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Top-right ⋮ (sort menu) removed; sorting stays at its default (newest first).
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
          // const ActiveAccountBar(),
          // const SizedBox(height: 4),
          // ── Account summary rows ──
          if (acc != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(children: [
                _row('Balance', mt5Money(balanceV)),
                _row('Equity', mt5Money(equityV)),
                if (creditV != 0) _row('Credit', mt5Money(creditV)),
                _row('Margin', mt5Money(marginV)),
                _row('Free Margin', mt5Money(freeMarginV)),
                _row('Margin Level (%)', mt5Money(marginLevelV)),
              ]),
            ),
          const SizedBox(height: 6),
          // ── Positions ──
          Container(
            color: _barColor(context),
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            constraints: const BoxConstraints(minHeight: 34),
            child: Row(children: [
              Text('Positions', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85))),
              const Spacer(),
              // MT5's "..." on the Positions bar - Close all lives in this menu.
              // valueOrNull keeps the last list while a background refetch runs, so the
              // menu never blinks away.
              Builder(builder: (_) {
                final l = positions.valueOrNull;
                if (l == null || l.isEmpty || readonly) return const SizedBox.shrink();
                return PopupMenuButton<String>(
                        tooltip: 'Positions menu',
                        icon: Icon(Icons.more_horiz, color: Theme.of(context).hintColor),
                        onSelected: (v) async {
                          if (v == 'closeAll' && id != null) {
                            await api.post('/accounts/$id/close-all', {});
                            SoundService.instance.tradeClose();
                            await refresh();
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'closeAll', child: Text('Close all positions', style: TextStyle(color: tc.loss, fontWeight: FontWeight.w600))),
                        ],
                      );
              }),
            ]),
          ),
          // Background refetches (30s ticker, socket events, a Close All burst) must never blank
          // the list: whenever there is a list, show it, whatever the reload state is. The
          // loader is only for the very first load, when there is nothing to show yet.
          (positions.hasValue ? AsyncData<List<Position>>(positions.requireValue) : positions).when(
            skipLoadingOnReload: true,
            skipLoadingOnRefresh: true,
            loading: () => const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
            error: (e, _) => Padding(padding: const EdgeInsets.all(24), child: Center(child: Text('$e'))),
            data: (list) {
              if (list.isEmpty) {
                return Padding(
                    padding: const EdgeInsets.all(40),
                    child: Center(child: Text('No open positions.', style: TextStyle(color: Theme.of(context).hintColor))));
              }
              final sorted = [...list];
              switch (_sort) {
                case _Sort.newest:
                  sorted.sort((a, b) => b.openedAt.compareTo(a.openedAt));
                  break;
                case _Sort.oldest:
                  sorted.sort((a, b) => a.openedAt.compareTo(b.openedAt));
                  break;
                case _Sort.symbol:
                  sorted.sort((a, b) => a.symbol.compareTo(b.symbol));
                  break;
              }
              final suffix = ref.watch(clientSuffixProvider);
              return Column(children: [
                for (final p in sorted)
                  _TradeTile(
                    p: p,
                    display: symbolDisplay(p.symbol, suffix),
                    pl: resolvePositionPl(p, livePl: livePL, quotes: quotes, symbols: symbols),
                    tc: tc,
                    cur: quotes[p.symbol] == null ? null : (p.side == 'BUY' ? quotes[p.symbol]!.bid : quotes[p.symbol]!.ask),
                    onTap: () => showActions(p),
                  ),
              ]);
            },
          ),
          // ── Orders (pending) — live from the same store that draws the chart lines ──
          _ordersSection(context, orders, symbols, tc, readonly),
          const SizedBox(height: 24),
        ]))),
      ),
    );
  }

  int _digitsFor(PendingOrder o, List<TradeSymbol> symbols) {
    if (o.digits != null) return o.digits!;
    for (final s in symbols) {
      if (s.symbol == o.symbol) return s.digits;
    }
    return 5;
  }

  Future<void> _deleteOrders(String label, bool Function(PendingOrder)? test, int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: Text('Cancel $count pending order${count == 1 ? '' : 's'}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final done = await ref.read(pendingOrdersProvider.notifier).cancelWhere(test);
    if (!mounted) return;
    if (done > 0) SoundService.instance.tradeClose();
    if (done < count) {
      SoundService.instance.error();
      messenger.showSnackBar(SnackBar(content: Text('Cancelled $done of $count orders')));
    }
  }

  Widget _ordersSection(BuildContext context, List<PendingOrder> orders, List<TradeSymbol> symbols, TradeColors tc, bool readonly) {
    if (orders.isEmpty) return const SizedBox.shrink();
    final hint = Theme.of(context).hintColor;
    final suffix = ref.watch(clientSuffixProvider);
    final sorted = [...orders]..sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
    final limits = orders.where((o) => o.isLimitKind).length;
    final stops = orders.where((o) => o.isStopKind).length;
    final stopLimits = orders.where((o) => o.isStopLimit).length;
    const tab = [FontFeature.tabularFigures()];

    PopupMenuItem<String> item(String v, String text, int n) =>
        PopupMenuItem(value: v, enabled: n > 0, child: Text(text, style: TextStyle(color: n > 0 ? tc.loss : null, fontWeight: FontWeight.w600)));

    void showOrder(PendingOrder o) {
      final d = _digitsFor(o, symbols);
      final display = symbolDisplay(o.symbol, suffix);
      showModalBottomSheet(
        context: context,
        showDragHandle: true,
        useRootNavigator: true,
        builder: (ctx) => SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              title: Row(children: [
                Text(display, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                Text(o.label, style: TextStyle(color: o.side == 'BUY' ? tc.buy : tc.sell, fontWeight: FontWeight.w600, fontSize: 13)),
              ]),
              subtitle: Text([
                o.isStopLimit ? 'Stop ${price(o.entry, d)} · Limit ${o.limit != null ? price(o.limit!, d) : '—'}' : 'Price ${price(o.entry, d)}',
                'SL ${o.sl != null ? price(o.sl!, d) : '—'} · TP ${o.tp != null ? price(o.tp!, d) : '—'}',
                if (o.createdAt != null) 'Placed ${dateTime(o.createdAt!)}',
                if (o.expiresAt != null) 'Expires ${dateTime(o.expiresAt!)}' else if (o.timeInForce != null) o.timeInForce!,
                'Status ${o.status.toLowerCase()}',
              ].join('\n')),
              isThreeLine: true,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.candlestick_chart_outlined),
              title: Text(readonly ? 'Chart' : 'Chart / modify'),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(chartSymbolProvider.notifier).set(o.symbol);
                TraderNav.openChart(context, o.symbol);
              },
            ),
            if (!readonly)
              ListTile(
                leading: Icon(Icons.delete_outline, color: tc.loss),
                title: Text('Delete order', style: TextStyle(color: tc.loss, fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(ctx);
                  ref.read(pendingOrdersProvider.notifier).cancelWhere((x) => x.id == o.id).then((n) {
                    if (n > 0) SoundService.instance.orderCancelled();
                  });
                },
              ),
          ]),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        color: _barColor(context),
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
        constraints: const BoxConstraints(minHeight: 34),
        child: Row(children: [
          Text('Orders', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85))),
          const Spacer(),
          if (!readonly)
            PopupMenuButton<String>(
              tooltip: 'Orders menu',
              icon: Icon(Icons.more_horiz, color: hint),
              onSelected: (v) {
                switch (v) {
                  case 'all':
                    _deleteOrders('Delete all orders', null, orders.length);
                  case 'limit':
                    _deleteOrders('Delete limit orders', (o) => o.isLimitKind, limits);
                  case 'stop':
                    _deleteOrders('Delete stop orders', (o) => o.isStopKind, stops);
                  case 'stopLimit':
                    _deleteOrders('Delete stop limit orders', (o) => o.isStopLimit, stopLimits);
                }
              },
              itemBuilder: (_) => [
                item('all', 'Delete all orders', orders.length),
                item('limit', 'Delete limit orders', limits),
                item('stop', 'Delete stop orders', stops),
                item('stopLimit', 'Delete stop limit orders', stopLimits),
              ],
            ),
        ]),
      ),
      for (final o in sorted)
        InkWell(
          onTap: () => showOrder(o),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(text: symbolDisplay(o.symbol, suffix), style: const TextStyle(fontWeight: FontWeight.w800)),
                      const TextSpan(text: ' '),
                      TextSpan(text: o.kindLabel, style: TextStyle(color: o.side == 'BUY' ? tc.buy : tc.sell, fontWeight: FontWeight.w600)),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16),
                  ),
                  Text(
                    '${o.volume.toStringAsFixed(2)} / 0 at ${price(o.entry, _digitsFor(o, symbols))}'
                    '${o.isStopLimit && o.limit != null ? ' (limit ${price(o.limit!, _digitsFor(o, symbols))})' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: hint, fontFeatures: tab),
                  ),
                  if (o.sl != null || o.tp != null)
                    Text('SL ${o.sl != null ? price(o.sl!, _digitsFor(o, symbols)) : '—'} · TP ${o.tp != null ? price(o.tp!, _digitsFor(o, symbols)) : '—'}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: hint, fontFeatures: tab)),
                ]),
              ),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('placed', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Theme.of(context).colorScheme.primary)),
              ]),
            ]),
          ),
        ),
    ]);
  }

  Color _barColor(BuildContext context) => Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06);

  // MT5 summary row: label left, bold value right-aligned, no leader dots, compact.
  Widget _row(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Expanded(child: Text('$k:', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, height: 1.2, fontWeight: FontWeight.w600))),
          const SizedBox(width: 8),
          Text(v, style: TextStyle(fontSize: 16, height: 1.2, fontWeight: FontWeight.w800, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
      );

  Future<void> _modify(BuildContext context, WidgetRef ref, Position p, Future<void> Function() refresh) async {
    final sl = TextEditingController(text: p.slPrice?.toString() ?? '');
    final tp = TextEditingController(text: p.tpPrice?.toString() ?? '');
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 20, right: 20, top: 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Modify ${symbolDisplay(p.symbol, ref.read(clientSuffixProvider))}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          TextField(controller: sl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Stop loss')),
          const SizedBox(height: 10),
          TextField(controller: tp, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Take profit')),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () async {
                try {
                  await ref.read(apiClientProvider).patch('/positions/${p.id}', {
                    'slPrice': double.tryParse(sl.text),
                    'tpPrice': double.tryParse(tp.text),
                  });
                  SoundService.instance.orderModified();
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (_) {
                  // Server is authoritative — reconcile even when PATCH is rejected.
                }
                await refresh();
              },
              child: const Text('Save SL/TP'),
            ),
          ),
          const SizedBox(height: 20),
        ]),
      ),
    );
  }
}

/// MT5-style expanded trade details, shown in the position sheet: ticket and open time,
/// S/L + swap, T/P + commission, then whatever else the positions API returned for this
/// trade (close time, margin, a human comment). A missing S/L or T/P shows "-"; fields the
/// API did not return are simply omitted. Internal engine fields (book, LP cover, execution
/// claims) are deliberately never shown to the client.
class _PositionDetails extends StatelessWidget {
  const _PositionDetails({required this.p});
  final Position p;

  String _ticket() {
    final compact = p.id.replaceAll('-', '');
    return '#${(compact.length > 8 ? compact.substring(0, 8) : compact).toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final label = TextStyle(fontSize: 13, color: hint);
    final value = TextStyle(fontSize: 13, color: onSurface, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]);

    // One two-column grid for every row (left 4 : right 6) so the right-hand labels
    // (Open / Swap / Commission) all start at the same x and their values end at the same
    // right edge — and the wider right column leaves room for "Commission:" + its value.
    Widget row(Widget left, String l2, String v2) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(children: [
            Expanded(flex: 4, child: left),
            const SizedBox(width: 12),
            Expanded(
              flex: 6,
              child: Row(children: [
                Text(l2, style: label),
                const SizedBox(width: 6),
                Expanded(child: Text(v2, style: value, textAlign: TextAlign.end, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ]),
            ),
          ]),
        );
    Widget pair(String l1, String v1, String l2, String v2) => row(
          Row(children: [Text(l1, style: label), const SizedBox(width: 6), Expanded(child: Text(v1, style: value, maxLines: 1, overflow: TextOverflow.ellipsis))]),
          l2,
          v2,
        );

    final comment = p.comment?.trim() ?? '';
    final showComment = comment.isNotEmpty && !comment.startsWith('{') && !comment.startsWith('[');
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        row(Text(_ticket(), style: value.copyWith(fontWeight: FontWeight.w800)), 'Open:', dateTime(p.openedAt)),
        pair('S/L:', p.slPrice != null ? price(p.slPrice!, p.digits) : '-', 'Swap:', mt5Money(p.swap)),
        pair('T/P:', p.tpPrice != null ? price(p.tpPrice!, p.digits) : '-', 'Commission:', mt5Money(p.commission)),
        // Margin is hidden for now; to restore, replace the Closed row below with:
        // if (p.marginUsed > 0 || p.closedAt != null)
        //   if (p.closedAt != null)
        //     pair(p.marginUsed > 0 ? 'Margin:' : '', p.marginUsed > 0 ? mt5Money(p.marginUsed) : '', 'Closed:', dateTime(p.closedAt!))
        //   else
        //     pair('Margin:', mt5Money(p.marginUsed), '', ''),
        if (p.closedAt != null) pair('', '', 'Closed:', dateTime(p.closedAt!)),
        if (showComment) Padding(padding: const EdgeInsets.only(top: 2), child: Text(comment, style: label.copyWith(fontStyle: FontStyle.italic))),
      ]),
    );
  }
}

class _TradeTile extends StatelessWidget {
  const _TradeTile({required this.p, required this.display, required this.pl, required this.tc, required this.onTap, this.cur});
  /// Live closing price (bid for a buy, ask for a sell), when a quote is available.
  final double? cur;
  final Position p;
  final String display;
  final double pl;
  final TradeColors tc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final plColor = pl >= 0 ? tc.profit : tc.loss;
    final hint = Theme.of(context).hintColor;
    const tab = [FontFeature.tabularFigures()];
    // MT5 position row: "SYMBOL, side vol" over the open price, P/L on the right.
    // Fonts are compact and everything shrinks/ellipsizes instead of overflowing.
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: display, style: const TextStyle(fontWeight: FontWeight.w800)),
                  // MT5: "XAUUSD.s buy 0.3" — a space, not a comma.
                  const TextSpan(text: ' '),
                  TextSpan(
                      text: '${p.side.toLowerCase()} ${p.volume.toStringAsFixed(2)}',
                      style: TextStyle(color: p.side == 'BUY' ? tc.buy : tc.sell, fontWeight: FontWeight.w600)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16),
              ),
              Text(cur != null ? '${price(p.openPrice, p.digits)} → ${price(cur!, p.digits)}' : price(p.openPrice, p.digits),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: hint, fontFeatures: tab)),
            ]),
          ),
          const SizedBox(width: 8),
          // MT5: a larger, medium-weight figure, and no chevron.
          Text(mt5Money(pl), style: TextStyle(fontSize: 14, color: plColor, fontWeight: FontWeight.w600, fontFeatures: tab)),
        ]),
      ),
    );
  }
}
