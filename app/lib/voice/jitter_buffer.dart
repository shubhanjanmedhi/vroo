// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:collection';
import 'dart:typed_data';

/// What to do for the next 20 ms of one sender's voice.
sealed class Playout {}

final class PlayFrame extends Playout {
  PlayFrame(this.opus);

  final Uint8List opus;
}

/// The frame due is missing but the one after it is here: decode [nextOpus] with FEC to rebuild the missing frame.
final class RecoverFrame extends Playout {
  RecoverFrame(this.nextOpus);

  final Uint8List nextOpus;
}

/// The frame due is missing: let the decoder conceal it.
final class ConcealFrame extends Playout {}

/// One sender's voice frames, put in as they arrive and taken out in order every 20 ms (architecture §4.2).
/// Playback starts once [startFrames] are held, and never runs more than [maxFrames] behind the newest frame.
class JitterBuffer {
  JitterBuffer({this.startFrames = 3, this.maxFrames = 15, this.tailConcealFrames = 2});

  final int startFrames, maxFrames, tailConcealFrames;

  final _held = SplayTreeMap<int, Uint8List>();
  int? _due; // the frame to play next; null while quiet
  int? _acceptFrom; // frames below this have had their turn, and are late
  int _tail = 0; // frames concealed since the buffer ran dry
  int played = 0, recovered = 0, concealed = 0, late = 0, skipped = 0;

  /// Frames that didn't arrive in time inside a talk spurt, rebuilt or concealed; not the tail after a talker stops.
  int lost = 0;

  /// Frames held.
  int get depth => _held.length;

  void put(int frameNo, Uint8List opus) {
    final acceptFrom = _acceptFrom;
    if (acceptFrom != null && frameNo < acceptFrom) {
      late++;
      return;
    }
    if (_held.containsKey(frameNo)) return;
    _held[frameNo] = opus;
    final newest = _held.lastKey()!, oldest = _due ?? _held.firstKey()!;
    if (newest - oldest + 1 > maxFrames) {
      // Skip ahead by frame number, so a few scattered frames can't keep playback far behind.
      final keepFrom = newest - startFrames + 1;
      while (_held.firstKey()! < keepFrom) {
        _held.remove(_held.firstKey());
        skipped++;
      }
      if (_due != null) _due = keepFrom;
      _acceptFrom = keepFrom;
    }
  }

  /// Called once every 20 ms; null means this sender is quiet.
  Playout? next() {
    var due = _due;
    if (due == null) {
      if (_held.length < startFrames) return null;
      due = _held.firstKey()!;
      _tail = 0;
    }
    final Playout out;
    final frame = _held.remove(due);
    if (frame != null) {
      out = PlayFrame(frame);
      played++;
      _tail = 0;
    } else if (_held[due + 1] case final nextOpus?) {
      out = RecoverFrame(nextOpus);
      recovered++;
      lost++;
      _tail = 0;
    } else if (_held.isNotEmpty || _tail < tailConcealFrames) {
      out = ConcealFrame();
      concealed++;
      if (_held.isEmpty) {
        _tail++;
      } else {
        lost++;
      }
    } else {
      _due = null; // the talker stopped: wait for the next spurt
      return null;
    }
    _due = due + 1;
    _acceptFrom = due + 1;
    return out;
  }
}
