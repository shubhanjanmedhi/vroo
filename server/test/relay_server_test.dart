// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The relay over real UDP on 127.0.0.1, with a clock the test moves.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vroo_protocol/vroo_protocol.dart';
import 'package:vroo_relay/relay_server.dart';

/// The shared protocol test vector: a sealed BEAT in group a9968d2a1c900625 (packages/vroo_protocol/test/fixtures.dart).
const _vector = 'a9968d2a1c900625010310010203040a0b0c0d000000070d0130763dd9b37750eade2038afcac4ca4ded54f5a07110b999e56896';

Uint8List _datagram({int group = 0, int type = PacketType.beat, int src = 0x01020304, int seq = 7}) {
  final d = Uint8List.fromList([for (var i = 0; i < _vector.length; i += 2) int.parse(_vector.substring(i, i + 2), radix: 16)]);
  final b = ByteData.sublistView(d);
  d[0] ^= group; // another group's tag
  d[9] = type;
  b.setUint32(8 + 3, src);
  b.setUint32(8 + 11, seq);
  return d;
}

class _Phone {
  _Phone(this.socket) {
    socket.listen((e) {
      final d = e == RawSocketEvent.read ? socket.receive() : null;
      if (d != null) got.add(d.data);
    });
  }

  final RawDatagramSocket socket;
  final got = <Uint8List>[];

  static Future<_Phone> open() async => _Phone(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));

  void send(RelayServer relay, Uint8List d) => socket.send(d, InternetAddress.loopbackIPv4, relay.port);
}

/// A socket the test hands datagrams to. Like dart:io, a send the system refuses returns 0 and the error arrives on
/// the socket's stream a moment later: Linux refuses every send to port 0, and [refusesAll] refuses the rest too.
class _FakeSocket extends Stream<RawSocketEvent> implements RawDatagramSocket {
  _FakeSocket({this.refusesAll = false});

  final bool refusesAll;
  final _events = StreamController<RawSocketEvent>();
  final _inbox = <Datagram>[];
  final sentTo = <int>[]; // the port of each send

  void deliver(Uint8List data, {required int fromPort}) {
    _inbox.add(Datagram(data, InternetAddress.loopbackIPv4, fromPort));
    _events.add(RawSocketEvent.read);
  }

