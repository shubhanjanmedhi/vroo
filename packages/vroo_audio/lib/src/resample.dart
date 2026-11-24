// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

/// [pcm] at [fromRate] turned into [toRate], by linear interpolation; the same rate gives a copy.
// ponytail: no anti-alias filter, fine for speech from the phone's voice; add one if downsampled speech sounds harsh.
Int16List resample(Int16List pcm, int fromRate, int toRate) {
  if (fromRate == toRate) return Int16List.fromList(pcm);
  final out = Int16List((pcm.length * toRate / fromRate).round());
  final step = fromRate / toRate, last = pcm.length - 1;
  for (var i = 0; i < out.length; i++) {
    final x = i * step, j = x.floor();
    final a = pcm[j.clamp(0, last)], b = pcm[(j + 1).clamp(0, last)];
    out[i] = (a + (b - a) * (x - j)).round();
  }
  return out;
}
