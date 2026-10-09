import 'dart:collection';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Short audio + haptic feedback for trade actions and errors.
///
/// Latency: each sound has its own player with the asset already loaded, so a
/// play is `seek(0) + resume()` — no file load on the hot path. The vibration is
/// issued in the same tick as the sound.
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

  /// The click played for every confirmed order event: a trade opened or closed, a pending order
  /// placed, an order / SL / TP modified. The original recording, cropped only of its leading and
  /// trailing silence (assets/sounds/order_event.wav, ~430 ms: the click starts 3 ms in, then its
  /// natural decay), so it is heard within milliseconds of the confirmation and never cut short.
  static const eventAsset = 'sounds/order_event.wav';

  /// Native bridge to Android's Vibrator (MainActivity.kt).
  @visibleForTesting
  static const haptics = MethodChannel('burjex/haptics');

  late final AudioPlayer _event;
  late final AudioPlayer _err;
  bool enabled = true;
  final _seen = ListQueue<String>();
  final _assets = <AudioPlayer, String>{};

  // Event sounds share ONE voice and play through a queue, so a burst (Close all of 40 positions)
  // is heard click after click instead of being dropped, stacked or cut before it is audible.
  // Each click is the first ~50 ms of the clip; a single event always plays in full.
  static const _burstWindow = Duration(milliseconds: 2000); // a whole burst is spread over about this
  static const _minGap = Duration(milliseconds: 50);        // the click is fully audible by then
  static const _maxGap = Duration(milliseconds: 120);       // few events: the click stays clear of the next one
  static const _minVibeGap = Duration(milliseconds: 100);   // a buzz per click would blur into one
  final _queue = ListQueue<List<int>>(); // vibration pattern of each event still to play
  bool _draining = false;
  int _gapMs = 120; // ms between two clicks of the current burst
  int _clicks = 0;  // clicks played in the current burst

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

  /// Queue [count] event sounds, each with its own [pattern] vibration. Returns at once; the caller
  /// never waits on audio or the vibrator.
  void _enqueue(List<int> pattern, {int count = 1}) {
    if (count <= 0) return;
    if (_queue.isEmpty) {
      _gapMs = _maxGap.inMilliseconds; // a new burst: the pace is worked out again
      _clicks = 0;
    }
    for (var i = 0; i < count; i++) {
      _queue.addLast(pattern);
    }
    if (!_draining) _drain();
  }

  /// Play the queued events one by one. The first plays in the same tick as the call (sound and
  /// vibration together); the next ones follow every gap, so 40 closes take about two seconds.
  Future<void> _drain() async {
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final pattern = _queue.removeFirst();
        // Pace: the whole burst fits [_burstWindow]. It only ever speeds up within a burst (more
        // events arriving), so the clicks do not slow down as the queue empties.
        final spread = _burstWindow.inMilliseconds ~/ (_queue.length + 1);
        _gapMs = min(_gapMs, spread.clamp(_minGap.inMilliseconds, _maxGap.inMilliseconds));
        _fire(_event); // sound first: the motor needs a moment to spin up, the sound does not
        // A buzz per click would blur into one long buzz in a fast burst: vibrate every few clicks.
        final every = (_minVibeGap.inMilliseconds / _gapMs).ceil();
        if (_clicks++ % every == 0) _vibrate(pattern, HapticFeedback.mediumImpact);
        // Even after the last click, hold the voice for a moment so an event right behind it does not
        // cut the click before it is heard.
        await Future<void>.delayed(Duration(milliseconds: _gapMs));
      }
    } finally {
      _draining = false;
    }
  }

  /// A manual order was confirmed by the server. Call once per order.
  void orderPlaced([String? orderId]) {
    if (orderId != null && orderId.isNotEmpty) {
      if (_seen.contains(orderId)) return;
      _seen.addLast(orderId);
      if (_seen.length > 64) _seen.removeFirst();
    }
    _enqueue(_tick); // very short tick
  }

  /// Trade opened successfully (kept for callers without an order id).
  Future<void> tradeOpen() async => orderPlaced();

  /// Position(s) closed: one sound (and tick) per closed position - [count] is how many the server
  /// confirmed, e.g. 40 for Close all. The sounds are queued, never dropped.
  Future<void> tradeClose({int count = 1}) async {
    _enqueue(_tick, count: count);
  }

  /// A resting (pending) order was cancelled and the server accepted it.
  Future<void> orderCancelled() async {
    _enqueue(_soft);
  }

  /// An existing order or position was modified (price, SL or TP) and the server accepted it.
  Future<void> orderModified() async {
    _enqueue(_soft);
  }

  /// Any error (order rejected, market closed, network, etc.).
  Future<void> error() async {
    _fire(_err);
    _vibrate(_errPulse, HapticFeedback.heavyImpact);
  }

  @visibleForTesting
  void resetForTest() {
    _seen.clear();
    _queue.clear();
  }
}
