import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/drawing.dart';
import 'providers.dart';

/// The drawings of the ACTIVE trading account, across symbols, saved on the device under that account so they
/// survive navigation, app restarts and a logout / login, and are never shown under another account (the chart
/// filters to the active symbol). The account is the key: it identifies the user and the account at once, and it is
/// the same every time the same user signs in.
class ChartDrawingsController extends StateNotifier<List<DrawingObject>> {
  ChartDrawingsController(this._ref) : super(const []) {
    _ref.listen<String?>(activeAccountIdProvider, (_, id) => _load(id), fireImmediately: true);
  }
  final Ref _ref;
  static const _legacyKey = 'bt_chart_drawings'; // before drawings were kept per account
  String? _account;
  Future<void> _loading = Future<void>.value();

  static String keyFor(String accountId) => '$_legacyKey|$accountId';

  /// Show the drawings of [id] and nothing of the previous account.
  Future<void> _load(String? id) {
    _account = id;
    state = const []; // never the previous account's, not even while this one is being read
    return _loading = _read(id);
  }

  Future<void> _read(String? id) async {
    if (id == null) return;
    List<DrawingObject> saved = const [];
    try {
      final p = await SharedPreferences.getInstance();
      var raw = p.getString(keyFor(id));
      if (raw == null) {
        // Drawings saved before they were kept per account belong to the first account that opens the chart.
        raw = p.getString(_legacyKey);
        if (raw != null) {
          await p.setString(keyFor(id), raw);
          await p.remove(_legacyKey);
        }
      }
      if (raw != null) {
        saved = (jsonDecode(raw) as List).map((e) => DrawingObject.fromJson(e as Map<String, dynamic>)).toList();
      }
    } catch (_) {
      // Corrupt payload / no storage - start clean rather than crash the chart.
    }
    if (_account != id || !mounted) return; // the account changed while reading: that answer is not for it
    // A drawing made while the saved ones were loading is kept, and nothing is shown twice.
    final fresh = state.where((d) => !saved.any((x) => x.id == d.id));
    state = [...saved, ...fresh];
    if (fresh.isNotEmpty) await _write(id);
  }

  /// Saves the current drawings under the active account - after the saved ones have been read, so a drawing made
  /// during the read cannot replace them.
  Future<void> _persist() async {
    await _loading;
    await _write(_account);
  }

  Future<void> _write(String? id) async {
    if (id == null) return; // no account yet: nothing to attach a drawing to
    final snapshot = state;
    try {
      final p = await SharedPreferences.getInstance();
      if (_account != id) return; // the account changed meanwhile: do not write A's drawings under B
      await p.setString(keyFor(id), jsonEncode(snapshot.map((e) => e.toJson()).toList()));
    } catch (_) {/* best effort */}
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

  /// Replace all anchors of a drawing at once (a whole-object move, called when the drag is released).
  void updateAnchors(String id, List<DrawingAnchor> anchors) {
    state = [for (final d in state) d.id == id ? d.copyWith(anchors: anchors) : d];
    _persist();
  }

  void updateColor(String id, int colorArgb) {
    state = [for (final d in state) d.id == id ? d.copyWith(colorArgb: colorArgb) : d];
    _persist();
  }
}

final chartDrawingsProvider =
    StateNotifierProvider<ChartDrawingsController, List<DrawingObject>>(
  (ref) => ChartDrawingsController(ref),
);
