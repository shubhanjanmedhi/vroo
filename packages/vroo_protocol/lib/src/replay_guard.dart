// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'constants.dart';
import 'packet.dart';

enum ReplayVerdict { accepted, duplicate, tooOld, staleBeat, noRecentBeat }

class _Session {
  _Session(int window) : bits = Uint32List(window ~/ 32);

  final Uint32List bits; // bit (seq % window) set: seq was accepted; covers the newest seq and the window below it
  int highest = -1;
  int lastMs = 0;
  int? lastBeatMs;

  bool seen(int seq) => bits[(seq % (bits.length * 32)) >> 5] & (1 << (seq & 31)) != 0;

  void mark(int seq) {
    final window = bits.length * 32;
    if (seq > highest) {
      if (highest < 0 || seq - highest >= window) {
        bits.fillRange(0, bits.length, 0);
      } else {
        for (var s = highest + 1; s <= seq; s++) {
          bits[(s % window) >> 5] &= ~(1 << (s & 31));
        }
      }
      highest = seq;
    }
    bits[(seq % window) >> 5] |= 1 << (seq & 31);
  }
}

/// Replay protection for packets that have already been authenticated (architecture §5.2). Strangers who hear the
/// boxes or sit on the internet path can record sealed packets and send them again later, after the 10 s dedupe
/// window. Each (src, session) keeps a window of the sequence numbers it has accepted; a session's voice and echoes
/// count only while its heartbeats keep arriving; and a heartbeat counts only if the sender's wall clock in it is
/// close to this phone's, so a session recorded long ago can't come back to life.
class ReplayGuard {
  ReplayGuard({this.window = 1024, this.liveMs = 40000, this.skewMs = 600000, this.forgetMs = 600000})
      : assert(window % 32 == 0);

  final int window, liveMs, skewMs, forgetMs;
  final _sessions = <(int, int), _Session>{};
  int _lastPurgeMs = 0;

  /// [nowMs] is the monotonic clock; [wallMs] is this phone's wall clock in ms since the epoch; [beatSentAtMs] is
  /// the BEAT's sentAt, required for type BEAT. A refused packet changes nothing.
  ReplayVerdict check(PacketHeader h, {required int nowMs, required int wallMs, int? beatSentAtMs}) {
    _purge(nowMs);
    if (h.type == PacketType.beat) {
      final skew = ((wallMs - (beatSentAtMs ?? 0)) & 0xFFFFFFFF).toSigned(32); // sentAt is the low 32 bits
      if (skew.abs() > skewMs) return ReplayVerdict.staleBeat;
    }
    final key = (h.src, h.session);
    final session = _sessions[key];
    if (session != null) {
      if (h.seq <= session.highest - window) return ReplayVerdict.tooOld;
      if (h.seq <= session.highest && session.seen(h.seq)) return ReplayVerdict.duplicate;
    }
    if (h.type == PacketType.voice || h.type == PacketType.echo) {
      final lastBeat = session?.lastBeatMs;
      if (lastBeat == null || nowMs - lastBeat > liveMs) return ReplayVerdict.noRecentBeat;
    }
    final s = session ?? (_sessions[key] = _Session(window));
    s
      ..mark(h.seq)
      ..lastMs = nowMs;
    if (h.type == PacketType.beat) s.lastBeatMs = nowMs;
    return ReplayVerdict.accepted;
  }

  void _purge(int nowMs) {
    if (nowMs - _lastPurgeMs <= 1000) return;
    _lastPurgeMs = nowMs;
    _sessions.removeWhere((_, s) => nowMs - s.lastMs > forgetMs);
  }
}
