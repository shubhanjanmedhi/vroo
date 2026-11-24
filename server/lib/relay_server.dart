// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The relay server (architecture §4.9): forwards each group's sealed packets between the phones that send them. It
// reads only the plain envelope and header, never the payload, and keeps nothing but who sent for which group.
import 'dart:async';
import 'dart:io';

import 'package:vroo_protocol/vroo_protocol.dart';

const _addressRate = 200, _addressBurst = 400; // a group's own limit is in RelayTable
const _limiterIdleMs = 60000; // per-address state is dropped this long after its last datagram

class RelayServer {
  RelayServer._(this._socket, this._nowMs) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = _socket.receive();
      if (d != null) _handle(d);
    }, onError: (Object _) => _bump('drop_send')); // dart:io reports a refused send here, after send() returned
  }

  /// Binds to [port] (0 picks a free one) on [address] (every IPv4 address by default). [nowMs], and a [socket] to use
  /// instead of binding one, are for tests.
  static Future<RelayServer> bind(
      {int port = relayPort, InternetAddress? address, int Function()? nowMs, RawDatagramSocket? socket}) async {
    socket ??= await RawDatagramSocket.bind(address ?? InternetAddress.anyIPv4, port);
    final watch = Stopwatch()..start();
    return RelayServer._(socket, nowMs ?? () => watch.elapsedMilliseconds);
  }

  final RawDatagramSocket _socket;
  final int Function() _nowMs;
  final _table = RelayTable();
  final _addresses = <String, ({InternetAddress ip, int port, RateLimiter limit, int lastMs})>{};
  int _lastSweepMs = 0;

  /// rx, tx, drop_size, drop_rate, drop_cap, drop_send and drop_full, since the start.
  final counters = {'rx': 0, 'tx': 0, 'drop_size': 0, 'drop_rate': 0, 'drop_cap': 0, 'drop_send': 0, 'drop_full': 0};

  int get port => _socket.port;

  String statusLine() => 'groups=${_table.groups} addresses=${_table.addresses} rx=${counters['rx']} '
      'tx=${counters['tx']} drop_size=${counters['drop_size']} drop_rate=${counters['drop_rate']} '
      'drop_cap=${counters['drop_cap']} drop_send=${counters['drop_send']} drop_full=${counters['drop_full']}';

  Future<void> close() async => _socket.close();

  void _handle(Datagram d) {
    final now = _nowMs();
    _bump('rx');
    final parsed = d.port == 0 ? null : parseRelayDatagram(d.data); // nothing can be sent back to port 0
    if (parsed == null) return _bump('drop_size');
    final key = '${d.address.address}:${d.port}';
    final group = _table.heard(parsed.groupTag, key, now);
    if (group == null) return _bump('drop_full');
    final limit = _addresses[key]?.limit ?? RateLimiter(perSecond: _addressRate, burst: _addressBurst);
    _addresses[key] = (ip: d.address, port: d.port, limit: limit, lastMs: now);
    _sweep(now);
    if (!limit.take(now) || !group.limit.take(now)) return _bump('drop_rate');
    final type = parsed.header.type;
    if ((type == PacketType.voice || type == PacketType.fill) && !group.cap.admit(parsed.header.src, now)) {
      return _bump('drop_cap');
    }
    for (final target in group.to) {
      final to = _addresses[target];
      if (to == null) continue;
      _socket.send(d.data, to.ip, to.port);
      _bump('tx');
    }
  }

  void _bump(String counter) => counters[counter] = counters[counter]! + 1;

  /// Forgets addresses (and their rate limits) idle for a minute.
  void _sweep(int now) {
    if (now - _lastSweepMs < 10000) return;
    _lastSweepMs = now;
    _addresses.removeWhere((_, a) => now - a.lastMs > _limiterIdleMs);
  }
}
