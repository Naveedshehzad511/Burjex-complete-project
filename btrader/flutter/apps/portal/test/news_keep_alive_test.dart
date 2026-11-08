import 'package:burjex_portal/state/market_news.dart';
import 'package:burjex_portal/widgets/economic_calendar.dart';
import 'package:burjex_portal/widgets/market_news.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the TradingView web view and counts how many times one is created (each creation = a TradingView load).
class _Probe extends StatefulWidget {
  const _Probe(this.onCreate, this.onLoaded);
  final VoidCallback onCreate;
  final VoidCallback onLoaded;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.onCreate();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onLoaded());
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 600);
}

/// Scrolls the way a finger does: in small steps, a frame each, so the list builds and drops rows as it would on a phone.
Future<void> _scrollTo(WidgetTester t, ScrollController c, double y) async {
  while ((c.offset - y).abs() > 1) {
    final step = (y - c.offset).clamp(-400.0, 400.0);
    c.jumpTo(c.offset + step);
    await t.pump();
  }
}

void main() {
  testWidgets('News & Events and Top Stories keep what they loaded when scrolled far away and back', (t) async {
    var news = 0, calendar = 0;
    final scroll = ScrollController();
    await t.pumpWidget(ProviderScope(
      overrides: [
        newsFeedViewBuilderProvider.overrideWithValue(({required key, required tab, required dark, required onLoaded, required onFailed, required onOpen}) =>
            _Probe(() => news++, onLoaded)),
        calendarViewBuilderProvider.overrideWithValue(({required key, required dark, required onLoaded, required onFailed, required onOpen}) =>
            _Probe(() => calendar++, onLoaded)),
      ],
      child: MaterialApp(
        home: Scaffold(
          // Same shape as Home: a lazy ListView with the two sections among tall siblings.
          body: ListView(controller: scroll, children: const [
            EconomicCalendarSection(),
            SizedBox(height: 3000),
            MarketNewsSection(),
            SizedBox(height: 3000),
          ]),
        ),
      ),
    ));
    await t.pump();
    expect(calendar, 1);

    for (var i = 0; i < 3; i++) {
      await _scrollTo(t, scroll, 6000); // far from the calendar
      await _scrollTo(t, scroll, 0);
    }
    expect(calendar, 1, reason: 'News & Events is not rebuilt (no new TradingView load) after scrolling away and back');

    await _scrollTo(t, scroll, 3300);
    expect(news, 1);
    for (var i = 0; i < 3; i++) {
      await _scrollTo(t, scroll, 0);
      await _scrollTo(t, scroll, 3300);
    }
    expect(news, 1, reason: 'Top Stories is not rebuilt after scrolling away and back');
  });

  test('coming back to Home: under 2 min shows it as is, 2 to 10 min refreshes quietly, over 10 min loads afresh', () {
    expect(newsViewReuse(Duration.zero), NewsViewReuse.fresh);
    expect(newsViewReuse(const Duration(minutes: 1, seconds: 59)), NewsViewReuse.fresh);
    expect(newsViewReuse(const Duration(minutes: 2)), NewsViewReuse.refreshQuietly);
    expect(newsViewReuse(const Duration(minutes: 3)), NewsViewReuse.refreshQuietly);
    expect(newsViewReuse(const Duration(minutes: 9, seconds: 59)), NewsViewReuse.refreshQuietly);
    expect(newsViewReuse(const Duration(minutes: 10)), NewsViewReuse.reload);
    expect(newsViewReuse(const Duration(hours: 1)), NewsViewReuse.reload);
  });
}
