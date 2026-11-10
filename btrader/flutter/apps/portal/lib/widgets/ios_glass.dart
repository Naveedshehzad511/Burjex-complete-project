import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// iPhone / iPad "Liquid Glass" look, drawn by Flutter.
///
/// Only the iOS app uses it. Android and the website never do: every widget here returns the
/// plain child there, and callers keep their current widgets ([iosGlass] is false).
///
/// This is Flutter-drawn glass (blur + translucent fill + light edge), not Apple's native
/// Liquid Glass. Everything glass goes through [GlassSurface] / [showGlassMenu] and the values
/// in [GlassTheme], so native iOS 26 glass can later replace them in one place.
/// Tests switch it with `debugDefaultTargetPlatformOverride`.
bool get iosGlass => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// All glass look values in one place (never in screens).
class GlassTheme {
  static const double blur = 22;
  static const double barRadius = 30;
  static const double menuRadius = 26;
  static const double buttonRadius = 22;

  /// Fill over the blurred content: light enough to see through, strong enough to read.
  static Color fill(BuildContext c) =>
      _dark(c) ? const Color(0xFF1C1F26).withValues(alpha: 0.62) : Colors.white.withValues(alpha: 0.66);

  /// The glass "edge light".
  static Color edge(BuildContext c) =>
      _dark(c) ? Colors.white.withValues(alpha: 0.14) : Colors.white.withValues(alpha: 0.85);

  /// Pill buttons inside a glass menu (MT5's grey capsules).
  static Color pill(BuildContext c) =>
      _dark(c) ? Colors.white.withValues(alpha: 0.10) : Colors.black.withValues(alpha: 0.07);

  static List<BoxShadow> shadow(BuildContext c) => [
        BoxShadow(color: Colors.black.withValues(alpha: _dark(c) ? 0.45 : 0.12), blurRadius: 24, offset: const Offset(0, 8)),
      ];

  static bool _dark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;
}

/// A glass panel: the content behind it is blurred and tinted, with a light edge and soft shadow.
/// With Increase Contrast on (or off iOS) it is the plain solid surface.
class GlassSurface extends StatelessWidget {
  const GlassSurface({super.key, required this.child, this.radius = GlassTheme.barRadius, this.padding, this.shadow = true});

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final solid = MediaQuery.maybeHighContrastOf(context) ?? false;
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: solid ? Theme.of(context).colorScheme.surface : GlassTheme.fill(context),
        borderRadius: r,
        border: Border.all(color: solid ? Theme.of(context).dividerColor : GlassTheme.edge(context), width: 0.8),
      ),
      child: child,
    );
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: r, boxShadow: shadow ? GlassTheme.shadow(context) : null),
      child: ClipRRect(
        borderRadius: r,
        child: solid ? box : BackdropFilter(filter: ImageFilter.blur(sigmaX: GlassTheme.blur, sigmaY: GlassTheme.blur), child: box),
      ),
    );
  }
}

/// One choice in a [showGlassMenu].
class GlassMenuAction {
  const GlassMenuAction(this.label, this.onTap, {this.destructive = false, this.key});
  final String label;
  final VoidCallback onTap;
  final bool destructive;
  final Key? key;
}

/// MT5 iOS-style centred popup: a title, one capsule button per action, and (optionally) Cancel.
/// Tapping outside or Cancel just closes it. An action closes the popup first, then runs.
Future<void> showGlassMenu(
  BuildContext context, {
  String? title,
  required List<GlassMenuAction> actions,
  bool cancel = true,
  Color? destructiveColor,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.18),
    transitionDuration: const Duration(milliseconds: 180),
    transitionBuilder: (_, a, __, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
    ),
    pageBuilder: (ctx, _, __) {
      final cs = Theme.of(ctx).colorScheme;
      final red = destructiveColor ?? const Color(0xFFE5484D);
      Widget pill(String label, VoidCallback onTap, {Color? color, Key? key, FontWeight weight = FontWeight.w600}) => Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Material(
              color: GlassTheme.pill(ctx),
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: key,
                onTap: onTap,
                child: SizedBox(
                  height: 50,
                  width: double.infinity,
                  child: Center(child: Text(label, style: TextStyle(fontSize: 17, fontWeight: weight, color: color ?? cs.onSurface))),
                ),
              ),
            ),
          );
      return SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Material(
                type: MaterialType.transparency,
                child: GlassSurface(
                  radius: GlassTheme.menuRadius,
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (title != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: cs.onSurface)),
                      ),
                    for (final a in actions)
                      pill(a.label, () {
                        Navigator.of(ctx).pop();
                        a.onTap();
                      }, color: a.destructive ? red : null, key: a.key),
                    if (cancel) pill('Cancel', () => Navigator.of(ctx).pop(), key: const ValueKey('glass-cancel')),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// The iOS bottom tab bar: a floating glass capsule (MT5 / iOS 26 style) with the same tabs.
class GlassTabBar extends StatelessWidget {
  const GlassTabBar({super.key, required this.items, required this.selectedIndex, required this.onSelect});

  /// (icon, selected icon, label) per tab, in order.
  final List<(IconData, IconData, String)> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
        child: GlassSurface(
          padding: const EdgeInsets.all(5),
          child: SizedBox(
            height: 56,
            child: Row(children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: Semantics(
                    selected: i == selectedIndex,
                    button: true,
                    label: items[i].$3,
                    child: GestureDetector(
                      key: ValueKey('glass-tab-$i'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onSelect(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        decoration: BoxDecoration(
                          color: i == selectedIndex ? GlassTheme.pill(context) : Colors.transparent,
                          borderRadius: BorderRadius.circular(GlassTheme.barRadius),
                        ),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(i == selectedIndex ? items[i].$2 : items[i].$1,
                              size: 24, color: i == selectedIndex ? cs.primary : cs.onSurface.withValues(alpha: 0.75)),
                          const SizedBox(height: 2),
                          Text(items[i].$3,
                              maxLines: 1,
                              overflow: TextOverflow.fade,
                              softWrap: false,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: i == selectedIndex ? FontWeight.w700 : FontWeight.w500,
                                  color: i == selectedIndex ? cs.primary : cs.onSurface.withValues(alpha: 0.75))),
                        ]),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// iPhone app theme on top of the normal one: bottom sheets, popup menus and alerts get the glass
/// shape and a slightly see-through fill. Off iOS the theme is returned unchanged.
ThemeData withIosGlass(ThemeData t) {
  if (!iosGlass) return t;
  final dark = t.brightness == Brightness.dark;
  final fill = (dark ? const Color(0xFF1C1F26) : Colors.white).withValues(alpha: 0.94);
  const top = RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(GlassTheme.menuRadius + 2)));
  final round = RoundedRectangleBorder(borderRadius: BorderRadius.circular(GlassTheme.menuRadius));
  return t.copyWith(
    bottomSheetTheme: t.bottomSheetTheme.copyWith(
      backgroundColor: fill,
      modalBackgroundColor: fill,
      surfaceTintColor: Colors.transparent,
      shape: top,
      clipBehavior: Clip.antiAlias,
    ),
    popupMenuTheme: t.popupMenuTheme.copyWith(
      color: fill,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 10,
    ),
    dialogTheme: t.dialogTheme.copyWith(backgroundColor: fill, surfaceTintColor: Colors.transparent, shape: round),
  );
}
