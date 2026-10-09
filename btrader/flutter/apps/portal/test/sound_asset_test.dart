import 'dart:typed_data';

import 'package:burjex_portal/services/sound_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The order-event click (open / close / pending placed / modified): the original recording
/// without its leading / trailing silence, loud enough, starting at once, so it is heard within
/// milliseconds of the confirmation and not cut short.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('order_event.wav is bundled, a valid short mono WAV that starts at the click', () async {
    final data = await rootBundle.load('assets/${SoundService.eventAsset}');
    final b = data.buffer.asByteData(data.offsetInBytes, data.lengthInBytes);
    String tag(int o) => String.fromCharCodes([for (var i = 0; i < 4; i++) b.getUint8(o + i)]);
    expect(tag(0), 'RIFF');
    expect(tag(8), 'WAVE');
    expect(b.getUint16(20, Endian.little), 1, reason: 'PCM');
    final channels = b.getUint16(22, Endian.little);
    final rate = b.getUint32(24, Endian.little);
    expect(b.getUint16(34, Endian.little), 16, reason: '16-bit');
    // Locate the data chunk.
    var o = 12;
    while (tag(o) != 'data') {
      o += 8 + b.getUint32(o + 4, Endian.little);
    }
    final bytes = b.getUint32(o + 4, Endian.little);
    final start = o + 8;
    final frames = bytes ~/ (2 * channels);
    final ms = frames * 1000 / rate;
    expect(ms, inInclusiveRange(300, 600), reason: 'the original click with its whole decay, only the silence around it cropped from the ~0.9 s clip: $ms ms');

    double at(int frame) => b.getInt16(start + frame * 2 * channels, Endian.little) / 32768;
    final firstMs = (rate * 0.010).round();
    final headPeak = [for (var i = 0; i < firstMs; i++) at(i).abs()].reduce((a, c) => a > c ? a : c);
    expect(headPeak, greaterThan(0.05), reason: 'no leading silence: the click starts within the first 10 ms');
    final peak = [for (var i = 0; i < frames; i++) at(i).abs()].reduce((a, c) => a > c ? a : c);
    expect(peak, inInclusiveRange(0.6, 1.0), reason: 'clearly audible, not clipped');
    expect(at(frames - 1).abs(), lessThan(0.01), reason: 'faded out: no pop at the end');
  });
}
