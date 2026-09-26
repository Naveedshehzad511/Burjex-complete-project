import 'dart:collection';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Short audio + haptic feedback for trade actions and errors.
///
/// Latency: each sound has its own player with the asset already loaded, so a
/// play is `seek(0) + resume()` — no file load on the hot path. The vibration is
/// issued first, synchronously, in the same tick as the call.
///
/// Feedback fires once per confirmed order: [orderPlaced] is de-duplicated by
/// order id, so the REST response and a later WebSocket event for the same order
/// can both call it without vibrating twice.
class SoundService {
  SoundService._() {
    _open = _player('bt_open', 'sounds/trade_open.wav');
    _close = _player('bt_close', 'sounds/trade_close.wav');
    _err = _player('bt_err', 'sounds/error.wav');
  }
  static final SoundService instance = SoundService._();

  late final AudioPlayer _open;
  late final AudioPlayer _close;
  late final AudioPlayer _err;
  bool enabled = true;
  final _seen = ListQueue<String>();

  AudioPlayer _player(String id, String asset) {
    final p = AudioPlayer(playerId: id)..setReleaseMode(ReleaseMode.stop);
    // Pre-load so the first play is not the one that pays for decoding.
    Future<void>(() async {
      try {
        await p.setPlayerMode(PlayerMode.lowLatency);
        await p.setSource(AssetSource(asset));
      } catch (_) {/* audio is optional; never block trading */}
    });
    return p;
  }

  void _fire(AudioPlayer p) {
    if (!enabled) return;
    // Not awaited: the caller must never wait on audio.
    p.seek(Duration.zero).then((_) => p.resume(), onError: (_) {});
  }

  /// A manual order was confirmed by the server. Call once per order.
  void orderPlaced([String? orderId]) {
    if (orderId != null && orderId.isNotEmpty) {
      if (_seen.contains(orderId)) return;
      _seen.addLast(orderId);
      if (_seen.length > 64) _seen.removeFirst();
    }
    HapticFeedback.mediumImpact(); // very short tick
    _fire(_open);
  }

  /// Trade opened successfully (kept for callers without an order id).
  Future<void> tradeOpen() async => orderPlaced();

  /// Trade / position closed.
  Future<void> tradeClose() async {
    HapticFeedback.mediumImpact();
    _fire(_close);
  }

  /// Any error (order rejected, market closed, network, etc.).
  Future<void> error() async {
    HapticFeedback.heavyImpact();
    _fire(_err);
  }

  @visibleForTesting
  void resetForTest() => _seen.clear();
}
