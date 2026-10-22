import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart' show kNavy;
import '../state/market_news.dart';
import 'news_feed_view.dart';
import 'portal_ui.dart';

/// Builds the widget view; replaced in tests (a web view needs a real device).
typedef NewsFeedViewBuilder = Widget Function({
  required Key key,
  required NewsTab tab,
  required bool dark,
  required VoidCallback onLoaded,
  required VoidCallback onFailed,
  required void Function(String url) onOpen,
});

final newsFeedViewBuilderProvider = Provider<NewsFeedViewBuilder>(
  (_) => ({required key, required tab, required dark, required onLoaded, required onFailed, required onOpen}) =>
      NewsFeedView(key: key, tab: tab, dark: dark, onLoaded: onLoaded, onFailed: onFailed, onOpen: onOpen),
);

/// Opens an address in the browser (a new tab on the web). False when it could not be opened.
Future<bool> openNewsLink(String url) async {
  if (!newsLinkOpenable(url)) return false;
  final uri = Uri.parse(url.trim());
  try {
    return kIsWeb ? await launchUrl(uri, webOnlyWindowName: '_blank') : await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

final newsLinkLauncherProvider = Provider<Future<bool> Function(String)>((_) => openNewsLink);

/// Home: category tabs and TradingView's live "Top Stories" list (the widget draws its own "Top Stories" title). Tapping a story opens that article in
/// the browser. The list reloads itself every [refreshEvery]; the section loads on its own, apart from the rest of
/// Home, and says so when it is loading or cannot be reached.
class MarketNewsSection extends ConsumerStatefulWidget {
  const MarketNewsSection({super.key, this.refreshEvery = const Duration(minutes: 10), this.loadTimeout = const Duration(seconds: 30)});
  final Duration refreshEvery;
  final Duration loadTimeout;

  @override
  ConsumerState<MarketNewsSection> createState() => _MarketNewsSectionState();
}

class _MarketNewsSectionState extends ConsumerState<MarketNewsSection> {
  NewsTab _tab = NewsTab.all;
  int _epoch = 0; // a new value rebuilds the view, which loads the list again
  bool _loading = true;
  bool _failed = false;
  Timer? _refresh;
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    _armTimeout();
    _refresh = Timer.periodic(widget.refreshEvery, (_) => _reload(quiet: true));
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _timeout?.cancel();
    super.dispose();
  }

  void _armTimeout() {
    _timeout?.cancel();
    _timeout = Timer(widget.loadTimeout, () {
      if (mounted && _loading) setState(() => _failed = true);
    });
  }

  /// Load the list again. [quiet]: the list on screen stays until the new one is ready (the periodic refresh).
  void _reload({bool quiet = false}) {
    if (!mounted) return;
    setState(() {
      _epoch++;
      _failed = false;
      if (!quiet) _loading = true;
    });
    if (!quiet) _armTimeout();
  }

  void _select(NewsTab t) {
    if (t == _tab) return;
    setState(() {
      _tab = t;
      _epoch++;
      _loading = true;
      _failed = false;
    });
    _armTimeout();
  }

  void _loaded() {
    if (!mounted) return;
    _timeout?.cancel();
    if (_loading || _failed) {
      setState(() {
        _loading = false;
        _failed = false;
      });
    }
  }

  void _failedLoading() {
    if (!mounted) return;
    _timeout?.cancel();
    setState(() {
      _loading = false;
      _failed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final hint = Theme.of(context).hintColor;
    final build = ref.watch(newsFeedViewBuilderProvider);
    final open = ref.watch(newsLinkLauncherProvider);

    final Widget body;
    if (_failed) {
      body = InfoCard(
        child: Row(children: [
          Icon(Icons.cloud_off_outlined, size: 20, color: hint),
          const SizedBox(width: 10),
          Expanded(child: Text('Market news is unavailable right now.', style: TextStyle(color: hint, fontSize: 13.5))),
          TextButton(onPressed: _reload, child: const Text('Retry')),
        ]),
      );
    } else {
      body = Stack(children: [
        // The view loads underneath the placeholder and shows once it has.
        build(
          key: ValueKey('news-${_tab.name}-$_epoch-$dark'),
          tab: _tab,
          dark: dark,
          onLoaded: _loaded,
          onFailed: _failedLoading,
          onOpen: (url) async {
            final messenger = ScaffoldMessenger.maybeOf(context);
            if (!await open(url)) messenger?.showSnackBar(const SnackBar(content: Text('Could not open the article.')));
          },
        ),
        if (_loading) const Positioned.fill(child: _NewsSkeleton()),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // No heading of our own: the widget's own "Top Stories" title (with the TradingView logo) is the heading.
      const SizedBox(height: 22),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final t in NewsTab.values)
            Padding(padding: const EdgeInsets.only(right: 8), child: _TabChip(label: t.label, selected: t == _tab, onTap: () => _select(t))),
        ]),
      ),
      const SizedBox(height: 8),
      body,
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () => open(kNewsKeepReadingUrl),
          style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.primary, padding: const EdgeInsets.symmetric(horizontal: 4)),
          child: const Text('Keep reading ›', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ),
    ]);
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: selected ? kNavy : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: selected ? const Color(0xFF6FA8E8) : Theme.of(context).dividerColor, width: selected ? 1.6 : 1),
            ),
            child: Text(
              label,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: selected ? Colors.white : Theme.of(context).colorScheme.onSurface),
            ),
          ),
        ),
      );
}

/// Placeholder rows while the list is on its way.
class _NewsSkeleton extends StatefulWidget {
  const _NewsSkeleton();
  @override
  State<_NewsSkeleton> createState() => _NewsSkeletonState();
}

class _NewsSkeletonState extends State<_NewsSkeleton> with SingleTickerProviderStateMixin {
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
      builder: (_, __) {
        final a = 0.05 + 0.06 * _c.value;
        Widget bar(double w, double h) => Container(width: w, height: h, decoration: BoxDecoration(color: base.withValues(alpha: a), borderRadius: BorderRadius.circular(6)));
        return ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          // Clipped, never overflowing, whatever height the list below it ends up with.
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < 5; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  bar(90, 10),
                  const SizedBox(height: 8),
                  bar(double.infinity, 14),
                  const SizedBox(height: 6),
                  bar(220, 14),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }
}
