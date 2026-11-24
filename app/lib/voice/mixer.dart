// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';
import 'dart:typed_data';

const _frameSamples = 320;

/// Below this share of full scale, samples pass unchanged; above it, they're squeezed instead of wrapping.
const _knee = 0.6;

/// Sums 20 ms frames of 320 samples (voices and alerts) into one, with a soft clip. No frames gives silence.
Int16List mix(List<Int16List> frames) {
  final out = Int16List(_frameSamples);
  if (frames.isEmpty) return out;
  for (var i = 0; i < _frameSamples; i++) {
    var sum = 0;
    for (final f in frames) {
      sum += f[i];
    }
    final x = sum / 32768, a = x.abs();
    final y = a <= _knee ? x : x.sign * (_knee + (1 - _knee) * _tanh((a - _knee) / (1 - _knee)));
    out[i] = (y * 32768).round().clamp(-32768, 32767);
  }
  return out;
}

double _tanh(double v) {
  if (v > 20) return 1;
  final e = exp(2 * v);
  return (e - 1) / (e + 1);
}
