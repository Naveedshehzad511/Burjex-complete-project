import 'package:flutter/material.dart';
import '../models/branding.dart';

/// Semantic trading colors available to widgets via Theme.of(context)
/// .extension<TradeColors>(). Buy/sell and P&L colors adapt to light/dark.
@immutable
class TradeColors extends ThemeExtension<TradeColors> {
  final Color buy;
  final Color sell;
  final Color profit;
  final Color loss;
  // MT5 quote direction vs day-open: up = blue, down = red.
  final Color up;
  final Color down;
  const TradeColors({
    required this.buy,
    required this.sell,
    required this.profit,
    required this.loss,
    required this.up,
    required this.down,
  });

  @override
  TradeColors copyWith({Color? buy, Color? sell, Color? profit, Color? loss, Color? up, Color? down}) =>
      TradeColors(
        buy: buy ?? this.buy,
        sell: sell ?? this.sell,
        profit: profit ?? this.profit,
        loss: loss ?? this.loss,
        up: up ?? this.up,
        down: down ?? this.down,
      );

  @override
  TradeColors lerp(ThemeExtension<TradeColors>? other, double t) {
    if (other is! TradeColors) return this;
    return TradeColors(
      buy: Color.lerp(buy, other.buy, t)!,
      sell: Color.lerp(sell, other.sell, t)!,
      profit: Color.lerp(profit, other.profit, t)!,
      loss: Color.lerp(loss, other.loss, t)!,
      up: Color.lerp(up, other.up, t)!,
      down: Color.lerp(down, other.down, t)!,
    );
  }
}

/// Builds light and dark Material 3 themes seeded from the tenant's brand color,
/// so every broker brand gets its own look with one source of truth.
class AppTheme {
  static ThemeData _base(Brightness b, Branding brand) {
    final isDark = b == Brightness.dark;
    final bg = isDark ? const Color(0xFF0B0F17) : const Color(0xFFFFFFFF);
    final onBg = isDark ? const Color(0xFFE6E9F0) : const Color(0xFF11141A);
    final divider = isDark ? const Color(0xFF1D2840) : const Color(0xFFE3E6EC);
    // The brand drives ACCENTS only (primary). Surfaces stay neutral white/dark
    // so the background never gets tinted by the logo's colour.
    final scheme = ColorScheme.fromSeed(seedColor: brand.primary, brightness: b).copyWith(
      surface: bg,
      onSurface: onBg,
      surfaceContainerLowest: bg,
      surfaceContainerLow: isDark ? const Color(0xFF0F1521) : const Color(0xFFF7F9FC),
      surfaceContainer: isDark ? const Color(0xFF121826) : const Color(0xFFF3F5F9),
      surfaceContainerHigh: isDark ? const Color(0xFF161E2C) : const Color(0xFFEFF1F5),
      surfaceContainerHighest: isDark ? const Color(0xFF1A2334) : const Color(0xFFEAEDF2),
      outlineVariant: divider,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      dividerColor: divider,
      fontFamily: 'Roboto',
      extensions: <ThemeExtension<dynamic>>[
        TradeColors(
          // Unified scheme: BLUE = positive, RED = negative (everywhere).
          buy: isDark ? const Color(0xFF4C8DFF) : const Color(0xFF1E66F5),
          sell: isDark ? const Color(0xFFFF5A5F) : const Color(0xFFD92D2D),
          profit: isDark ? const Color(0xFF4C8DFF) : const Color(0xFF1E66F5),
          loss: isDark ? const Color(0xFFFF5A5F) : const Color(0xFFD92D2D),
          up: isDark ? const Color(0xFF4C8DFF) : const Color(0xFF1E66F5),
          down: isDark ? const Color(0xFFFF5A5F) : const Color(0xFFD92D2D),
        ),
      ],
      cardTheme: CardThemeData(
        elevation: 0,
        color: isDark ? const Color(0xFF0F1729) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: isDark ? const Color(0xFF1D2840) : const Color(0xFFE6E9F0)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF0B1220) : const Color(0xFFF1F3F8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        isDense: true,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xFF0A0F1C) : Colors.white,
        indicatorColor: brand.primary.withValues(alpha: 0.15),
        labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11)),
      ),
    );
  }

  static ThemeData light(Branding brand) => _base(Brightness.light, brand);
  static ThemeData dark(Branding brand) => _base(Brightness.dark, brand);
}
