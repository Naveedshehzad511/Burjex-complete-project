import 'dart:io';

import 'package:btrader_core/btrader_core.dart';
import 'package:burjex_portal/screens/ib_screens.dart' show IbState, ibStateProvider;
import 'package:burjex_portal/widgets/portal_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The side menu opens at about half the viewport (within limits), keeps every label readable on
/// one line at every size, and closes from its button or a tap on the dimmed screen behind it.

const _labels = [
  'Dashboard', 'My Fund', 'My Wallet', 'KYC', 'IB Programme', 'My Data', 'Account', 'Competition',
  'Trade And Win', 'News', 'Trading Platform', 'Legal Agreements', 'Need Help?', 'Logout',
];

final _key = GlobalKey<ScaffoldState>();

Future<void> _open(WidgetTester t, Size size, {bool dark = true, List<Override> overrides = const []}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: dark ? AppTheme.dark(Branding.fallback) : AppTheme.light(Branding.fallback),
      home: Scaffold(
        key: _key,
        drawer: const PortalDrawer(),
        drawerScrimColor: Colors.black.withValues(alpha: 0.45),
        body: const Center(child: Text('behind')),
      ),
    ),
  ));
  _key.currentState!.openDrawer();
  await t.pumpAndSettle();
}

/// The test runner's default font (Ahem) draws every glyph as a full-width square, which says
/// nothing about whether a label fits. Load the real Roboto the app uses so widths are honest.
Future<void> _loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final f in ['regular', 'medium', 'bold']) {
    final file = File('$dir/roboto-$f.ttf');
    if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await loader.load();
}

void main() {
  setUpAll(_loadRoboto);

  group('the IB entry follows where the client stands', () {
    Future<void> openAs(WidgetTester t, IbState state) =>
        _open(t, const Size(390, 844), overrides: [ibStateProvider.overrideWith((ref) async => state)]);

    testWidgets('an approved IB sees the dashboard and no request entry', (t) async {
      await openAs(t, IbState.approved);
      await t.scrollUntilVisible(find.text('IB Dashboard'), 80, scrollable: find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable)).first);
      expect(find.text('IB Dashboard'), findsOneWidget);
      expect(find.text('IB Request'), findsNothing);
      expect(find.text('IB Programme'), findsNothing);
    });

    for (final state in [IbState.none, IbState.pending]) {
      testWidgets('${state.name}: only the request entry, no dashboard', (t) async {
        await openAs(t, state);
        await t.scrollUntilVisible(find.text('IB Request'), 80, scrollable: find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable)).first);
        expect(find.text('IB Request'), findsOneWidget);
        expect(find.text('IB Dashboard'), findsNothing);
      });
    }
  });

  test('width is about half the viewport, clamped, and never over 90% of a tiny screen', () {
    expect(PortalDrawer.widthFor(1366), 320, reason: 'desktop: capped, not a half-screen slab');
    expect(PortalDrawer.widthFor(820), 320);
    expect(PortalDrawer.widthFor(560), 280, reason: 'exactly half where it fits the limits');
    expect(PortalDrawer.widthFor(390), 236, reason: 'phone: half would clip labels, so the floor applies');
    expect(PortalDrawer.widthFor(240), closeTo(216, 0.001));
  });

  for (final dark in [true, false]) {
    for (final size in const [Size(320, 640), Size(390, 844), Size(820, 1180), Size(1366, 768)]) {
      testWidgets('${dark ? 'dark' : 'light'} ${size.width.toInt()}x${size.height.toInt()}: sized, readable, closes', (t) async {
        await _open(t, size, dark: dark);
        final w = t.getSize(find.byType(Drawer)).width;
        expect(w, closeTo(PortalDrawer.widthFor(size.width), 0.5));
        expect(w, lessThan(size.width), reason: 'the screen behind stays visible');
        expect(find.text('behind'), findsOneWidget);

        // Every entry is present, on ONE line (so nothing is cut or wraps awkwardly).
        for (final l in _labels) {
          final f = find.text(l);
          if (f.evaluate().isEmpty) {
            // The menu list scrolls: bring far entries into view like a user would.
            await t.scrollUntilVisible(f, 80, scrollable: find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable)).first);
          }
          expect(f, findsOneWidget, reason: l);
          expect(t.getSize(f).height, lessThan(26), reason: '$l must fit on one line');
          expect((t.widget<Text>(f).style?.fontSize ?? 14), greaterThanOrEqualTo(15), reason: '$l keeps a readable size');
        }
        // The expandable groups show a visible arrow each.
        for (final g in ['My Fund', 'IB Programme', 'My Data', 'Account']) {
          final tile = find.ancestor(of: find.text(g), matching: find.byType(ExpansionTile));
          if (tile.evaluate().isEmpty) {
            await t.scrollUntilVisible(find.text(g), -80, scrollable: find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable)).first);
          }
          expect(find.descendant(of: find.ancestor(of: find.text(g), matching: find.byType(ExpansionTile)), matching: find.byIcon(Icons.expand_more)), findsOneWidget, reason: '$g shows its arrow');
        }
        expect(find.byTooltip('Close menu'), findsOneWidget);

        // Expanding a group keeps its children readable too.
        await t.tap(find.text('IB Programme'));
        await t.pumpAndSettle();
        // While the IB state is unknown (here: no server) both entries are offered.
        for (final l in ['IB Dashboard', 'IB Request']) {
          expect(find.text(l), findsOneWidget);
          expect(t.getSize(find.text(l)).height, lessThan(24), reason: '$l fits on one line');
        }
        // What the IB Dashboard already carries is not repeated in the menu.
        for (final l in ['My Clients', 'My Commission', 'IB Tree Chart', 'IB Withdraw', 'IB Progress', 'Team Deposits', 'Team Withdrawals']) {
          expect(find.text(l), findsNothing, reason: '$l lives on the IB Dashboard');
        }
        expect(t.takeException(), isNull, reason: 'no overflow errors');

        // Close button.
        await t.tap(find.byTooltip('Close menu'));
        await t.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);

        // Tap on the dimmed area outside closes it as well.
        _key.currentState!.openDrawer();
        await t.pumpAndSettle();
        await t.tapAt(Offset(size.width - 4, size.height / 2));
        await t.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);
      });
    }
  }

  testWidgets('plain and expandable entries share one text column; rows are compact; no dead strip on the right', (t) async {
    await _open(t, const Size(390, 844));
    final xs = {for (final l in ['Dashboard', 'My Fund', 'My Wallet', 'KYC', 'IB Programme', 'My Data', 'Account', 'Competition']) l: t.getRect(find.text(l)).left};
    expect(xs.values.toSet().length, 1, reason: 'every label starts at the same x: $xs');
    final y1 = t.getRect(find.text('My Wallet')).top, y2 = t.getRect(find.text('KYC')).top;
    expect(y2 - y1, lessThanOrEqualTo(48), reason: 'compact row pitch');
    // The widest label leaves only a modest margin before the drawer's right edge.
    final drawerRight = t.getRect(find.byType(Drawer)).right;
    final widest = t.getRect(find.text('Legal Agreements').evaluate().isEmpty ? find.text('Competition') : find.text('Legal Agreements')).right;
    expect(drawerRight - widest, lessThan(60));
    // Expanded sub-items line up under the parent label.
    await t.tap(find.text('My Fund'));
    await t.pumpAndSettle();
    expect(t.getRect(find.text('Deposit')).left, xs['My Fund']);
  });
}
