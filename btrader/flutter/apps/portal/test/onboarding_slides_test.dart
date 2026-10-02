import 'package:burjex_portal/crm/onboarding_slides.dart';
import 'package:burjex_portal/screens/onboarding_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

OnboardingSlideData _slide(int i, {String title = '', String desc = ''}) =>
    OnboardingSlideData(id: i, title: title, description: desc, imageUrl: 'http://invalid.test/$i.png');

Future<void> _pump(WidgetTester t, OnboardingSlides data) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(ProviderScope(
    overrides: [onboardingSlidesProvider.overrideWith((ref) => Stream.value(data))],
    child: const MaterialApp(home: OnboardingScreen()),
  ));
  await t.pump();
  await t.pump();
}

double? _page(WidgetTester t) => t.widget<PageView>(find.byType(PageView)).controller?.page;

void main() {
  group('OnboardingSlides.fromBody', () {
    test('reads slides, drops ones without an image, clamps the interval', () {
      final s = OnboardingSlides.fromBody({
        'success': true,
        'data': {
          'interval_seconds': 99,
          'slides': [
            {'id': 1, 'title': 'A', 'description': 'a', 'image_url': 'https://x/1.png'},
            {'id': 2, 'title': 'B', 'description': '', 'image_url': ''},
            {'id': 3, 'title': '', 'description': '', 'image_url': 'https://x/3.png'},
          ],
        },
      });
      expect(s.slides.map((e) => e.id), [1, 3]);
      expect(s.slides.first.hasText, isTrue);
      expect(s.slides.last.hasText, isFalse, reason: 'no copy → full-bleed artwork');
      expect(s.interval, const Duration(seconds: 15));
    });

    test('a failed / malformed response is just "no slides"', () {
      expect(OnboardingSlides.fromBody(null).slides, isEmpty);
      expect(OnboardingSlides.fromBody({'success': false}).slides, isEmpty);
      expect(OnboardingSlides.fromBody({'success': true, 'data': 'x'}).slides, isEmpty);
    });
  });

  group('OnboardingScreen', () {
    testWidgets('shows the CRM slides: 3 dots, their copy, and auto-advances every 3 s', (t) async {
      await _pump(t, OnboardingSlides([
        _slide(1, title: 'First title', desc: 'First text'),
        _slide(2, title: 'Second title'),
        _slide(3, title: 'Third title'),
      ]));
      expect(find.byType(AnimatedContainer), findsNWidgets(3), reason: 'one dot per CRM slide');
      expect(find.text('First title'), findsOneWidget);
      expect(find.text('First text'), findsOneWidget);
      expect(_page(t), 0);

      await t.pump(const Duration(seconds: 3));
      await t.pump(const Duration(milliseconds: 500));
      expect(_page(t), closeTo(1, 0.01), reason: 'advanced after the 3 s interval');

      await t.pump(const Duration(seconds: 3));
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(seconds: 3));
      await t.pump(const Duration(milliseconds: 500));
      expect(_page(t), closeTo(0, 0.01), reason: 'wraps back to the first of 3 slides');
    });

    testWidgets('swiping by hand still works', (t) async {
      await _pump(t, OnboardingSlides([_slide(1, title: 'One'), _slide(2, title: 'Two')]));
      await t.drag(find.byType(PageView), const Offset(-300, 0));
      await t.pumpAndSettle(); // let the page snap
      expect(_page(t), closeTo(1, 0.01));
    });

    testWidgets('no CRM slides → the 4 bundled slides', (t) async {
      await _pump(t, OnboardingSlides.empty);
      expect(find.byType(AnimatedContainer), findsNWidgets(4));
    });

    testWidgets('buttons follow the client layout: Google, Apple (iOS), Register, or, Sign In', (t) async {
      await _pump(t, OnboardingSlides.empty);
      double y(String label) => t.getTopLeft(find.text(label)).dy;
      expect(y('Google'), lessThan(y('Apple')));
      expect(y('Apple'), lessThan(y('Register')));
      expect(y('Register'), lessThan(y('or')));
      expect(y('or'), lessThan(y('Sign In')));
      expect(find.text('Login'), findsNothing, reason: 'the old Login button is now "Sign In"');
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('Apple is not offered on Android', (t) async {
      await _pump(t, OnboardingSlides.empty);
      expect(find.text('Apple'), findsNothing);
      expect(find.text('Google'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('the ? button opens a help sheet with sign-in / register / forgot-password', (t) async {
      await _pump(t, OnboardingSlides.empty);
      await t.tap(find.byKey(const ValueKey('landing-help')));
      await t.pumpAndSettle();
      expect(find.text('Need help?'), findsOneWidget);
      expect(find.text('Sign in to my account'), findsOneWidget);
      expect(find.text('Create an account'), findsOneWidget);
      expect(find.text('I forgot my password'), findsOneWidget);
    });

    testWidgets('a very short window scrolls instead of overflowing', (t) async {
      t.view.physicalSize = const Size(320, 480);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(ProviderScope(
        overrides: [onboardingSlidesProvider.overrideWith((ref) => Stream.value(OnboardingSlides([_slide(1, title: 'T', desc: 'D')])))],
        child: const MaterialApp(home: OnboardingScreen()),
      ));
      await t.pump();
      await t.pump();
      expect(t.takeException(), isNull);
    });

    testWidgets('the interval comes from the CRM', (t) async {
      await _pump(t, OnboardingSlides([_slide(1, title: 'One'), _slide(2, title: 'Two')], interval: const Duration(seconds: 5)));
      await t.pump(const Duration(seconds: 3));
      await t.pump(const Duration(milliseconds: 500));
      expect(_page(t), 0, reason: 'a 5 s interval has not elapsed yet');
      await t.pump(const Duration(seconds: 2));
      await t.pump(const Duration(milliseconds: 500));
      expect(_page(t), closeTo(1, 0.01));
    });
  });
}
