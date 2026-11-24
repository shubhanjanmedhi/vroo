// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/voice/tones.dart';

void main() {
  test('the busy tone is two 150 ms beeps at -12 dBFS', () {
    final tone = busyTone();
    expect(tone.length, 6400);
    expect(tone.map((s) => s.abs()).reduce(max) / 32768, inInclusiveRange(0.24, 0.26));
    expect(tone.sublist(2400, 4000).every((s) => s == 0), isTrue);
    expect(tone.sublist(4000).any((s) => s != 0), isTrue);
  });

  test('the back tone is 120 ms', () {
    final tone = backTone();
    expect(tone.length, 1920);
    expect(tone.map((s) => s.abs()).reduce(max) / 32768, inInclusiveRange(0.24, 0.26));
  });
}
