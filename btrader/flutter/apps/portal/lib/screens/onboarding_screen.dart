import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../crm/onboarding_slides.dart';
import '../widgets/branding_slide.dart';
import '../widgets/social_brand_icons.dart';

// Landing-screen palette (matches the client's reference): a yellow primary action, light-grey
// secondary buttons, near-black text. Change the three values here to re-skin the screen.
const _kPrimary = Color(0xFF002D58); // brand navy, same as the Login button
const _kBtnGrey = Color(0xFFF1F3F4);
const _kInk = Color(0xFF111111);
const _crmSocial = 'https://crm.burjexprime.net/api/v1/auth';

/// Slides bundled in `assets/branding/` — shown until the CRM supplies its own, and whenever it can't.
const _kBundledSlides = 4;

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _page = PageController();
  Timer? _timer;
  int _index = 0;

  /// How many slides are showing and how often they advance. Driven by the CRM's slides (the
  /// 4 bundled ones until/unless it supplies its own), so the timer and the dots follow the data.
  int _count = _kBundledSlides;
  Duration _interval = const Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _armTimer();
  }

  void _armTimer() {
    _timer?.cancel();
    if (_count < 2) return; // nothing to advance to
    _timer = Timer.periodic(_interval, (_) {
      if (!mounted || !_page.hasClients) return;
      _page.animateToPage(
        (_index + 1) % _count,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _page.dispose();
    super.dispose();
  }

  /// Google / Apple sign-in is not live yet: show "Coming soon" instead of starting the flow.
  /// The original launch code is kept below as `_socialLaunch`, ready to switch back on.
  void _social(String provider) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Coming soon'), duration: Duration(seconds: 2)));
  }

  // ignore: unused_element
  Future<void> _socialLaunch(String provider) async {
    final origin = kIsWeb ? Uri.base.origin : 'https://portal.burjexprime.net';
    final next = Uri.encodeComponent('$origin/');
    final uri = Uri.parse('$_crmSocial/$provider/start/?mode=token&next=$next');
    if (kIsWeb) {
      await launchUrl(uri, webOnlyWindowName: '_self');
    } else {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Full-width landing button. Secondary buttons are flat light grey; the primary one is yellow.
  Widget _btn(String label, VoidCallback onTap, {Color bg = _kBtnGrey, Color fg = _kInk, Widget? leading}) {
    return SizedBox(
      height: 50,
      width: double.infinity,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg, // explicit: the dark theme's default label colour is light-on-dark
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (leading != null) ...[leading, const SizedBox(width: 10)],
            Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  void _register() {
    final refId = (Uri.base.queryParameters['ref'] ?? Uri.base.queryParameters['ib'] ?? '').trim();
    context.push(refId.isEmpty ? '/register' : '/register?ref=$refId');
  }

  /// The "?" in the corner: shortcuts to the screens a person stuck on this page usually wants.
  void _showHelp() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(alignment: Alignment.centerLeft, child: Text('Need help?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
          ),
          for (final (icon, label, route) in const [
            (Icons.login, 'Sign in to my account', '/login'),
            (Icons.person_add_alt_1_outlined, 'Create an account', '/register'),
            (Icons.lock_reset, 'I forgot my password', '/forgot-password'),
          ])
            ListTile(
              leading: Icon(icon),
              title: Text(label),
              onTap: () {
                Navigator.pop(ctx);
                context.push(route);
              },
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  /// Adopt a new slide count / interval (the CRM list arrived or changed): keep the page in
  /// range and restart the timer.
  void _syncSlides(int count, Duration interval) {
    if (count == _count && interval == _interval) return;
    _count = count;
    _interval = interval;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_index >= _count) {
        _index = 0;
        if (_page.hasClients) _page.jumpToPage(0);
        setState(() {});
      }
      _armTimer();
    });
  }

  @override
  Widget build(BuildContext context) {
    final remote = ref.watch(onboardingSlidesProvider).valueOrNull;
    final slides = remote?.slides ?? const <OnboardingSlideData>[];
    final useRemote = slides.isNotEmpty;
    final count = useRemote ? slides.length : _kBundledSlides;
    _syncSlides(count, useRemote ? remote!.interval : const Duration(seconds: 3));
    // Apple's button shows where Apple sign-in is available: iOS, and the web build.
    final showApple = kIsWeb || defaultTargetPlatform == TargetPlatform.iOS;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(builder: (context, c) {
          // Everything below the carousel has a fixed height; the carousel takes the rest (never
          // less than 260), and the page scrolls on a very short window instead of overflowing.
          const belowH = 336.0;
          final sliderH = math.max(260.0, c.maxHeight - belowH);
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: c.maxHeight),
              child: Column(children: [
                Stack(children: [
                  SizedBox(
                    height: sliderH,
                    width: double.infinity,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFE3E4E7), Colors.white]),
                      ),
                      child: PageView.builder(
                        controller: _page,
                        itemCount: count,
                        onPageChanged: (i) {
                          setState(() => _index = i);
                          _armTimer();
                        },
                        itemBuilder: (_, i) => useRemote ? RemoteBrandingSlide(slide: slides[i]) : BrandingSlide(index: i),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 12,
                    child: IconButton(
                      key: const ValueKey('landing-help'),
                      tooltip: 'Help',
                      onPressed: _showHelp,
                      icon: const Icon(Icons.help_outline, color: _kInk, size: 24),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(count, (i) {
                    final on = i == _index;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(color: on ? const Color(0xFF8A8F98) : const Color(0xFFD9DCE1), shape: BoxShape.circle),
                    );
                  }),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(children: [
                    _btn('Google', () => _social('google'), leading: const GoogleMark()),
                    if (showApple) ...[
                      const SizedBox(height: 10),
                      _btn('Apple', () => _social('apple'), leading: const AppleMark()),
                    ],
                    const SizedBox(height: 10),
                    _btn('Register', _register, bg: _kPrimary, fg: Colors.white),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: Divider(color: Colors.grey.shade300)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text('or', style: TextStyle(color: Colors.grey.shade700, fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                      Expanded(child: Divider(color: Colors.grey.shade300)),
                    ]),
                    const SizedBox(height: 12),
                    _btn('Sign In', () => context.push('/login')),
                    const SizedBox(height: 16),
                  ]),
                ),
              ]),
            ),
          );
        }),
      ),
    );
  }
}
