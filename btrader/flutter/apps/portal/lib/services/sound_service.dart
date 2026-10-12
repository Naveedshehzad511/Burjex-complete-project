import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:btrader_core/btrader_core.dart' show TradeEventKind;
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

  late final AudioPlayer _event; // fallback only: Android plays the click natively (see [_fireEvent])
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
  // Long enough to be FELT: Android's own touch haptics are 30-70 ms and only register on a good linear
  // motor; its notification buzz is ~400 ms. (55 / 40 ms reached the vibrator and ran, but was not felt.)
  // Every confirmed trade event (open, close, modify, cancel, fill, SL / TP) uses the same pulse as an error
  // such as insufficient funds - the one pattern known to be felt on the client's phones.
  static const _errPulse = [0, 80, 70, 80];
  static const _tick = _errPulse; // trade opened / closed
  static const _soft = _errPulse; // modified / cancelled

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

  // One play at a time per player. Each event is `stop()` then `play()`; two overlapping, un-awaited
  // runs let the second stop() land BEFORE the first play() had started, so that click never sounded
  // (10 trades in a burst gave 7-8 clicks while all 10 vibrated). Chained, every event starts.
  final _playing = <AudioPlayer, Future<void>>{};
  // A plugin call that never answers must not freeze every later sound of the session.
  @visibleForTesting
  static Duration callTimeout = const Duration(milliseconds: 400);

  /// One event click. Android plays it through a native SoundPool (MainActivity.kt) - many overlapping streams,
  /// so every click of a burst sounds, in the same tick as its vibration. Elsewhere, or if the native sound is
  /// not ready, the audio plugin's player does it (one click at a time).
  void _fireEvent() {
    if (!enabled) return;
    eventClicks++;
    if (!_androidApp) {
      _fire(_event);
      return;
    }
    haptics.invokeMethod<bool>('click').then((ok) {
      if (ok != true) _fire(_event);
    }, onError: (Object e) {
      debugPrint('native click unavailable: $e');
      _fire(_event);
    });
  }

  /// Event clicks started since the last [resetForTest].
  @visibleForTesting
  int eventClicks = 0;

  void _fire(AudioPlayer p) {
    if (!enabled) return;
    final prev = _playing[p] ?? Future<void>.value();
    // Not awaited by the caller: it must never wait on audio.
    _playing[p] = prev.then((_) => _playOne(p)).catchError((Object e) {
      debugPrint('sound failed: $e');
    });
  }

  Future<void> _playOne(AudioPlayer p) async {
    final asset = _assets[p];
    await () async {
      if (_androidApp && asset != null) {
        // The documented Android path: play() the asset (the low-latency pool keeps it decoded after the
        // first load). The seek + resume shortcut below stays for the other platforms and as a fallback.
        try {
          // stop() FIRST, every time. The Android low-latency (SoundPool) player never reports that a clip
          // finished, so its internal "playing" flag stays true after the first sound and every later
          // play() / resume() is silently ignored - only the first event of a session would be heard.
          // stop() clears that flag (and the finished stream), so each event sounds.
          await p.stop().timeout(callTimeout);
        } catch (_) {/* nothing playing yet, or the plugin was slow: never hold the queue */}
        try {
          await p.play(AssetSource(asset), mode: PlayerMode.lowLatency).timeout(callTimeout);
          return;
        } catch (e) {
          debugPrint('sound play failed ($asset): $e');
        }
      }
      try {
        await p.seek(Duration.zero).timeout(callTimeout);
      } catch (_) {/* best effort */}
      try {
        await p.resume().timeout(callTimeout);
      } catch (e) {
        debugPrint('sound resume failed: $e');
      }
    }();
  }

  // ── Closing trades sounds AS they close, and stops when they stop ────────────────────────────────────
  // "Close all" of 40 positions finishes in a fraction of a second, but 40 queued clicks kept playing for
  // seconds after the last trade was already closed. Closes are therefore NOT queued one per trade:
  //  * a close plays its click the moment it is confirmed (sound and vibration together);
  //  * closes that arrive bunched - the server confirms a whole close-all within a few milliseconds, and the
  //    socket delivers it in one batch - follow as a short series, one click every [closeClickGap], at most
  //    [closeMaxClicks] in a row. A longer close-all (events that keep coming) keeps clicking while it runs.
  // So several clicks sound for a close-all, they follow the closing, and at most [closeMaxClicks] x
  // [closeClickGap] (about a quarter of a second) is left once the last trade has closed. (Opens still sound
  // one by one.)
  @visibleForTesting
  static Duration closeClickGap = const Duration(milliseconds: 45);
  static const int closeMaxClicks = 6;
  DateTime? _lastCloseClickAt;
  int _closePending = 0; // bunched closes still to click
  Timer? _closeTimer;
  List<int> _closePattern = _tick;

  void _playCloseClick() {
    _lastCloseClickAt = DateTime.now();
    _fireEvent();
    _vibrate(_closePattern, HapticFeedback.mediumImpact);
  }

  /// One confirmed close.
  void _closeEvent(List<int> pattern) {
    _closePattern = pattern;
    final last = _lastCloseClickAt;
    final free = last == null || DateTime.now().difference(last) >= closeClickGap;
    if (free && _closePending == 0) {
      _playCloseClick();
      return;
    }
    // Too soon after the previous click: it follows in turn (bounded, so a huge batch cannot drag on).
    if (_closePending < closeMaxClicks - 1) {
      _closePending++;
      _closeTimer ??= Timer(closeClickGap, _drainClosePending);
    }
  }

  void _drainClosePending() {
    _closeTimer = null;
    if (_closePending <= 0) return;
    _closePending--;
    _playCloseClick();
    if (_closePending > 0) _closeTimer = Timer(closeClickGap, _drainClosePending);
  }

  /// [count] closes reported together by the server's total (no socket event sounded them).
  void _closeSeries(List<int> pattern, int count) {
    for (var i = 0; i < count && i < closeMaxClicks; i++) {
      _closeEvent(pattern);
    }
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
        _fireEvent(); // sound first: the motor needs a moment to spin up, the sound does not
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

  // ── REST reply  <->  socket event: one feedback per real trade event ─────────────────────────────
  // The same open / close / modify is reported twice - by this device's REST reply and by the engine's
  // socket event - and the socket event is the ONLY report for a trade closed by its SL / TP, a pending
  // order that filled, or a change made from another device. Each report is matched against an
  // unmatched report of the other source (any order, so it also works for Close all: 40 REST closes
  // against 40 socket events), and only an unmatched one plays. Credits expire, so a report whose
  // partner never arrives (socket down, or no REST reply on this device) cannot suppress a later event.
  static const _creditTtl = Duration(seconds: 12);
  final _restCredits = <TradeEventKind, ListQueue<DateTime>>{for (final k in TradeEventKind.values) k: ListQueue()};
  final _socketCredits = <TradeEventKind, ListQueue<DateTime>>{for (final k in TradeEventKind.values) k: ListQueue()};

  int _live(ListQueue<DateTime> q) {
    final now = DateTime.now();
    while (q.isNotEmpty && now.difference(q.first) > _creditTtl) {
      q.removeFirst();
    }
    return q.length;
  }

  /// REST reported [n] confirmed [kind] events: how many of them still need feedback.
  int _restReport(TradeEventKind kind, int n) {
    final socket = _socketCredits[kind]!;
    var left = n;
    while (left > 0 && _live(socket) > 0) {
      socket.removeFirst();
      left--;
    }
    final now = DateTime.now();
    for (var i = 0; i < left; i++) {
      _restCredits[kind]!.addLast(now);
    }
    return left;
  }

  /// The engine confirmed a [kind] event on the socket (see `lastTradeEventProvider`). Plays unless this
  /// device's REST reply already did for it.
  void onTradeEvent(TradeEventKind kind) {
    final rest = _restCredits[kind]!;
    if (_live(rest) > 0) {
      rest.removeFirst();
      return;
    }
    _socketCredits[kind]!.addLast(DateTime.now());
    if (kind == TradeEventKind.closed) {
      _closeEvent(_tick);
    } else {
      _enqueue(kind == TradeEventKind.modified ? _soft : _tick);
    }
  }

  /// A position's SL / TP was just changed by something that is NOT an Apply (the "+" / toggle on the open
  /// card saves at once). The engine will confirm it on the socket; that confirmation is swallowed, so
  /// opening or toggling the SL / TP controls stays silent - the sound belongs to Apply.
  void expectPositionChange() => _restCredits[TradeEventKind.modified]!.addLast(DateTime.now());

  /// A manual order was confirmed by the server. Call once per order.
  ///
  /// [positionId]: the position this order opened (a market fill). Given, the engine's `opened` socket
  /// event for it is recognised as the same trade and does not vibrate again; a resting order that was
  /// only placed has none (its later fill is a separate event).
  void orderPlaced([String? orderId, String? positionId]) {
    if (orderId != null && orderId.isNotEmpty) {
      if (_seen.contains(orderId)) return;
      _seen.addLast(orderId);
      if (_seen.length > 64) _seen.removeFirst();
    }
    if (positionId != null && positionId.isNotEmpty && _restReport(TradeEventKind.opened, 1) == 0) return;
    _enqueue(_tick); // very short tick
  }

  /// Trade opened successfully (kept for callers without an order id).
  Future<void> tradeOpen() async => orderPlaced();

  /// Position(s) closed: one sound (and tick) per closed position - [count] is how many the server
  /// confirmed, e.g. 40 for Close all. The sounds are queued, never dropped.
  Future<void> tradeClose({int count = 1}) async {
    // What the server reported and no socket event already sounded (see [_closeSeries]).
    _closeSeries(_tick, _restReport(TradeEventKind.closed, count));
  }

  /// A resting (pending) order was cancelled and the server accepted it.
  Future<void> orderCancelled({int count = 1}) async {
    _closeSeries(_soft, count); // cancelling many pending orders follows the same rule
  }

  /// An existing order or position was modified (price, SL or TP) and the server accepted it.
  ///
  /// [position]: it was an open POSITION's SL / TP (the engine then confirms it on the socket as well,
  /// which must not vibrate a second time); a pending order's change has no such socket event.
  Future<void> orderModified({bool position = false}) async {
    if (position && _restReport(TradeEventKind.modified, 1) == 0) return;
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
    _lastCloseClickAt = null;
    _closePending = 0;
    _closeTimer?.cancel();
    _closeTimer = null;
    eventClicks = 0;
    for (final q in [..._restCredits.values, ..._socketCredits.values]) {
      q.clear();
    }
  }
}
