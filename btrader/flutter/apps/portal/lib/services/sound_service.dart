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
///
/// Android: the vibration goes through the real Vibrator service (a tiny bridge in MainActivity.kt,
/// needs the VIBRATE permission) - `HapticFeedback` only asks the view for a touch tick, which phones
/// with "touch vibration" off, and many others, simply do not play. The sound uses the low-latency
/// player's regular `play()` there. If either is unavailable the old behaviour is the fallback, and
/// nothing here can ever block or fail a trade.
class SoundService {
  SoundService._() {
    _event = _player('bt_event', eventAsset);
    _err = _player('bt_err', 'sounds/error.wav');
  }
  static final SoundService instance = SoundService._();

  /// The short click played for every confirmed order event: a trade opened or closed, a pending
  /// order placed, an order / SL / TP modified. About 200 ms, trimmed to start right at the click
  /// (assets/sounds/order_event.wav), so it is heard within milliseconds of the confirmation.
  static const eventAsset = 'sounds/order_event.wav';

  /// Native bridge to Android's Vibrator (MainActivity.kt).
  @visibleForTesting
  static const haptics = MethodChannel('burjex/haptics');

  late final AudioPlayer _event;
  late final AudioPlayer _err;
  bool enabled = true;
  final _seen = ListQueue<String>();
  final _assets = <AudioPlayer, String>{};

  // Vibration patterns in ms: (delay, on, off, on ...).
  static const _tick = [0, 55];
  static const _soft = [0, 40];
  static const _errPulse = [0, 80, 70, 80];

  bool get _androidApp => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  AudioPlayer _player(String id, String asset) {
    final p = AudioPlayer(playerId: id)..setReleaseMode(ReleaseMode.stop);
    _assets[p] = asset;
    // Pre-load so the first play is not the one that pays for decoding.
    Future<void>(() async {
      try {
        await p.setPlayerMode(PlayerMode.lowLatency);
        await p.setSource(AssetSource(asset));
      } catch (e) {
        debugPrint('sound preload failed ($asset): $e'); // audio is optional; never block trading
      }
    });
    return p;
  }

  /// Touch [instance] at app start so the players exist and are loading their clips: the FIRST trade
  /// of a session must not be the one that pays for that (and plays in silence).
  void warmUp() {}

  /// Vibrate with [pattern]. Real vibration on Android; elsewhere, or when the device has no vibrator
  /// or the bridge is missing, the old [fallback] haptic.
  void _vibrate(List<int> pattern, Future<void> Function() fallback) {
    if (!_androidApp) {
      fallback();
      return;
    }
    haptics.invokeMethod<bool>('vibrate', {'pattern': pattern}).then((ok) {
      if (ok != true) fallback();
    }, onError: (Object e) {
      debugPrint('vibration unavailable: $e');
      fallback();
    });
  }

  void _fire(AudioPlayer p) {
    if (!enabled) return;
    final asset = _assets[p];
    // Not awaited: the caller must never wait on audio.
    () async {
      if (_androidApp && asset != null) {
        // The documented Android path: play() the asset (the low-latency pool keeps it decoded after the
        // first load). The seek + resume shortcut below stays for the other platforms and as a fallback.
        try {
          // stop() FIRST, every time. The Android low-latency (SoundPool) player never reports that a clip
          // finished, so its internal "playing" flag stays true after the first sound and every later
          // play() / resume() is silently ignored - only the first event of a session would be heard.
          // stop() clears that flag (and the finished stream), so each event sounds.
          await p.stop();
        } catch (_) {/* nothing playing yet */}
        try {
          await p.play(AssetSource(asset), mode: PlayerMode.lowLatency);
          return;
        } catch (e) {
          debugPrint('sound play failed ($asset): $e');
        }
      }
      try {
        await p.seek(Duration.zero);
      } catch (_) {/* best effort */}
      try {
        await p.resume();
      } catch (e) {
        debugPrint('sound resume failed: $e');
      }
    }();
  }

  /// A manual order was confirmed by the server. Call once per order.
  void orderPlaced([String? orderId]) {
    if (orderId != null && orderId.isNotEmpty) {
      if (_seen.contains(orderId)) return;
      _seen.addLast(orderId);
      if (_seen.length > 64) _seen.removeFirst();
    }
    _vibrate(_tick, HapticFeedback.mediumImpact); // very short tick
    _fire(_event);
  }

  /// Trade opened successfully (kept for callers without an order id).
  Future<void> tradeOpen() async => orderPlaced();

  /// Trade / position closed.
  Future<void> tradeClose() async {
    _vibrate(_tick, HapticFeedback.mediumImpact);
    _fire(_event);
  }

  /// A resting (pending) order was cancelled and the server accepted it.
  Future<void> orderCancelled() async {
    _vibrate(_soft, HapticFeedback.mediumImpact);
    _fire(_event);
  }

  /// An existing order or position was modified (price, SL or TP) and the server accepted it.
  Future<void> orderModified() async {
    _vibrate(_soft, HapticFeedback.mediumImpact);
    _fire(_event);
  }

  /// Any error (order rejected, market closed, network, etc.).
  Future<void> error() async {
    _vibrate(_errPulse, HapticFeedback.heavyImpact);
    _fire(_err);
  }

  @visibleForTesting
  void resetForTest() => _seen.clear();
}
