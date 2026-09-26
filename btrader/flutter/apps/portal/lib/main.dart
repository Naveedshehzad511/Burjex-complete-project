import 'package:btrader_core/btrader_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'widgets/trade_toast.dart';

void main() => runApp(const ProviderScope(child: PortalApp()));

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
    return MaterialApp.router(
      title: brand.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(brand),
      darkTheme: AppTheme.dark(brand),
      themeMode: mode,
      routerConfig: router,
      builder: (context, child) => ToastHost(child: child ?? const SizedBox.shrink()),
    );
  }
}
