import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/chart.dart';

/// Small "Updating chart…" label while the chart fetches the bars it missed (the app was away, the network dropped). The
/// chart meanwhile shows its last complete stretch ([chartUpdatingProvider]); a catch-up that finishes quickly shows no
/// label at all, so it does not flash on every reopen.
class ChartUpdatingBadge extends ConsumerStatefulWidget {
  const ChartUpdatingBadge(this.req, {super.key});
  final ChartReq req;

  static const Duration showAfter = Duration(milliseconds: 700);

  @override
  ConsumerState<ChartUpdatingBadge> createState() => _ChartUpdatingBadgeState();
}

class _ChartUpdatingBadgeState extends ConsumerState<ChartUpdatingBadge> {
  Timer? _delay;
  bool _visible = false;

  void _onUpdating(bool updating) {
    _delay?.cancel();
    if (!updating) {
      if (_visible) setState(() => _visible = false);
      return;
    }
    _delay = Timer(ChartUpdatingBadge.showAfter, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onUpdating(ref.read(chartUpdatingProvider(widget.req)));
    });
  }

  @override
  void didUpdateWidget(ChartUpdatingBadge old) {
    super.didUpdateWidget(old);
    if (old.req != widget.req) {
      _visible = false;
      _onUpdating(ref.read(chartUpdatingProvider(widget.req)));
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(chartUpdatingProvider(widget.req), (_, now) => _onUpdating(now));
    if (!_visible) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.6, color: cs.onSurface.withValues(alpha: 0.7))),
          const SizedBox(width: 7),
          Text('Updating chart…', style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.85))),
        ]),
      ),
    );
  }
}
