// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';
import 'dart:typed_data';

/// RMS level of [frame] in dBFS, floored at -90.
double frameDb(Int16List frame) {
  var sum = 0.0;
  for (final s in frame) {
    sum += s * s;
  }
  final rms = sqrt(sum / frame.length);
  return rms < 1 ? -90 : max(-90, 20 * log(rms / 32768) / ln10);
}

/// Picks out the mic frames worth sending (architecture §4.2): energy against an adaptive noise floor, with a hang
/// so word endings aren't cut and a pre-roll so word starts aren't either. Silence sends nothing.
class VoiceGate {
  VoiceGate({
    this.thresholdDb = 12,
    this.hangFrames = 15,
    this.preRollFrames = 2,
    this.minDb = -55,
    this.floorRiseDbPerFrame = 0.1,
  });

  /// How far above the noise floor speech must be: the ride screen's mic sensitivity.
  double thresholdDb;
  final int hangFrames, preRollFrames;
  final double minDb, floorRiseDbPerFrame;

  final _preRoll = <Int16List>[];
  double? _floor;
  int _hangLeft = 0;
  bool _open = false;

  bool get open => _open;

  /// The frames to send now: none while closed; the pre-roll frames and then [frame] when it opens; then one at a
  /// time until the hang runs out.
  List<Int16List> push(Int16List frame) {
    final db = frameDb(frame);
    final floor = _floor; // judged against the floor before this frame
    _floor = floor == null || db < floor ? db : floor + min(db - floor, floorRiseDbPerFrame);
    final loud = floor != null && db >= minDb && db > floor + thresholdDb;
    if (loud) {
      _hangLeft = hangFrames;
      if (_open) return [frame];
      _open = true;
      final opening = [..._preRoll, frame];
      _preRoll.clear();
      return opening;
    }
    if (_open) {
      if (--_hangLeft <= 0) _open = false;
      return [frame];
    }
    _preRoll.add(frame);
    if (_preRoll.length > preRollFrames) _preRoll.removeAt(0);
    return const <Int16List>[];
  }
}
