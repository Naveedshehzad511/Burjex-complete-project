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

  test('every trade event vibrates for real on Android, each with its own pattern', () async {
    sound.orderPlaced('o1'); // market buy / sell, pending placed
    await settle();
    sound.tradeOpen();
    await settle();
    await sound.tradeClose(); // position close, partial close, close all
    await settle();
    await sound.orderModified(); // order / position / SL / TP modified
    await settle();
    await sound.orderCancelled(); // pending order cancelled
    await settle();
    await sound.error(); // rejected / failed
    await settle();

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
      await settle();
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

  test('the same order confirmed twice (REST + socket) vibrates once', () async {
    sound.orderPlaced('o7');
    sound.orderPlaced('o7');
    await settle();
    expect(calls.length, 1);
  });

  test('without the native bridge (or a vibrator) the old haptic still fires, nothing throws', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SoundService.haptics, (call) async => false);
    await sound.tradeClose();
    await settle();
    expect(platformHaptics, 1, reason: 'no vibrator: fall back to the touch tick');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SoundService.haptics, (call) async => throw PlatformException(code: 'x'));
    await sound.error();
    await settle();
    expect(platformHaptics, 2, reason: 'bridge error: fall back, never fail the trade');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SoundService.haptics, null);
    await sound.orderModified(); // no handler at all: MissingPluginException
    await settle();
    expect(platformHaptics, 3);
  });

  test('other platforms keep the touch haptic and never touch the Android bridge', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await sound.tradeClose();
    await settle();
    expect(calls, isEmpty);
    expect(platformHaptics, 1);
  });
}
