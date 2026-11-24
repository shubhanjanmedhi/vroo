// SPDX-License-Identifier: GPL-3.0-or-later
//
// Test helpers for GroupLink: one fake box and one fake relay that phones' FakeVrooNets talk through, and phones
// running real GroupLinks on them. Create phones inside fakeAsync, so their clocks follow fake time.
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:vroo/diag/clock.dart';
import 'package:vroo/diag/ride_log.dart';
import 'package:vroo/net/group_link.dart';
import 'package:vroo/net/relay_address.dart';
import 'package:vroo_net/vroo_net.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

/// Forwards every data-port datagram to every other joined phone, as the box firmware does (it never sends a phone's
/// packet back to it); with [duplicate], twice, as when a
/// packet reaches a phone over two paths. Sends BOX_STATUS only when told.
class FakeBox {
  FakeBox({this.duplicate = false});

  final bool duplicate;
  final _nets = <FakeVrooNet>[];

  /// A phone's net on this box; with [relay], it reaches that relay over the internet too.
  FakeVrooNet join({FakeRelay? relay}) {
    final net = _BoxNet(this, relay);
    _nets.add(net);
    relay?._members.add(net);
    return net;
  }

  void sendStatus() {
    final status = encodeBoxStatus(const BoxStatus(
        boxId: 0x00A1B2C3, fwVersion: 1, uptimeS: 1, setupMode: false, phones: 2,
        rxFromPhones: 0, txToPhones: 0, dropDup: 0, dropTag: 0));
    for (final net in _nets) {
      net.emit(BoxDatagram(boxControlPort, status));
    }
  }

  void _received(FakeVrooNet from, int port, Uint8List data) {
    if (port != boxDataPort) return;
    for (final net in _nets) {
      if (net == from) continue;
      net.emit(BoxDatagram(boxDataPort, data));
      if (duplicate) net.emit(BoxDatagram(boxDataPort, data));
    }
  }
}

class _BoxNet extends FakeVrooNet {
  _BoxNet(this._box, this._relay) {
    answerDnsProbes = _relay != null; // a phone with a relay has internet
  }

  final FakeBox _box;
  final FakeRelay? _relay;

  @override
  Future<void> sendToBox(Uint8List data, {required int port}) async {
    await super.sendToBox(data, port: port);
    _box._received(this, port, data);
  }

  @override
  Future<void> sendToInternet(Uint8List data, InternetAddress host, int port) async {
    await super.sendToInternet(data, host, port);
    _relay?._received(this, host, port, data);
  }
}

/// A relay server at [address]: what one phone sends there reaches every other phone joined to it, as an
/// [InternetDatagram] from the relay. Its phones have internet, so their probes succeed.
class FakeRelay {
  static const address = RelayAddress('10.0.0.9', relayPort);

  final _members = <FakeVrooNet>[];

  /// A phone's net with internet and no box.
  FakeVrooNet join() {
    final net = _RelayNet(this)..answerDnsProbes = true;
    _members.add(net);
    return net;
  }

  void _received(FakeVrooNet from, InternetAddress host, int port, Uint8List data) {
    if (host.address != address.host || port != address.port) return;
    for (final m in _members) {
      if (m != from) m.emit(InternetDatagram(InternetAddress(address.host), address.port, data));
    }
  }
}

class _RelayNet extends FakeVrooNet {
  _RelayNet(this._relay);

  final FakeRelay _relay;

  @override
  Future<void> sendToInternet(Uint8List data, InternetAddress host, int port) async {
    await super.sendToInternet(data, host, port);
    _relay._received(this, host, port, data);
  }
}

class Phone {
  Phone(this._keys, this.net, this.name, this.id, {this.boxSetUp = true, this.relay}) {
    restartLink();
  }

  final GroupKeys _keys;
  final FakeVrooNet net;
  final String name;
  final int id;
  final bool boxSetUp;
  final RelayAddress? relay;
  final _clock = SystemClock();
  final _log = StringBuffer();
  late GroupLink link;
  late GroupLinkState lastState;

  String get logText => _log.toString();

  /// A new GroupLink with the same rider ID and name, as after an app restart.
  void restartLink() {
    link = GroupLink(
        net: net,
        keys: _keys,
        myId: id,
        myName: name,
        platform: 1,
        clock: _clock,
        log: RideLog(_log, _clock),
        boxSetUp: boxSetUp,
        relay: relay);
    link.states.listen((s) => lastState = s);
  }
}

class Harness {
  Harness() : keys = _keys!;

  static GroupKeys? _keys;
  static Uint8List? _foreign;

  /// Derives the keys and the foreign envelope once, outside fake time. Call it from setUpAll.
  static Future<void> prepare() async {
    _keys = await GroupKeys.derive(Uint8List.fromList(List.generate(32, (i) => i)));
    final other = await GroupKeys.derive(Uint8List(32));
    const h = PacketHeader(version: 1, type: PacketType.beat, ttl: 16, src: 0x0F, session: 1, seq: 1);
    final beat = encodeBeat(const Beat(platform: 0, flags: 0, battery: 50, sentAtMs: 0, btNeighbors: [], name: 'X'));
    _foreign = wrapEnvelope(_keys!.tag, await Sealer(other).seal(h, beat));
  }

  final box = FakeBox();
  final relay = FakeRelay();
  final GroupKeys keys;
  final _phones = <String, Phone>{};

  /// A phone on the box, with no relay set.
  Phone phone(String name, {required int id}) => _phones[name] ??= Phone(keys, box.join(), name, id);

  /// A phone with no box, on the relay.
  Phone relayPhone(String name, {required int id}) =>
      _phones[name] ??= Phone(keys, relay.join(), name, id, boxSetUp: false, relay: FakeRelay.address);

  /// A phone on the box and the relay.
  Phone bothPhone(String name, {required int id}) =>
      _phones[name] ??= Phone(keys, box.join(relay: relay), name, id, relay: FakeRelay.address);
  Phone get a => phone('A', id: 0xA);
  Phone get b => phone('B', id: 0xB);

  void startBoth() {
    a.link.start();
    b.link.start();
  }

  Opened? openNow(Uint8List packet, FakeAsync fa) {
    Opened? opened;
    Sealer(keys).open(packet).then((o) => opened = o);
    fa.flushMicrotasks();
    return opened;
  }

  /// The right group tag, sealed with a different key: a packet from another group whose tag collides.
  Uint8List foreignEnvelope() => _foreign!;

  /// A datagram from another rider of this group: [payload] sealed as [type] from [src] with [seq].
  Future<Uint8List> envelopeFrom(int src, {required int type, required int seq, required Uint8List payload}) async {
    final h = PacketHeader(version: 1, type: type, ttl: 16, src: src, session: 1, seq: seq);
    return wrapEnvelope(keys.tag, await Sealer(keys).seal(h, payload));
  }
}
