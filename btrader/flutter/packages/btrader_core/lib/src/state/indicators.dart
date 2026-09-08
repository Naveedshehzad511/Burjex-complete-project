import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../indicators/engine.dart';
import '../indicators/indicator_config.dart';

/// The chart's active indicators. Held in a root (non-autoDispose) provider so
/// the set survives navigating away from and back to the chart — exactly like
/// [chartTfProvider]/[chartSymbolProvider] — and is additionally persisted to
/// disk (SharedPreferences), so a client's indicators also survive app
/// restarts, mirroring the ThemeModeController pattern.
class ChartIndicatorsController extends StateNotifier<List<IndicatorConfig>> {
  ChartIndicatorsController() : super(const []) {
    _restore();
  }
  static const _key = 'bt_chart_indicators';

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => IndicatorConfig.fromJson(e as Map<String, dynamic>))
          .toList();
      state = list;
    } catch (_) {
      // Corrupt/legacy payload — start clean rather than crash the chart.
    }
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(state.map((e) => e.toJson()).toList()));
  }

  String _newId(IndicatorType type) =>
      '${type.name}-${DateTime.now().microsecondsSinceEpoch}';

  void add(IndicatorType type) {
    state = [...state, IndicatorConfig.defaults(type, _newId(type))];
    _persist();
  }

  void addConfig(IndicatorConfig cfg) {
    state = [...state, cfg];
    _persist();
  }

  void remove(String id) {
    state = state.where((c) => c.id != id).toList();
    _persist();
  }

  void toggle(String id) {
    state = [
      for (final c in state) c.id == id ? c.copyWith(enabled: !c.enabled) : c,
    ];
    _persist();
  }

  /// Replace an existing config (edited params/colors/source) in place.
  void update(IndicatorConfig cfg) {
    state = [for (final c in state) c.id == cfg.id ? cfg : c];
    _persist();
  }

  void updateParams(String id, Map<String, double> params) {
    state = [
      for (final c in state) c.id == id ? c.copyWith(params: params) : c,
    ];
    _persist();
  }

  void updateColors(String id, List<int> colors) {
    state = [
      for (final c in state) c.id == id ? c.copyWith(colors: colors) : c,
    ];
    _persist();
  }

  void updateSource(String id, IndicatorSource source) {
    state = [
      for (final c in state) c.id == id ? c.copyWith(source: source) : c,
    ];
    _persist();
  }

  void clear() {
    state = const [];
    _persist();
  }
}

final chartIndicatorsProvider =
    StateNotifierProvider<ChartIndicatorsController, List<IndicatorConfig>>(
  (_) => ChartIndicatorsController(),
);
