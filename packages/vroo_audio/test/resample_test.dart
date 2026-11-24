// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vroo_audio/vroo_audio.dart';

void main() {
  test('32 kHz to 16 kHz halves the length and keeps a constant level', () {
    final out = resample(Int16List(640)..fillRange(0, 640, 1000), 32000, 16000);
    expect(out.length, 320);
    expect(out.every((s) => s == 1000), isTrue);
  });

  test('22.05 kHz to 16 kHz gives round(n × 16000 ÷ 22050) samples', () {
    expect(resample(Int16List(2205), 22050, 16000).length, 1600);
    expect(resample(Int16List(1000), 22050, 16000).length, (1000 * 16000 / 22050).round());
  });

  test('the same rate gives a copy', () {
    final pcm = Int16List.fromList([1, 2, 3]);
    final out = resample(pcm, 16000, 16000);
    expect(out, pcm);
    expect(identical(out, pcm), isFalse);
  });

  test('a ramp stays a ramp when upsampled', () {
    expect(resample(Int16List.fromList([0, 100, 200]), 8000, 16000), [0, 50, 100, 150, 200, 200]);
  });
}
