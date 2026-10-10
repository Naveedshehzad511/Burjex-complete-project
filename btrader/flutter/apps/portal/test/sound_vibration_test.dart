import 'dart:io';

import 'package:burjex_portal/services/sound_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Trade feedback on Android: every existing trade event vibrates through the REAL vibrator
/// (MainActivity.kt bridge), and falls back to the old haptic only when the bridge cannot.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The audio plugin is not part of a unit test: answer its channels so the players can be created.
  final audio = <String>[]; // every call the audio plugin receives, in order
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (call) async {
    audio.add('${(call.arguments as Map)['playerId']}:${call.method}');
    return null;
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), (call) async => null);
  // AudioCache copies the asset to a temp file once; answer path_provider so play() works as on a phone.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'), (call) async => Directory.systemTemp.path);
  final sound = SoundService.instance;
  final calls = <List<int>>[];
  var platformHaptics = 0;

  setUp(() {
    calls.clear();
    platformHaptics = 0;
    sound.resetForTest();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SoundService.haptics, (call) async {
      calls.add([for (final n in (call.arguments as Map)['pattern'] as List) n as int]);
      return true;
    });
    // HapticFeedback goes through SystemChannels.platform.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') platformHaptics++;
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SoundService.haptics, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));
  // Event sounds share one voice: the next event starts once the previous click has had its gap.
  Future<void> nextEvent() => Future<void>.delayed(const Duration(milliseconds: 220));

  test('every trade event vibrates for real on Android, each with its own pattern', () async {
    sound.orderPlaced('o1'); // market buy / sell, pending placed
    await nextEvent();
    sound.tradeOpen();
    await nextEvent();
    await sound.tradeClose(); // position close, partial close, close all
    await nextEvent();
    await sound.orderModified(); // order / position / SL / TP modified
    await nextEvent();
    await sound.orderCancelled(); // pending order cancelled
    await nextEvent();
    await sound.error(); // rejected / failed
    await nextEvent();

    expect(calls.length, 6, reason: 'one vibration per event');
    expect(calls[0], [0, 55]);
    expect(calls[1], [0, 55]);
    expect(calls[2], [0, 55]);
    expect(calls[3], [0, 40]);
    expect(calls[4], [0, 40]);
    expect(calls[5], [0, 80, 70, 80], reason: 'an error is a double pulse, distinct from success');
    expect(platformHaptics, 0, reason: 'the weak touch tick is not used when the real vibrator answered');
  });

  test('EVERY event stops the low-latency player before playing, so it is not just the first one that sounds', () async {
    await settle(); // preload finished
    audio.clear();
    for (var i = 0; i < 4; i++) {
      await sound.tradeClose();
      await nextEvent();
    }
    final mine = audio.where((c) => c.startsWith('bt_event:')).toList();
    // Android's SoundPool never reports "finished", so after the first sound the player still counts as
    // playing and every later play() is ignored - unless stop() ran first. (This mock cannot emulate the
    // real plugin's play path; that the sound is actually heard each time is confirmed on the phone.)
    expect(mine.where((c) => c == 'bt_event:stop').length, 4, reason: 'a stop() per event: $mine');
    expect(mine.first, 'bt_event:stop', reason: 'stop() is the first call of an event: $mine');
    // The error sound has its own player, stopped the same way.
    audio.clear();
    await sound.error();
    await settle();
    expect(audio.where((c) => c.startsWith('bt_err:')), contains('bt_err:stop'));
  });

  test('order placed: sound and vibration start in the same tick, once per order', () async {
    await settle();
    audio.clear();
    sound.orderPlaced('same-tick');
    // Both reach the platform within the same few milliseconds (the plugin hops a microtask or two).
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final soundFirst = audio.where((c) => c.startsWith('bt_event:')).length;
    expect(soundFirst, greaterThanOrEqualTo(1));
    expect(calls.length, 1);
    sound.orderPlaced('same-tick'); // REST + socket for the same order
    await nextEvent();
    expect(calls.length, 1, reason: 'no duplicate vibration');
    expect(audio.where((c) => c == 'bt_event:stop').length, 1, reason: 'no duplicate sound');
  });

  test('several orders placed back to back: every one sounds and vibrates', () async {
    await settle();
    audio.clear();
    for (var i = 0; i < 5; i++) {
      sound.orderPlaced('b$i');
    }
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(audio.where((c) => c == 'bt_event:stop').length, 5, reason: 'five orders, five sounds');
    expect(calls.length, 5, reason: 'gaps of 120 ms: each order keeps its own vibration');
  });

  test('closing one position plays one full sound immediately', () async {
    await settle();
    audio.clear();
    final t0 = DateTime.now();
    await sound.tradeClose();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(audio.where((c) => c == 'bt_event:stop').length, 1);
    expect(DateTime.now().difference(t0).inMilliseconds, lessThan(100), reason: 'no delay on a single event');
    await nextEvent();
    expect(audio.where((c) => c == 'bt_event:stop').length, 1);
    expect(calls.length, 1);
  });

  test('closing 40 positions plays 40 sounds in about 2 s, none dropped, vibration does not block', () async {
    await settle();
    await nextEvent();
    audio.clear();
    final times = <int>[];
    final t0 = DateTime.now();
    final prev = audio.length;
    expect(prev, 0);
    await sound.tradeClose(count: 40);
    // Sample the plugin's stop() (first call of each sound) as it happens.
    var seen = 0;
    while (DateTime.now().difference(t0).inMilliseconds < 3500) {
      final n = audio.where((c) => c == 'bt_event:stop').length;
      while (seen < n) {
        times.add(DateTime.now().difference(t0).inMilliseconds);
        seen++;
      }
      if (n >= 40) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(seen, 40, reason: 'every close has its sound');
    // ignore: avoid_print
    print('40 closes: first ${times.first} ms, last ${times.last} ms');
    expect(times.last, inInclusiveRange(1700, 2600), reason: '40 sounds spread over about two seconds: ${times.last} ms');
    await nextEvent();
    expect(audio.where((c) => c == 'bt_event:stop').length, 40, reason: 'exactly 40, no duplicates');
    expect(calls.length, lessThanOrEqualTo(25), reason: 'vibration is thinned out in a burst, not one per click');
    expect(calls.length, greaterThanOrEqualTo(10));
  });

  test('a burst followed by another event: queued behind it, nothing lost', () async {
    await settle();
    await nextEvent();
    audio.clear();
    sound.tradeClose(count: 3);
    sound.orderPlaced('late');
    sound.tradeClose();
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(audio.where((c) => c == 'bt_event:stop').length, 5);
  });

  test('the same order confirmed twice (REST + socket) vibrates once', () async {
    sound.orderPlaced('o7');
    sound.orderPlaced('o7');
    await settle();
    expect(calls.length, 1);
  });

  test('without the native bridge (or a vibrator) the old haptic still fires, nothing throws', () async {
    await nextEvent(); // previous test's click has finished
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SoundService.haptics, (call) async => false);
    await sound.tradeClose();
    await settle();
    expect(platformHaptics, 1, reason: 'no vibrator: fall back to the touch tick');
    await nextEvent();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SoundService.haptics, (call) async => throw PlatformException(code: 'x'));
    await sound.error();
    await settle();
    expect(platformHaptics, 2, reason: 'bridge error: fall back, never fail the trade');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SoundService.haptics, null);
    await nextEvent();
    await sound.orderModified(); // no handler at all: MissingPluginException
    await settle();
    expect(platformHaptics, 3);
  });

  test('other platforms keep the touch haptic and never touch the Android bridge', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await nextEvent();
    await sound.tradeClose();
    await settle();
    expect(calls, isEmpty);
    expect(platformHaptics, 1);
  });
}
