// SPDX-License-Identifier: GPL-3.0-or-later

enum SlotDecision { send, hold, holdWithBusyTone }

/// Up to [n] voices at once (VO7, architecture §4.2): a rider who starts talking while [n] others are holds back,
/// hears a busy tone at most every [busyEveryMs], and is carried as soon as a slot frees. A rider already talking
/// keeps their slot.
class TalkSlots {
  TalkSlots({this.n = 4, this.activeMs = 500, this.busyEveryMs = 5000});

  final int n, activeMs, busyEveryMs;

  final _lastHeardMs = <int, int>{};
  int? _lastSentMs, _lastBusyMs;

  /// Another rider's voice frame arrived.
  void heard(int src, int nowMs) => _lastHeardMs[src] = nowMs;

  /// For each frame the voice gate wants to send.
  SlotDecision decide(int nowMs) {
    final sent = _lastSentMs;
    _lastHeardMs.removeWhere((_, heard) => nowMs - heard > activeMs);
    if ((sent != null && nowMs - sent <= activeMs) || _lastHeardMs.length < n) {
      _lastSentMs = nowMs;
      return SlotDecision.send;
    }
    final busy = _lastBusyMs;
    if (busy != null && nowMs - busy < busyEveryMs) return SlotDecision.hold;
    _lastBusyMs = nowMs;
    return SlotDecision.holdWithBusyTone;
  }
}
