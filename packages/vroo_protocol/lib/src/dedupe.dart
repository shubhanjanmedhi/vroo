// SPDX-License-Identifier: GPL-3.0-or-later
import 'constants.dart';

/// Lets each packet through once, however many paths it arrives by (architecture §5.2).
class Dedupe {
  Dedupe({this.windowMs = dedupeWindowMs});

  final int windowMs;
  final _firstSeen = <(int, int, int), int>{};
  int _lastPurgeMs = 0;

  /// True for the first copy of packet (src, session, seq) within the window, false for the copies after it.
  bool firstTime(int src, int session, int seq, int nowMs) {
    if (nowMs - _lastPurgeMs > 1000) {
      _firstSeen.removeWhere((_, seen) => nowMs - seen > windowMs);
      _lastPurgeMs = nowMs;
    }
    final key = (src, session, seq);
    final seen = _firstSeen[key];
    if (seen != null && nowMs - seen <= windowMs) return false;
    _firstSeen[key] = nowMs;
    return true;
  }

  /// Live entries.
  int get size => _firstSeen.length;
}
