// SPDX-License-Identifier: GPL-3.0-or-later
//
// The relay server's rules (architecture §4.9), and the talker cap it shares with the boxes (§4.8). Pure Dart, so the
// server, the app's tests and the mesh simulator all run the same code.
import 'dart:math';
import 'dart:typed_data';

import 'envelope.dart';
import 'packet.dart';

const relayPort = 47100, maxRelayDatagram = 512, relayForgetMs = 30000;

/// Which addresses ("host:port") of each group the relay forwards to, with the rate limit and talker cap each group
/// shares. A group, and its limit and cap, are forgotten with its last address.
class RelayTable {
  RelayTable({this.forgetMs = relayForgetMs, this.maxPerGroup = 256, this.maxPerHost = 16, this.maxAddresses = 50000});

  final int forgetMs;

  /// Caps on new addresses, so forged ones can't grow the relay's memory or work without bound (architecture §5.2):
  /// in one group, from one host in one group, and in all.
  final int maxPerGroup, maxPerHost, maxAddresses;
  final _groups = <String, _Group>{};
  int _count = 0, _lastPurgeMs = 0;

  /// Records that [address] sent for [groupTag] (hex) at [nowMs], and returns where to forward it (every other
  /// address of that group heard within [forgetMs]) with the group's rate limit and talker cap. Null, and nothing
  /// recorded, when a new address would pass a cap.
  ({List<String> to, RateLimiter limit, TalkerCap cap})? heard(String groupTag, String address, int nowMs) {
    _purge(nowMs);
    final known = _groups[groupTag];
    if (known?.seen.containsKey(address) != true) {
      final host = _host(address);
      if (_count >= maxAddresses ||
          known != null &&
              (known.seen.length >= maxPerGroup ||
                  known.seen.keys.where((a) => _host(a) == host).length >= maxPerHost)) {
        return null;
      }
      _count++;
    }
    final group = _groups.putIfAbsent(groupTag, _Group.new)..seen[address] = nowMs;
    return (
      to: [
        for (final MapEntry(key: other, value: seen) in group.seen.entries)
          if (other != address && nowMs - seen <= forgetMs) other,
      ],
      limit: group.limit,
      cap: group.cap,
    );
  }

  /// Groups and addresses held, for the server's log.
  int get groups => _groups.length;
  int get addresses => _groups.values.fold(0, (n, g) => n + g.seen.length);

  void _purge(int nowMs) {
    if (nowMs - _lastPurgeMs <= 1000) return;
    _lastPurgeMs = nowMs;
    for (final group in _groups.values) {
      group.seen.removeWhere((_, seen) => nowMs - seen > forgetMs);
    }
    _groups.removeWhere((_, group) => group.seen.isEmpty);
    _count = addresses;
  }

  static String _host(String address) {
    final colon = address.lastIndexOf(':');
    return colon < 0 ? address : address.substring(0, colon);
  }
}

class _Group {
  final seen = <String, int>{}; // address → when it last sent
  final limit = RateLimiter(perSecond: 2000, burst: 4000);
  final cap = TalkerCap();
}

/// A token bucket: [perSecond] tokens a second, holding at most [burst]. It starts full.
class RateLimiter {
  RateLimiter({required this.perSecond, required this.burst}) : _tokens = burst.toDouble();

  final int perSecond, burst;
  double _tokens;
  int? _lastMs;

  bool take(int nowMs) {
    final last = _lastMs;
    if (last != null && nowMs > last) _tokens = min(burst.toDouble(), _tokens + (nowMs - last) * perSecond / 1000);
    _lastMs = nowMs;
    if (_tokens < 1) return false;
    _tokens -= 1;
    return true;
  }
}

/// At most [n] riders' voice at once (the boxes and the relay alike, architecture §4.8 and §4.9). A rider holds a
/// slot while their VOICE or FILL was admitted in the last [activeMs]; heartbeats and echoes are never capped.
class TalkerCap {
  TalkerCap({this.n = 4, this.activeMs = 1000});

  final int n, activeMs;
  final _last = <int, int>{}; // rider → when their voice was last admitted

  /// For a VOICE or FILL packet from [src]: whether it may go on.
  bool admit(int src, int nowMs) {
    _last.removeWhere((_, t) => nowMs - t > activeMs);
    if (!_last.containsKey(src) && _last.length >= n) return false;
    _last[src] = nowMs;
    return true;
  }

  /// Riders holding a slot at [nowMs].
  int active(int nowMs) => _last.values.where((t) => nowMs - t <= activeMs).length;
}

/// The group tag (hex) and header of a relay datagram, or null unless it's 39–512 bytes with a protocol v1 header.
({String groupTag, PacketHeader header})? parseRelayDatagram(Uint8List d) {
  if (d.length > maxRelayDatagram) return null;
  final envelope = unwrapEnvelope(d); // null below 39 bytes
  final header = envelope == null ? null : decodeHeader(envelope.packet);
  if (envelope == null || header == null) return null;
  return (groupTag: _hex(envelope.groupTag), header: header);
}

String _hex(Uint8List b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
