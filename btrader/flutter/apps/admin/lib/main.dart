import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:btrader_core/btrader_core.dart';

import 'router.dart';

void main() => runApp(const ProviderScope(child: AdminApp()));

class AdminApp extends ConsumerWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brand = ref.watch(brandingProvider).valueOrNull ?? Branding.fallback;
    final router = ref.watch(adminRouterProvider);
    final mode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: '${brand.appName} Admin',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(brand),
      darkTheme: AppTheme.dark(brand),
      themeMode: mode == ThemeMode.system ? ThemeMode.light : mode, // admin defaults light (bright white)
      routerConfig: router,
    );
  }
}
