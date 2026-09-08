import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import 'router.dart';
import 'widgets/trade_toast.dart';

void main() => runApp(const ProviderScope(child: TraderApp()));

class TraderApp extends ConsumerWidget {
  const TraderApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brand = ref.watch(brandingProvider).valueOrNull ?? Branding.fallback;
    final router = ref.watch(routerProvider);
    final mode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: brand.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(brand),
      darkTheme: AppTheme.dark(brand),
      themeMode: mode, // light / dark / system — controlled from Settings
      routerConfig: router,
      // Host for non-blocking trade toasts (top of screen, never over buttons).
      builder: (context, child) => ToastHost(child: child ?? const SizedBox.shrink()),
    );
  }
}
