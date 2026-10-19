import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/crm/crm.dart';
import 'package:burjex_portal/screens/history_screen.dart';
import 'package:burjex_portal/screens/home_screen.dart';
import 'package:burjex_portal/screens/markets_screen.dart';
import 'package:burjex_portal/screens/trade_screen.dart';
import 'package:burjex_portal/widgets/portal_drawer.dart';
import 'package:burjex_portal/widgets/trade_toast.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On an iPhone every piece of text must be drawn in the bundled Roboto. A text that ends up without it falls back
/// to San Francisco, which is what made iOS look bold. Rendered as iOS (its typography differs from Android's).
class _Api extends ApiClient {
  _Api() : super(AuthStore());
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/positions') {
      return [
        {'id': 'p1', 'accountId': 'A1', 'side': 'BUY', 'volume': 0.1, 'openPrice': 1.1, 'profit': 5, 'symbol': {'symbol': 'EURUSD', 'digits': 5}, 'openedAt': DateTime.now().toIso8601String()}
      ];
    }
    return <dynamic>[];
  }
}

Account _acct() => Account.fromJson({
      'id': 'A1', 'login': '500001', 'type': 'LIVE', 'status': 'ACTIVE', 'currency': 'USD', 'leverage': 1000,
      'balance': 996.8, 'equity': 987.51, 'margin': 0, 'freeMargin': 987.51, 'marginLevel': 0, 'floatingPL': 0,
    });

CrmAccount _crm() => CrmAccount.fromJson({'login_id': '500001', 'account_type': 'LIVE', 'is_demo': false, 'balance': 996.8, 'equity': 987.51, 'leverage': 1000, 'status': 'ACTIVE', 'trading_enabled': true, 'group_name': 'standard'});

const _iconFonts = {'MaterialIcons', 'CupertinoIcons', 'packages/cupertino_icons/CupertinoIcons'};

/// Every text on screen whose font is not the bundled Roboto, with the text itself.
List<String> _notRoboto(WidgetTester t) {
  final bad = <String>[];
  void visit(InlineSpan span, String? family) {
    final f = span.style?.fontFamily ?? family;
    if (span is TextSpan) {
      final text = span.text ?? '';
      if (text.trim().isNotEmpty && !_iconFonts.contains(f) && f != kAppFontFamily) bad.add('"$text" -> $f');
      for (final c in span.children ?? const <InlineSpan>[]) {
        visit(c, f);
      }
    }
  }

  for (final p in t.allRenderObjects.whereType<RenderParagraph>()) {
    visit(p.text, null);
  }
  for (final e in t.allRenderObjects.whereType<RenderEditable>()) {
    visit(e.text ?? const TextSpan(), null);
  }
  return bad;
}

Future<void> _show(WidgetTester t, Widget home, {bool openDrawer = false}) async {
  SharedPreferences.setMockInitialValues({});
  t.view
    ..physicalSize = const Size(430, 1600)
    ..devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(_Api()),
    marketSocketProvider.overrideWith((_) => null),
    openPositionsTickProvider.overrideWith((_) => const Stream<int>.empty()),
    symbolsProvider.overrideWith((_) async => const <TradeSymbol>[]),
    accountsProvider.overrideWith((_) async => [_acct()]),
    activeAccountIdProvider.overrideWith((_) => 'A1'),
    crmDashboardProvider.overrideWith((_) async => CrmDashboard(
        real: const CrmMetrics(balance: 996.8, equity: 987.51, openPnl: -9.29, margin: 0, withdrawable: 0),
        demo: const CrmMetrics(),
        accounts: [_crm()],
        userName: 'u',
        walletBalance: 0)),
  ]);
  addTearDown(c.dispose);
  final key = GlobalKey<ScaffoldState>();
  await t.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(
      theme: AppTheme.light(Branding.fallback),
      home: openDrawer ? Scaffold(key: key, drawer: const PortalDrawer(), body: const SizedBox()) : home,
    ),
  ));
  if (openDrawer) key.currentState!.openDrawer();
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 60));
    t.takeException(); // the test font's metrics overflow a few rows; layout is not under test here
  }
}

void main() {
  final screens = <String, (Widget, bool)>{
    'Home': (const HomeScreen(), false),
    'Quotes': (const MarketsScreen(), false),
    'Trade': (const TradeScreen(), false),
    'History': (const HistoryScreen(), false),
    'Menu': (const SizedBox(), true),
  };
  for (final e in screens.entries) {
    testWidgets('iOS: every text on ${e.key} is the bundled Roboto', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await _show(t, e.value.$1, openDrawer: e.value.$2);
        expect(t.allRenderObjects.whereType<RenderParagraph>(), isNotEmpty);
        expect(_notRoboto(t), isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('iOS: a trade toast is the bundled Roboto, not the fallback (monospace, underlined)', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.light(Branding.fallback),
        builder: (c, child) => ToastHost(child: child!),
        home: const Scaffold(body: SizedBox()),
      ));
      ToastHost.show('Order filled', 'BUY 0.10 EURUSD');
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Order filled'), findsOneWidget);
      expect(_notRoboto(t), isEmpty);
      final title = t.renderObject<RenderParagraph>(find.text('Order filled'));
      expect(title.text.style?.decoration, isNot(TextDecoration.underline));
      await t.pump(const Duration(seconds: 10)); // let the toast expire
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
