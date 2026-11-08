import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The chart elements whose colour the user can change (Chart Settings > Colors), in MT5's order and groups.
enum ChartColorKey {
  background('Background', ChartColorGroup.general),
  foreground('Foreground', ChartColorGroup.general),
  grid('Grid', ChartColorGroup.general),
  barUp('Bar up', ChartColorGroup.appearance),
  barDown('Bar down', ChartColorGroup.appearance),
  bullCandle('Bull candle', ChartColorGroup.appearance),
  bearCandle('Bear candle', ChartColorGroup.appearance),
  chartLine('Chart line', ChartColorGroup.appearance),
  volumes('Volumes', ChartColorGroup.appearance),
  bidLine('Bid price line', ChartColorGroup.priceLines),
  askLine('Ask price line', ChartColorGroup.priceLines),
  slLine('Stop Loss line', ChartColorGroup.levels),
  slText('Stop Loss line text', ChartColorGroup.levels),
  tpLine('Take Profit line', ChartColorGroup.levels),
  tpText('Take Profit line text', ChartColorGroup.levels),
  sellLine('Sell line', ChartColorGroup.levels),
  sellText('Sell line text', ChartColorGroup.levels),
  buyLine('Buy line', ChartColorGroup.levels),
  buyText('Buy line text', ChartColorGroup.levels),
  stopLimitLine('Stop Limit Price line', ChartColorGroup.levels),
  stopLimitText('Stop Limit Price line text', ChartColorGroup.levels);

  const ChartColorKey(this.label, this.group);
  final String label;
  final ChartColorGroup group;
}

enum ChartColorGroup {
  general('General'),
  appearance('Chart appearance'),
  priceLines('Price lines'),
  levels('Trading levels');

  const ChartColorGroup(this.label);
  final String label;
}

/// The Scheme selector, as MT5 lists it, plus [defaultScheme] first. [defaultScheme] is today's look (every colour
/// comes from the app theme, so nothing changes until a user picks another); picking one of the others sets all the
/// colours of the palette below together. "Custom" is not a palette: it is the state of a scheme after single
/// colours were edited (or after the user chose Custom in the selector).
enum ChartScheme {
  defaultScheme('Default'),
  colorOnWhite('Color on White'),
  greenOnBlack('Green on Black'),
  blackOnWhite('Black on White');

  const ChartScheme(this.label);
  final String label;
}

const _teal = Color(0xFF26A69A), _red = Color(0xFFEF5350);

/// Full palettes of the predefined schemes (the Default scheme has none: it leaves the theme in charge).
/// "Color on White" is MT5's colourful scheme as in its Colors screen (white foreground, dark grid, teal / red bars,
/// orange SL, green TP, red sell and blue buy lines) on a black chart; the other two are the classic MT looks.
const Map<ChartScheme, Map<ChartColorKey, Color>> kSchemePalettes = {
  ChartScheme.colorOnWhite: {
    ChartColorKey.background: Color(0xFF000000),
    ChartColorKey.foreground: Color(0xFFFFFFFF),
    ChartColorKey.grid: Color(0xFF363A45),
    ChartColorKey.barUp: _teal,
    ChartColorKey.barDown: _red,
    ChartColorKey.bullCandle: _teal,
    ChartColorKey.bearCandle: _red,
    ChartColorKey.chartLine: Color(0xFFFFFFFF),
    ChartColorKey.volumes: _teal,
    ChartColorKey.bidLine: _teal,
    ChartColorKey.askLine: _red,
    ChartColorKey.slLine: Color(0xFFE8711A),
    ChartColorKey.slText: Color(0xFFFF8A45),
    ChartColorKey.tpLine: Color(0xFF2FB344),
    ChartColorKey.tpText: Color(0xFF4CC764),
    ChartColorKey.sellLine: Color(0xFFE64A4A),
    ChartColorKey.sellText: Color(0xFFFF5757),
    ChartColorKey.buyLine: Color(0xFF2F80FF),
    ChartColorKey.buyText: Color(0xFF4A9BFF),
    ChartColorKey.stopLimitLine: Color(0xFFFFFFFF),
    ChartColorKey.stopLimitText: Color(0xFFFFFFFF),
  },
  ChartScheme.greenOnBlack: {
    ChartColorKey.background: Color(0xFF000000),
    ChartColorKey.foreground: Color(0xFFC0C0C0),
    ChartColorKey.grid: Color(0xFF2A3A2A),
    ChartColorKey.barUp: Color(0xFF00FF00),
    ChartColorKey.barDown: Color(0xFF00FF00),
    ChartColorKey.bullCandle: Color(0xFF00FF00),
    ChartColorKey.bearCandle: Color(0xFF008F00),
    ChartColorKey.chartLine: Color(0xFF00FF00),
    ChartColorKey.volumes: Color(0xFF00FF00),
    ChartColorKey.bidLine: Color(0xFF00C853),
    ChartColorKey.askLine: Color(0xFFFF5252),
    ChartColorKey.slLine: Color(0xFFFF5252),
    ChartColorKey.slText: Color(0xFFFF8A80),
    ChartColorKey.tpLine: Color(0xFF00E676),
    ChartColorKey.tpText: Color(0xFF69F0AE),
    ChartColorKey.sellLine: Color(0xFFFF5252),
    ChartColorKey.sellText: Color(0xFFFF8A80),
    ChartColorKey.buyLine: Color(0xFF00E676),
    ChartColorKey.buyText: Color(0xFF69F0AE),
    ChartColorKey.stopLimitLine: Color(0xFFC0C0C0),
    ChartColorKey.stopLimitText: Color(0xFFC0C0C0),
  },
  ChartScheme.blackOnWhite: {
    ChartColorKey.background: Color(0xFFFFFFFF),
    ChartColorKey.foreground: Color(0xFF000000),
    ChartColorKey.grid: Color(0xFFD0D0D0),
    ChartColorKey.barUp: Color(0xFF000000),
    ChartColorKey.barDown: Color(0xFF000000),
    ChartColorKey.bullCandle: Color(0xFF000000),
    ChartColorKey.bearCandle: Color(0xFF9E9E9E),
    ChartColorKey.chartLine: Color(0xFF000000),
    ChartColorKey.volumes: Color(0xFF555555),
    ChartColorKey.bidLine: Color(0xFF00796B),
    ChartColorKey.askLine: Color(0xFFC62828),
    ChartColorKey.slLine: Color(0xFFE8711A),
    ChartColorKey.slText: Color(0xFFB85400),
    ChartColorKey.tpLine: Color(0xFF2E7D32),
    ChartColorKey.tpText: Color(0xFF1B5E20),
    ChartColorKey.sellLine: Color(0xFFD32F2F),
    ChartColorKey.sellText: Color(0xFFB71C1C),
    ChartColorKey.buyLine: Color(0xFF1565C0),
    ChartColorKey.buyText: Color(0xFF0D47A1),
    ChartColorKey.stopLimitLine: Color(0xFF000000),
    ChartColorKey.stopLimitText: Color(0xFF000000),
  },
};

