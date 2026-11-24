// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/voice/mixer.dart';

Int16List sineAt(double fullScale) =>
    Int16List.fromList([for (var i = 0; i < 320; i++) (fullScale * 32767 * sin(2 * pi * 1000 * i / 16000)).round()]);

void main() {
  test('one quiet voice passes through unchanged', () {
    final voice = sineAt(0.1); // about -20 dBFS
    expect(mix([voice]), voice);
  });

  test('two loud voices never wrap around', () {
    final a = sineAt(0.9), b = sineAt(0.9);
    final out = mix([a, b]);
    for (var i = 0; i < 320; i++) {
      final sum = a[i] + b[i];
      expect(out[i].sign, sum.sign, reason: 'sample $i');
      expect(out[i].abs(), lessThanOrEqualTo(32767));
    }
    expect(out.reduce(max), greaterThan(30000)); // squeezed near full scale, not halved
  });

  test('no voices is silence', () {
    expect(mix([]), Int16List(320));
  });
}
