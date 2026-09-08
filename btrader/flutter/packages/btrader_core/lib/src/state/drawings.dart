import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/drawing.dart';

/// All user drawings across symbols, persisted to disk (SharedPreferences) so
/// they survive navigation and app restarts — same pattern as the indicators
/// and chart symbol/timeframe. The chart filters to the active symbol.
class ChartDrawingsController extends StateNotifier<List<DrawingObject>> {
  ChartDrawingsController() : super(const []) {
    _restore();
  }
  static const _key = 'bt_chart_drawings';

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return;
    try {
      state = (jsonDecode(raw) as List)
          .map((e) => DrawingObject.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Corrupt/legacy payload — start clean rather than crash the chart.
    }
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(state.map((e) => e.toJson()).toList()));
  }

  void add(DrawingObject d) {
    state = [...state, d];
    _persist();
  }

  void remove(String id) {
    state = state.where((d) => d.id != id).toList();
    _persist();
  }

  /// Remove every drawing on one symbol (leaves other symbols' drawings).
  void clearSymbol(String symbol) {
    state = state.where((d) => d.symbol != symbol).toList();
    _persist();
  }

  /// Move one anchor of a drawing (called once when a drag is released).
  void updateAnchor(String id, int index, DrawingAnchor a) {
    state = [for (final d in state) d.id == id ? d.withAnchor(index, a) : d];
    _persist();
  }

  void updateColor(String id, int colorArgb) {
    state = [for (final d in state) d.id == id ? d.copyWith(colorArgb: colorArgb) : d];
    _persist();
  }
}

final chartDrawingsProvider =
    StateNotifierProvider<ChartDrawingsController, List<DrawingObject>>(
  (_) => ChartDrawingsController(),
);
