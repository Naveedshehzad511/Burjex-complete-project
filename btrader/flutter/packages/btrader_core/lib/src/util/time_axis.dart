import 'dart:math' as math;

import '../models/candle.dart';
import 'format.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _2(int v) => v.toString().padLeft(2, '0');

/// A chart time-axis / crosshair label for a bar opening at [d], as MT5 writes it: on the trade server's
/// clock and 24-hour, never the phone's zone or 12-hour setting. Every intraday label carries its date, so
/// midnight and older trading days read correctly ("28 Oct 23:55", "29 Oct 00:00").
///   M1…H4 → "29 Oct 04:22"   D1 / W1 → "29 Oct 2026"   MN → "Oct 2026"
/// The month names are fixed English (as MT5), independent of the device locale.
String chartTimeLabel(DateTime d, Timeframe tf) {
  final s = serverTime(d);
  final mon = _months[s.month - 1];
  return switch (tf) {
    Timeframe.mn1 => '$mon ${s.year}',
    Timeframe.d1 || Timeframe.w1 => '${s.day} $mon ${s.year}',
    _ => '${s.day} $mon ${_2(s.hour)}:${_2(s.minute)}',
  };
}

/// The smallest step of 1, 2, 3, 4, 6, 8, 12, 16, 24, … bars that is at least [need]. Snapping to a short
/// ladder keeps the labelled bars the same over most of a pinch instead of changing with every frame.
int niceLabelStride(double need) {
  if (!(need > 1)) return 1;
  if (need <= 2) return 2;
  var a = 2, b = 3; // from here each step is the one before last ×2: 4, 6, 8, 12, 16, 24, …
  while (b < need) {
    final next = a * 2;
    a = b;
    b = next;
  }
  return b;
}

/// One placed time-axis label.
class TimeAxisLabel {
  final int index; // index into the visible candles
  final String text;
  final double left;
  final double width; // including the tag's padding
  final bool tag; // the highlighted crosshair / newest-candle label
  const TimeAxisLabel(this.index, this.text, this.left, this.width, {this.tag = false});
  double get right => left + width;
}

/// Places the time-axis labels of one frame (pure; the painters only draw the result).
///
/// - Spacing follows the real label width, the slot width (zoom) and the timeframe's text, so a phone gets a few
///   labels and a wide screen more, without overlap.
/// - Labels sit on every `stride`-th bar counted from the newest bar of the whole series ([newestOffset] = bars
///   right of the visible window), so a label stays on its bar while the chart pans.
/// - A label is kept inside [0, width] (pulled in at the edges, never clipped) and dropped if it would touch
///   another one or the tag.
/// - [tagIndex] (the crosshair bar, or the newest bar) gets a highlighted label that always wins its place.
List<TimeAxisLabel> layoutTimeAxis({
  required int count,
  required int newestOffset,
  required double slot,
  required double Function(int i) centerX,
  required String Function(int i) text,
  required double Function(String s) measure,
  required double width,
  int? tagIndex,
  double tagPad = 8,
  double gap = 14,
  double edge = 2,
}) {
  final out = <TimeAxisLabel>[];
  if (count <= 0 || width <= 0 || slot <= 0) return out;

  double place(double cx, double w) => (cx - w / 2).clamp(edge, math.max(edge, width - w - edge));
  bool free(double l, double r) {
    for (final o in out) {
      // Half the target gap: stride spacing alone keeps labels `gap` apart, this only stops a label pulled
      // in at an edge (or one wider than the sample) from touching its neighbour.
      if (l < o.right + gap / 2 && r > o.left - gap / 2) return false;
    }
    return true;
  }

  if (tagIndex != null && tagIndex >= 0 && tagIndex < count) {
    final cx = centerX(tagIndex);
    if (cx >= 0 && cx <= width) {
      final t = text(tagIndex);
      final w = measure(t) + tagPad;
      out.add(TimeAxisLabel(tagIndex, t, place(cx, w), w, tag: true));
    }
  }

  final stride = niceLabelStride((measure(text(count - 1)) + gap) / slot);
  for (var i = count - 1; i >= 0; i--) {
    if ((newestOffset + count - 1 - i) % stride != 0) continue;
    final cx = centerX(i);
    if (cx > width) continue;
    if (cx < 0) break;
    final t = text(i);
    final w = measure(t);
    var l = place(cx, w);
    if (!free(l, l + w) && out.isNotEmpty && out.first.tag && l + w > out.first.left - gap / 2) {
      // Only the tag is in the way (it is pulled in at the right edge): slide this label left of it rather than
      // leave a hole, as long as its bar stays under the text.
      final moved = out.first.left - gap / 2 - w;
      if (moved >= edge && cx - moved <= w) l = moved;
    }
    if (!free(l, l + w)) continue;
    out.add(TimeAxisLabel(i, t, l, w));
  }
  return out;
}