/// The colours the chart actually uses: the scheme's palette with the user's single-colour edits on top. A key that
/// is missing means "keep the theme's colour" (so the Default scheme changes nothing). Value-equal, so the chart's
/// repaint check only fires when a colour really changed.
@immutable
class ChartPalette {
  const ChartPalette([this.colors = const {}]);
  final Map<ChartColorKey, Color> colors;

  static const empty = ChartPalette();
  bool get isEmpty => colors.isEmpty;
  Color? operator [](ChartColorKey k) => colors[k];

  @override
  bool operator ==(Object other) => other is ChartPalette && mapEquals(colors, other.colors);
  @override
  int get hashCode => Object.hashAllUnordered([for (final e in colors.entries) Object.hash(e.key, e.value.toARGB32())]);
}

class ChartColorsState {
  const ChartColorsState({this.scheme = ChartScheme.defaultScheme, this.edits = const {}, this.custom = false});

  /// The base scheme, and the colours the user changed one by one on top of it.
  final ChartScheme scheme;
  final Map<ChartColorKey, Color> edits;

  /// The user picked "Custom" in the selector (the colours stay as they are, and are edited from here).
  final bool custom;

  /// What the Scheme selector shows: the scheme's name, or "Custom" once a colour was edited or Custom was chosen.
  String get schemeLabel => (edits.isEmpty && !custom) ? scheme.label : 'Custom';

  ChartPalette get palette => ChartPalette({...?kSchemePalettes[scheme], ...edits});

  /// The colour shown in the Colors list for [k]: the chart's colour, or the theme's [fallback] when nothing overrides it.
  Color colorOf(ChartColorKey k, Color fallback) => palette[k] ?? fallback;
}

/// Chart colours: the scheme plus the single-colour edits, saved with SharedPreferences (the app's existing
/// preference store) and applied to the chart at once.
class ChartColorsController extends StateNotifier<ChartColorsState> {
  ChartColorsController() : super(const ChartColorsState()) {
    _restore();
  }

  static const kScheme = 'bt_cc_scheme';
  static const kCustom = 'bt_cc_custom';
  bool _changed = false; // the user already changed something: a late restore must not overwrite it
  static String keyOf(ChartColorKey k) => 'bt_cc_${k.name}';

  Future<void> _restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!mounted || _changed) return;
      final n = p.getString(kScheme);
      final scheme = ChartScheme.values.firstWhere((s) => s.name == n, orElse: () => ChartScheme.defaultScheme);
      final edits = <ChartColorKey, Color>{};
      for (final k in ChartColorKey.values) {
        final v = p.getInt(keyOf(k));
        if (v != null) edits[k] = Color(v);
      }
      state = ChartColorsState(scheme: scheme, edits: edits, custom: p.getBool(kCustom) ?? false);
    } catch (_) {/* defaults: the theme's colours */}
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(kScheme, state.scheme.name);
      await p.setBool(kCustom, state.custom);
      for (final k in ChartColorKey.values) {
        final c = state.edits[k];
        if (c == null) {
          await p.remove(keyOf(k));
        } else {
          await p.setInt(keyOf(k), c.toARGB32());
        }
      }
    } catch (_) {/* kept in memory for this session */}
  }

  /// Picking a predefined scheme sets every colour of it (single-colour edits are cleared, as in MT5).
  void setScheme(ChartScheme s) {
    _changed = true;
    state = ChartColorsState(scheme: s);
    _save();
  }

  /// Save from the Colors screen: the scheme and the colours exactly as edited there.
  void apply(ChartScheme scheme, Map<ChartColorKey, Color> edits, {bool custom = false}) {
    _changed = true;
    state = ChartColorsState(scheme: scheme, edits: Map.unmodifiable(edits), custom: custom);
    _save();
  }
}

final chartColorsProvider = StateNotifierProvider<ChartColorsController, ChartColorsState>((_) => ChartColorsController());
