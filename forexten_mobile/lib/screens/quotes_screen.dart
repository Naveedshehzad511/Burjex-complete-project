import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import '../state/account_view.dart';
import '../widgets/big_figure_price.dart';

class QuotesScreen extends ConsumerStatefulWidget {
  const QuotesScreen({super.key});
  @override
  ConsumerState<QuotesScreen> createState() => _QuotesScreenState();
}

class _QuotesScreenState extends ConsumerState<QuotesScreen> {
  List<TradeSymbol>? _last;

  @override
  Widget build(BuildContext context) {
    ref.watch(marketSocketProvider);
    ref.watch(feedSubscriptionProvider);
    final symbols = ref.watch(symbolsProvider);
    final mode = ref.watch(themeModeProvider);
    final fresh = symbols.valueOrNull;
    if (fresh != null) _last = fresh;
    final list = fresh ?? _last;
    if (symbols.hasError && list == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Quotes')),
        body: Center(child: Text('Failed to load symbols\n${symbols.error}', textAlign: TextAlign.center)),
      );
    }
    if (list == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Quotes')),
        body: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    final byCode = {for (final s in list) s.symbol: s};
    final allCodes = list.map((s) => s.symbol).toList();
    final watch = ref.watch(watchlistProvider) ?? allCodes;
    final shown = watch.where(byCode.containsKey).toList();
    final filtered = shown.isEmpty && allCodes.isNotEmpty ? allCodes : shown;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quotes'),
        actions: [
          IconButton(
            tooltip: 'Add symbols',
            icon: const Icon(Icons.add),
            onPressed: () => _manage(list, filtered, allCodes),
          ),
          IconButton(
            tooltip: 'Toggle theme',
            icon: Icon(mode == ThemeMode.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
            onPressed: () => ref.read(themeModeProvider.notifier).toggle(),
          ),
        ],
      ),
      body: filtered.isEmpty
          ? Center(child: Text('No symbols', style: TextStyle(color: Theme.of(context).hintColor)))
          : ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final s = byCode[filtered[i]]!;
                return Dismissible(
                  key: ValueKey(s.symbol),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: const Color(0xFFE5484D),
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    child: const Icon(Icons.delete_outline, color: Colors.white),
                  ),
                  onDismissed: (_) => ref.read(watchlistProvider.notifier).remove(s.symbol, allCodes),
                  child: _QuoteRow(spec: s, onTap: () => _menu(s)),
                );
              },
            ),
    );
  }

  void _menu(TradeSymbol s) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: const Text('New Order'),
            onTap: () {
              Navigator.pop(ctx);
              context.go('/trade?symbol=${Uri.encodeQueryComponent(s.symbol)}');
            },
          ),
          ListTile(
            title: const Text('Chart'),
            onTap: () {
              Navigator.pop(ctx);
              context.go('/chart?symbol=${Uri.encodeQueryComponent(s.symbol)}');
            },
          ),
          ListTile(
            title: const Text('Remove from Quotes'),
            onTap: () {
              final all = (ref.read(symbolsProvider).valueOrNull ?? const <TradeSymbol>[]).map((e) => e.symbol).toList();
              ref.read(watchlistProvider.notifier).remove(s.symbol, all);
              Navigator.pop(ctx);
            },
          ),
        ]),
      ),
    );
  }

  void _manage(List<TradeSymbol> all, List<String> shown, List<String> allCodes) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.7,
          child: ListView(
            children: [
              for (final s in all)
                ListTile(
                  title: Text(s.displaySymbol),
                  subtitle: Text(s.description ?? s.symbol),
                  trailing: shown.contains(s.symbol) ? const Icon(Icons.check) : const Icon(Icons.add),
                  onTap: () {
                    if (shown.contains(s.symbol)) {
                      ref.read(watchlistProvider.notifier).remove(s.symbol, allCodes);
                    } else {
                      ref.read(watchlistProvider.notifier).add(s.symbol, allCodes);
                    }
                    Navigator.pop(ctx);
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _QuoteRow extends ConsumerWidget {
  const _QuoteRow({required this.spec, required this.onTap});
  final TradeSymbol spec;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tick = ref.watch(quotesProvider.select((m) => m[spec.symbol]));
    final marked = spec.applyGroupMarkup(tick ?? const Tick(symbol: '', bid: 0, ask: 0, ts: 0));
    final tc = Theme.of(context).extension<TradeColors>()!;
    final bid = tick == null ? '—' : null;
    return ListTile(
      onTap: onTap,
      title: Text(spec.displaySymbol, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(spec.description ?? spec.klass, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: tick == null
          ? Text(bid!, style: TextStyle(color: Theme.of(context).hintColor))
          : Row(mainAxisSize: MainAxisSize.min, children: [
              BigFigurePrice(value: marked.bid, digits: spec.digits, color: tc.sell),
              const SizedBox(width: 12),
              BigFigurePrice(value: marked.ask, digits: spec.digits, color: tc.buy),
            ]),
    );
  }
}
