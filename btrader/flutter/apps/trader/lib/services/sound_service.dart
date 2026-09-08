import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// Short audio + haptic feedback for trade actions and errors. Sounds are
/// bundled WAV assets; failures (e.g. silent mode) are swallowed so they never
/// block the trading flow. A single reusable player is kept low-latency.
class SoundService {
  SoundService._();
  static final SoundService instance = SoundService._();

  final AudioPlayer _player = AudioPlayer(playerId: 'bt_fx')
    ..setReleaseMode(ReleaseMode.stop);
  bool enabled = true;

  Future<void> _play(String asset) async {
    if (!enabled) return;
    try {
      await _player.stop();
      await _player.play(AssetSource(asset), volume: 1.0);
    } catch (_) {
      /* ignore audio failures (silent mode, no output, etc.) */
    }
  }

  /// Trade opened successfully.
  Future<void> tradeOpen() async {
    HapticFeedback.lightImpact();
    await _play('sounds/trade_open.wav');
  }

  /// Trade / position closed.
  Future<void> tradeClose() async {
    HapticFeedback.mediumImpact();
    await _play('sounds/trade_close.wav');
  }

  /// Any error (order rejected, market closed, network, etc.).
  Future<void> error() async {
    HapticFeedback.heavyImpact();
    await _play('sounds/error.wav');
  }
}
