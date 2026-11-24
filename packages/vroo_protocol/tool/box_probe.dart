// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bench probe for one box, run on a Mac joined to the box's Wi-Fi (docs/test-plan.md). From packages/vroo_protocol:
//   dart run tool/box_probe.dart setup --password abcd-efgh-jkmn-pqrs --tag a9968d2a1c900625 --channel 6
//   dart run tool/box_probe.dart bridge --tag a9968d2a1c900625
// --box <ip> points it somewhere other than 192.168.4.1.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:vroo_protocol/vroo_protocol.dart';

import '../test/fixtures.dart';
import '../test/hex.dart';

late InternetAddress box;

Future<void> main(List<String> args) async {
  final opts = {for (var i = 1; i + 1 < args.length; i += 2) args[i]: args[i + 1]};
  box = InternetAddress(opts['--box'] ?? boxIp);
  final tag = opts['--tag'];
  switch (args.firstOrNull) {
    case 'setup' when tag != null && opts['--password'] != null && opts['--channel'] != null:
      await setup(opts['--password']!, unhex(tag), int.parse(opts['--channel']!));
    case 'bridge' when tag != null:
      await bridge(unhex(tag));
    default:
      stderr.writeln('usage: box_probe.dart setup --password P --tag HEX --channel C | bridge --tag HEX  [--box IP]');
      exit(64);
  }
  exit(0);
}

Future<void> setup(String password, Uint8List tag, int channel) async {
  final config = encodeBoxConfig(BoxConfig(groupTag: tag, channel: channel, wifiPassword: password));
  check(decodeBoxConfig(config) != null, 'a valid config (8-byte tag, channel 1, 6 or 11, password of 8-63 characters)');
  final p = await Peer.open();
  p.send(config, boxControlPort);
  final reply = await p.next(boxControlPort, const Duration(seconds: 3), (d) => decodeBoxStatus(d)?.setupMode == true);
  check(reply != null, 'a BOX_STATUS with setupMode true within 3 s');
  print('setup ok, box ssid ${boxSsid(decodeBoxStatus(reply!)!.boxId)}');
}

Future<void> bridge(Uint8List tag) async {
  final a = await Peer.open(), b = await Peer.open();
  a.send([0], boxDataPort);
  b.send([0], boxControlPort);
  // A status reaching a socket proves the box registered it. Sockets from a run less than 30 s ago still count.
  bool twoPhones(Uint8List d) => (decodeBoxStatus(d)?.phones ?? 0) >= 2;
  final registered = await Future.wait([
    a.next(boxControlPort, const Duration(seconds: 3), twoPhones),
    b.next(boxControlPort, const Duration(seconds: 3), twoPhones),
  ]);
  check(registered.every((s) => s != null), 'both phones get a BOX_STATUS (phones >= 2) within 3 s');

  final keys = await GroupKeys.derive(secret);
  final header = PacketHeader(
      version: protocolVersion, type: PacketType.beat, ttl: originTtl, src: 0x01020304,
      session: Random().nextInt(1 << 32), seq: 7);
  final envelope = wrapEnvelope(tag, await Sealer(keys).seal(header, payload));
  a.send(envelope, boxDataPort);
  final forwarded = await b.next(boxDataPort, const Duration(milliseconds: 500));
  check(forwarded != null && hex(forwarded) == hex(envelope), 'B receives the envelope within 500 ms');

  await expectDropped(a, b, envelope, 'a duplicate', (s) => s.dropDup);
  await expectDropped(a, b, Uint8List.fromList(envelope)..[0] ^= 0xFF, 'a foreign group tag', (s) => s.dropTag);
  print('box probe: all checks passed');
}

/// A sends [datagram]; B must not get it, and B's next status must show [counter] up by one.
Future<void> expectDropped(Peer a, Peer b, Uint8List datagram, String what, int Function(BoxStatus) counter) async {
  final before = await b.status();
  a.send(datagram, boxDataPort);
  check(await b.next(boxDataPort, const Duration(milliseconds: 500)) == null, '$what is not forwarded');
  b.drain();
  final after = await b.status();
  check(counter(after) == counter(before) + 1, '$what is counted once (${counter(before)} -> ${counter(after)})');
}

void check(bool ok, String what) {
  if (ok) return;
  print('box probe: FAILED: $what');
  exit(1);
}

/// One UDP socket playing a phone. Everything it receives is queued, so nothing is missed between checks.
class Peer {
  Peer._(this._socket) {
    _socket.listen((event) {
      final d = event == RawSocketEvent.read ? _socket.receive() : null;
      if (d != null) _inbox.add(d);
    });
  }

  static Future<Peer> open() async => Peer._(await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0));

  final RawDatagramSocket _socket;
  final _inbox = <Datagram>[];

  void send(List<int> bytes, int port) {
    var error = '';
    try {
      if (_socket.send(bytes, box, port) == bytes.length) return;
    } on SocketException catch (e) {
      error = ' (${e.osError?.message ?? e.message})';
    }
    check(false, 'sending to the box$error. On a Mac, "No route to host" usually means the app running this probe '
        'has no Local Network access: System Settings > Privacy & Security > Local Network');
  }

  /// The next datagram from the box's [port] that passes [where], or null after [timeout]. Skipped ones are dropped.
  Future<Uint8List?> next(int port, Duration timeout, [bool Function(Uint8List)? where]) async {
    final end = DateTime.now().add(timeout);
    do {
      while (_inbox.isNotEmpty) {
        final d = _inbox.removeAt(0);
        if (d.address == box && d.port == port && (where == null || where(d.data))) return d.data;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    } while (DateTime.now().isBefore(end));
    return null;
  }

  /// The next BOX_STATUS (the box sends one every second).
  Future<BoxStatus> status() async {
    final d = await next(boxControlPort, const Duration(milliseconds: 1500), (d) => decodeBoxStatus(d) != null);
    check(d != null, 'a BOX_STATUS every second');
    return decodeBoxStatus(d!)!;
  }

  void drain() => _inbox.clear();
}
