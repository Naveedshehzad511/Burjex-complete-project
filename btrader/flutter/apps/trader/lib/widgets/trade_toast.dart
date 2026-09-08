import 'dart:async';
import 'package:flutter/material.dart';

/// Lightweight, non-blocking trade notifications. Cards slide in at the TOP of
/// the screen (never over the bottom trade buttons), auto-dismiss after 2s,
/// stack/overlap when fired rapidly, and each has a close button. Showing a
/// toast is a cheap setState — it never blocks one-click trading.
///
/// Wrap the app once with [ToastHost]; fire with `ToastHost.show(...)`.
class ToastData {
  final String title;
  final String subtitle;
  final Color accent;
  final Key key;
  ToastData(this.title, this.subtitle, this.accent) : key = UniqueKey();
}

class ToastHost extends StatefulWidget {
  const ToastHost({super.key, required this.child});
  final Widget child;

  static _ToastHostState? _state;

  static void show(String title, String subtitle, {Color accent = const Color(0xFF1652F0)}) {
    _state?._add(ToastData(title, subtitle, accent));
  }

  @override
  State<ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends State<ToastHost> {
  final List<ToastData> _toasts = [];
  static const int _maxVisible = 5;

  @override
  void initState() {
    super.initState();
    ToastHost._state = this;
  }

  @override
  void dispose() {
    if (ToastHost._state == this) ToastHost._state = null;
    super.dispose();
  }

  void _add(ToastData t) {
    if (!mounted) return;
    setState(() {
      _toasts.add(t);
      if (_toasts.length > _maxVisible) _toasts.removeAt(0);
    });
    Timer(const Duration(seconds: 2), () => _remove(t));
  }

  void _remove(ToastData t) {
    if (!mounted) return;
    setState(() => _toasts.remove(t));
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    return Stack(children: [
      widget.child,
      // Toasts occupy only the top band → bottom trade buttons stay tappable.
      Positioned(
        top: topPad + 8,
        left: 0,
        right: 0,
        child: IgnorePointer(
          ignoring: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final t in _toasts)
                _ToastCard(key: t.key, data: t, onClose: () => _remove(t)),
            ],
          ),
        ),
      ),
    ]);
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({super.key, required this.data, required this.onClose});
  final ToastData data;
  final VoidCallback onClose;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 220))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF141C2B) : Colors.white;
    final border = isDark ? const Color(0xFF273349) : const Color(0xFFE6E9F0);
    final onBg = Theme.of(context).colorScheme.onSurface;
    final faint = Theme.of(context).hintColor;

    final anim = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: anim,
      child: SizeTransition(
        sizeFactor: anim,
        axisAlignment: -1.0,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, -0.25), end: Offset.zero).animate(anim),
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: border),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.10), blurRadius: 14, offset: const Offset(0, 4))],
            ),
            child: Row(children: [
              Container(
                width: 4,
                height: 44,
                margin: const EdgeInsets.only(left: 2),
                decoration: BoxDecoration(color: widget.data.accent, borderRadius: BorderRadius.circular(4)),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Icon(Icons.check_circle, color: widget.data.accent, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(widget.data.title,
                        style: TextStyle(color: onBg, fontWeight: FontWeight.w700, fontSize: 13.5)),
                    Text(widget.data.subtitle,
                        style: TextStyle(color: faint, fontSize: 11.5, fontFeatures: const [FontFeature.tabularFigures()])),
                  ]),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close, size: 18, color: faint),
                onPressed: widget.onClose,
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
