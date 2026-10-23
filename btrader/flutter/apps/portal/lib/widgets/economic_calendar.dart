import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/economic_calendar.dart';
import '../state/market_news.dart';
import 'market_news.dart' show newsLinkLauncherProvider;
import 'news_feed_view.dart';
import 'portal_ui.dart';

/// Builds the calendar view; replaced in tests (a web view needs a real device).
typedef CalendarViewBuilder = Widget Function({
  required Key key,
  required bool dark,
  required VoidCallback onLoaded,
  required VoidCallback onFailed,
  required void Function(String url) onOpen,
});

final calendarViewBuilderProvider = Provider<CalendarViewBuilder>(
  (_) => ({required key, required dark, required onLoaded, required onFailed, required onOpen}) => NewsFeedView(
        key: key,
        tab: NewsTab.all,
        dark: dark,
        onLoaded: onLoaded,
        onFailed: onFailed,
        onOpen: onOpen,
        html: calendarWidgetHtml(dark: dark),
        height: kCalendarHeight.toDouble(),
      ),
);

/// Home, directly below the account list: TradingView's live economic calendar (Forex majors, Medium and High
/// impact). The widget draws its own heading, dates, times and impact markers. The section loads on its own,
/// apart from the rest of Home, reloads itself every [refreshEvery], and says so when it is loading or cannot be
/// reached.
class EconomicCalendarSection extends ConsumerStatefulWidget {
  const EconomicCalendarSection({super.key, this.refreshEvery = const Duration(minutes: 30), this.loadTimeout = const Duration(seconds: 30)});
  final Duration refreshEvery;
  final Duration loadTimeout;

  @override
  ConsumerState<EconomicCalendarSection> createState() => _EconomicCalendarSectionState();
}

class _EconomicCalendarSectionState extends ConsumerState<EconomicCalendarSection> {
  int _epoch = 0; // a new value rebuilds the view, which loads the calendar again
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

  void _reload({bool quiet = false}) {
    if (!mounted) return;
    setState(() {
      _epoch++;
      _failed = false;
      if (!quiet) _loading = true;
    });
    if (!quiet) _armTimeout();
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
    final build = ref.watch(calendarViewBuilderProvider);
    final open = ref.watch(newsLinkLauncherProvider);

    final Widget body;
    if (_failed) {
      body = InfoCard(
        child: Row(children: [
          Icon(Icons.cloud_off_outlined, size: 20, color: hint),
          const SizedBox(width: 10),
          Expanded(child: Text('The economic calendar is unavailable right now.', style: TextStyle(color: hint, fontSize: 13.5))),
          TextButton(onPressed: _reload, child: const Text('Retry')),
        ]),
      );
    } else {
      body = InfoCard(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(children: [
            // The view loads underneath the placeholder and shows once it has.
            build(
              key: ValueKey('calendar-$_epoch-$dark'),
              dark: dark,
              onLoaded: _loaded,
              onFailed: _failedLoading,
              onOpen: (url) async {
                final messenger = ScaffoldMessenger.maybeOf(context);
                if (!await open(url)) messenger?.showSnackBar(const SnackBar(content: Text('Could not open the page.')));
              },
            ),
            if (_loading) const Positioned.fill(child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))),
          ]),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 22),
      const Text('News & Events', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      const SizedBox(height: 12),
      body,
    ]);
  }
}
