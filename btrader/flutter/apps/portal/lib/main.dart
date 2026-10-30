import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'crm/crm.dart';
import 'screens/security_screens.dart';
import 'security/geo_gate.dart';
import 'services/sound_service.dart';
import 'session/app_reset.dart';
import 'widgets/trade_toast.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // A release build made without --dart-define-from-file (e.g. archived straight from Xcode) still talks to
  // production instead of a LAN address. API_BASE / WS_URL, when given, win.
  BtConfig.releaseFallbackHost = 'portal.burjexprime.net';
  SoundService.instance.warmUp(); // load the trade sounds now, not on the first trade
  GeoGate.instance.install(); // iPhone / iPad: sign-in and registration only where the service is offered
  runApp(const _AppRoot());
}

/// The provider tree is keyed on the session generation: a logout bumps it ([resetAppForNewUser]) and every provider
/// - and with it every trace of the previous user - is discarded, so the next login starts clean.
class _AppRoot extends StatelessWidget {
  const _AppRoot();
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: appSessionGeneration,
        builder: (_, generation, __) => ProviderScope(key: ValueKey(generation), child: const PortalApp()),
      );
}

/// Burjex Prime navy — the one brand colour used across every screen.
const kNavy = Color(0xFF002D58);

class PortalApp extends ConsumerWidget {
  const PortalApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brand = Branding(
      appName: 'Burjex Prime',
      logoUrl: null,
      primary: kNavy,
      accent: const Color(0xFF0BB07B),
    );
    final router = ref.watch(routerProvider);
    final mode = ref.watch(themeModeProvider);
    // A signed-in iPhone / iPad session whose location is no longer allowed is signed out.
    GeoGate.instance.onRefused = () => ref.read(crmSessionProvider.notifier).logout();
    return MaterialApp.router(
      title: brand.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(brand),
      darkTheme: AppTheme.dark(brand),
      themeMode: mode,
      routerConfig: router,
      builder: (context, child) =>
          GeoPromptHost(child: LockGate(child: ToastHost(child: child ?? const SizedBox.shrink()))),
    );
  }
}
