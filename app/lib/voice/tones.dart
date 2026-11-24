// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';
import 'dart:typed_data';

const _rate = 16000;
const _amplitude = 0.251188643 * 32767; // -12 dBFS
const _fadeSamples = 80; // 5 ms, so a beep doesn't click

List<int> _beep(double hz, int ms) {
  final n = _rate * ms ~/ 1000;
  return [
    for (var i = 0; i < n; i++)
      (_amplitude * min(1.0, min(i, n - 1 - i) / _fadeSamples) * sin(2 * pi * hz * i / _rate)).round(),
  ];
}

/// "Wait for a slot" (spec 7.5): two 150 ms beeps at 425 Hz, 100 ms apart, as 16 kHz PCM.
Int16List busyTone() => Int16List.fromList([..._beep(425, 150), ...List.filled(1600, 0), ..._beep(425, 150)]);

/// Played before "[Name] is back": one 120 ms beep at 880 Hz, as 16 kHz PCM.
Int16List backTone() => Int16List.fromList(_beep(880, 120));