  @override
  Datagram? receive() => _inbox.isEmpty ? null : _inbox.removeAt(0);

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    sentTo.add(port);
    if (refusesAll || port == 0) _events.addError(const SocketException('Send failed (OS Error: Invalid argument)'));
    return 0;
  }

  @override
  void close() => _events.close();

  @override
  StreamSubscription<RawSocketEvent> listen(void Function(RawSocketEvent event)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _events.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Lets datagrams on 127.0.0.1 arrive and be handled.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  var now = 0;
  late RelayServer relay;
  final phones = <_Phone>[];
  Future<_Phone> phone() async => (phones..add(await _Phone.open())).last;

  setUp(() async {
    now = 0;
    relay = await RelayServer.bind(port: 0, address: InternetAddress.loopbackIPv4, nowMs: () => now);
  });
  tearDown(() async {
    await relay.close();
    for (final p in phones) {
      p.socket.close();
    }
    phones.clear();
  });

  test("a datagram reaches the group's other phone, and not another group's", () async {
    final a = await phone(), b = await phone(), c = await phone();
    b.send(relay, _datagram());
    c.send(relay, _datagram(group: 1));
    await settle();
    a.send(relay, _datagram(seq: 8));
    await settle();
    expect(b.got, hasLength(1));
    expect(c.got, isEmpty);
    expect(a.got, isEmpty); // never back to its sender
  });

  test('a phone whose address changes is reached at the new one', () async {
    final a1 = await phone(), a2 = await phone(), b = await phone();
    a1.send(relay, _datagram(seq: 1));
    await settle();
    now = 1000;
    a2.send(relay, _datagram(seq: 2)); // carrier NAT gave the phone a new port
    await settle();
    now = 2000;
    b.send(relay, _datagram(src: 2, seq: 1));
    await settle();
    expect(a2.got, hasLength(1));
    final a1Before = a1.got.length; // the relay can't tell a1 and a2 are one phone, so a1 heard both while live
    now = 31001; // a1 was last heard at 0, a2 at 1000
    a2.send(relay, _datagram(seq: 3));
    await settle();
    b.send(relay, _datagram(src: 2, seq: 2));
    await settle();
    expect(a2.got, hasLength(2));
    expect(a1.got, hasLength(a1Before)); // forgotten: nothing more goes to the old address
  });

  test('junk, oversized and old-version datagrams are dropped and counted', () async {
    final a = await phone(), b = await phone();
    b.send(relay, _datagram());
    await settle();
    a.send(relay, Uint8List(10));
    a.send(relay, Uint8List(600)..setRange(0, 52, _datagram()));
    a.send(relay, _datagram()..[8] = 2);
    await settle();
    expect(relay.counters['drop_size'], 3);
    expect(b.got, isEmpty);
  });

  test('a flood from one address is limited, and others still get through', () async {
    final a = await phone(), b = await phone();
    b.send(relay, _datagram(src: 2));
    await settle();
    final txBefore = relay.counters['tx']!;
    for (var i = 0; i < 1000; i++) {
      a.send(relay, _datagram(seq: 1000 + i));
    }
    await settle();
    final forwarded = relay.counters['tx']! - txBefore;
    expect(forwarded, lessThanOrEqualTo(400)); // the burst
    expect(forwarded + relay.counters['drop_rate']!, 1000);
    b.send(relay, _datagram(src: 2, seq: 2));
    await settle();
    expect(a.got, hasLength(1));
  });

  test("a fifth talker's voice is dropped, but heartbeats get through", () async {
    final a = await phone(), b = await phone();
    b.send(relay, _datagram(src: 99));
    await settle();
    for (var src = 1; src <= 5; src++) {
      a.send(relay, _datagram(type: PacketType.voice, src: src, seq: 1));
    }
    a.send(relay, _datagram(src: 6, seq: 1)); // a BEAT
    await settle();
    expect(b.got, hasLength(5));
    expect(relay.counters['drop_cap'], 1);
  });

  test('a send the system refuses is counted, and the relay keeps forwarding', () async {
    // A routing blip, a full firewall table, or a phone gone from the Wi-Fi: dart:io reports these after the send.
    final socket = _FakeSocket(refusesAll: true);
    final relay = await RelayServer.bind(socket: socket, nowMs: () => 0);
    socket.deliver(_datagram(src: 1), fromPort: 5001);
    socket.deliver(_datagram(src: 2), fromPort: 5002); // to 5001: refused
    await pumpEventQueue();
    socket.deliver(_datagram(src: 1, seq: 8), fromPort: 5001); // to 5002: refused
    await pumpEventQueue();
    expect(socket.sentTo, [5001, 5002]);
    expect(relay.counters['drop_send'], 2);
  });

  test('a datagram from port 0 is dropped, so nothing is ever sent to port 0', () async {
    final socket = _FakeSocket();
    final relay = await RelayServer.bind(socket: socket, nowMs: () => 0);
    socket.deliver(_datagram(src: 1), fromPort: 0);
    socket.deliver(_datagram(src: 2), fromPort: 5002);
    await pumpEventQueue();
    expect(socket.sentTo, isEmpty);
    expect(relay.counters['drop_size'], 1);
  });

  test('a new address past a cap is dropped, counted, and never sent to', () async {
    final socket = _FakeSocket();
    final relay = await RelayServer.bind(socket: socket, nowMs: () => 0);
    for (var port = 5001; port <= 5017; port++) {
      socket.deliver(_datagram(src: port), fromPort: port); // all from 127.0.0.1: one host has 16 places in a group
    }
    await pumpEventQueue();
    socket.deliver(_datagram(src: 5001, seq: 8), fromPort: 5001);
    await pumpEventQueue();
    expect(relay.counters['drop_full'], 1);
    expect(socket.sentTo, isNot(contains(5017)));
    expect(socket.sentTo.where((port) => port == 5016), hasLength(1)); // the 16th heard the last datagram
  });

  test('the status line has every counter', () async {
    for (final counter in [
      'groups', 'addresses', 'rx', 'tx', 'drop_size', 'drop_rate', 'drop_cap', 'drop_send', 'drop_full' //
    ]) {
      expect(relay.statusLine(), contains('$counter='));
    }
  });
}
