import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import '../nav.dart';
import '../services/sound_service.dart';
import '../widgets/account_panel.dart';

/// MT5-style account summary + open positions. Header shows floating P/L (blue
/// in profit, red in loss); rows show Balance / Equity / Credit / Margin / Free
/// margin; an accounts strip switches the active account; open trades list below
/// is sortable (newest / oldest / by symbol) and scrolls for long lists.
final _positionsProvider = FutureProvider.autoDispose<List<Position>>((ref) async {
  final id = ref.watch(activeAccountIdProvider);
  if (id == null) return [];
  final api = ref.watch(apiClientProvider);
  final data = await api.get('/positions', query: {'accountId': id, 'status': 'OPEN'}) as List;
  return data.map((e) => Position.fromJson(e)).toList();
});

enum _Sort { newest, oldest, symbol }

class PortfolioScreen extends ConsumerStatefulWidget {
  const PortfolioScreen({super.key});
  @override
  ConsumerState<PortfolioScreen> createState() => _PortfolioScreenState();
}

class _PortfolioScreenState extends ConsumerState<PortfolioScreen> {
  _Sort _sort = _Sort.newest;

  @override
  Widget build(BuildContext context) {
    final tc = Theme.of(context).extension<TradeColors>()!;
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const <Account>[];
    final liveAcc = ref.watch(liveAccountProvider);
    final id = ref.watch(activeAccountIdProvider);
    final positions = ref.watch(_positionsProvider);
    final livePL = ref.watch(livePositionProvider);
    final quotes = ref.watch(quotesProvider);
    final symbols = ref.watch(symbolsProvider).valueOrNull ?? const <TradeSymbol>[];
    final api = ref.read(apiClientProvider);

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
      ref.invalidate(_positionsProvider);
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
      final pl = resolvePositionPl(p, livePl: livePL, quotes: quotes, symbols: symbols);
      showModalBottomSheet(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              title: Row(children: [
                Text(display, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                Text('${p.side} ${p.volume.toStringAsFixed(2)}',
                    style: TextStyle(color: p.side == 'BUY' ? tc.buy : tc.sell, fontWeight: FontWeight.w600, fontSize: 13)),
              ]),
              subtitle: Text('@ ${price(p.openPrice, p.digits)}'),
              trailing: Text(money(pl),
                  style: TextStyle(color: pl >= 0 ? tc.profit : tc.loss, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.candlestick_chart_outlined),
              title: const Text('Chart'),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(chartSymbolProvider.notifier).set(p.symbol);
                TraderNav.openChart(context, p.symbol);
              },
            ),
            ListTile(
              leading: const Icon(Icons.add_chart_outlined),
              title: const Text('Add position'),
              subtitle: Text('New order on ${symbolDisplay(p.symbol, ref.read(clientSuffixProvider))}'),
              onTap: () {
                Navigator.pop(ctx);
                TraderNav.openTrade(context, p.symbol);
              },
            ),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Modify position'),
              subtitle: const Text('Set stop loss / take profit'),
              onTap: () {
                Navigator.pop(ctx);
                _modify(context, ref, p, refresh);
              },
            ),
            ListTile(
              leading: const Icon(Icons.call_split),
              title: const Text('Partial close'),
              subtitle: const Text('Choose how many lots to close'),
              onTap: () {
                Navigator.pop(ctx);
                partialClose(p);
              },
            ),
            ListTile(
              leading: Icon(Icons.close, color: tc.loss),
              title: Text('Close trade', style: TextStyle(color: tc.loss, fontWeight: FontWeight.w600)),
              trailing: Text(money(pl), style: TextStyle(color: pl >= 0 ? tc.profit : tc.loss, fontFeatures: const [FontFeature.tabularFigures()])),
              onTap: () {
                Navigator.pop(ctx);
                close(p.id);
              },
            ),
            const SizedBox(height: 8),
          ]),
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
        title: Text('${money(fpl)} ${acc?.currency ?? 'USD'}',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: plColor, fontFeatures: const [FontFeature.tabularFigures()])),
        actions: [
          IconButton(
            tooltip: 'Add',
            icon: const Icon(Icons.add),
            onPressed: () {},
          ),
          PopupMenuButton<_Sort>(
            tooltip: 'Sort trades',
            icon: const Icon(Icons.more_vert),
            initialValue: _sort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (_) => const [
              PopupMenuItem(value: _Sort.newest, child: Text('Newest first')),
              PopupMenuItem(value: _Sort.oldest, child: Text('Oldest first')),
              PopupMenuItem(value: _Sort.symbol, child: Text('By symbol')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(children: [
          const SizedBox(height: 8),
          // ── Account summary rows ──
          if (acc != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(children: [
                _row('Balance', money(balanceV)),
                _row('Equity', money(equityV)),
                _row('Credit', money(creditV)),
                _row('Margin', money(marginV)),
                _row('Free margin', money(freeMarginV)),
                _row('Margin level', '${marginLevelV.toStringAsFixed(2)}%'),
              ]),
            ),
          const SizedBox(height: 8),
          // ── Accounts switcher ──
          if (accounts.length > 1)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final a in accounts)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      child: ChoiceChip(
                        label: Text('#${a.login}'),
                        selected: a.id == id,
                        onSelected: (_) => ref.read(activeAccountIdProvider.notifier).state = a.id,
                      ),
                    ),
                ],
              ),
            ),
          const Divider(height: 16),
          // ── Open trades ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
            child: Row(children: [
              Text('OPEN TRADES', style: TextStyle(fontSize: 11, letterSpacing: 0.5, fontWeight: FontWeight.w700, color: Theme.of(context).hintColor)),
              const Spacer(),
              positions.maybeWhen(
                data: (l) => l.isEmpty
                    ? const SizedBox.shrink()
                    : TextButton(
                        onPressed: () async {
                          if (id != null) {
                            await api.post('/accounts/$id/close-all', {});
                            SoundService.instance.tradeClose();
                            await refresh();
                          }
                        },
                        child: Text('Close all', style: TextStyle(color: tc.loss)),
                      ),
                orElse: () => const SizedBox.shrink(),
              ),
            ]),
          ),
          positions.when(
            loading: () => const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
            error: (e, _) => Padding(padding: const EdgeInsets.all(24), child: Center(child: Text('$e'))),
            data: (list) {
              if (list.isEmpty) {
                return Padding(
                    padding: const EdgeInsets.all(40),
                    child: Center(child: Text('No open trades.', style: TextStyle(color: Theme.of(context).hintColor))));
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
                    onTap: () => showActions(p),
                  ),
              ]);
            },
          ),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  Widget _row(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 17)),
          Text(v, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
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
                  SoundService.instance.tradeOpen();
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

class _TradeTile extends StatelessWidget {
  const _TradeTile({required this.p, required this.display, required this.pl, required this.tc, required this.onTap});
  final Position p;
  final String display;
  final double pl;
  final TradeColors tc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final plColor = pl >= 0 ? tc.profit : tc.loss;
    return ListTile(
      onTap: onTap,
      title: Row(children: [
        Text(display, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(width: 6),
        Text('${p.side} ${p.volume.toStringAsFixed(2)}',
            style: TextStyle(color: p.side == 'BUY' ? tc.buy : tc.sell, fontSize: 17, fontWeight: FontWeight.w700)),
      ]),
      subtitle: Text(
        '@ ${price(p.openPrice, p.digits)}   SL ${p.slPrice != null ? price(p.slPrice!, p.digits) : '—'} · TP ${p.tpPrice != null ? price(p.tpPrice!, p.digits) : '—'}',
        style: const TextStyle(fontSize: 17, fontFeatures: [FontFeature.tabularFigures()]),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(money(pl), style: TextStyle(fontSize: 17, color: plColor, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(width: 4),
        Icon(Icons.chevron_right, size: 20, color: Theme.of(context).hintColor),
      ]),
    );
  }
}
