// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/net/group_link.dart';
import 'package:vroo/net/peer.dart';
import 'package:vroo/net/relay_address.dart';
import 'package:vroo_net/vroo_net.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import 'fake_box.dart';

void main() {
  late Harness harness;
  setUpAll(Harness.prepare);
  setUp(() => harness = Harness());

  /// [payload] sealed as [type] from rider 7, ready to arrive from the box.
  Uint8List from7(FakeAsync fa, int type, int seq, Uint8List payload) {
    late Uint8List envelope;
    harness.envelopeFrom(7, type: type, seq: seq, payload: payload).then((e) => envelope = e);
    fa.flushMicrotasks();
    return envelope;
  }

  Uint8List beat7(FakeAsync fa, int seq, int sentAtMs) => from7(fa, PacketType.beat, seq,
      encodeBeat(Beat(platform: 0, flags: 0, battery: 255, sentAtMs: sentAtMs, btNeighbors: const [], name: 'Seven')));

  int wallMs() => clock.now().millisecondsSinceEpoch;

  /// The heartbeats [p] has sent to the box so far, oldest first.
  List<Beat> beatsSent(Phone p, FakeAsync fa) => [
        for (final (port, d) in p.net.sentToBox)
          if (port == boxDataPort)
            if (harness.openNow(unwrapEnvelope(d)!.packet, fa) case final o? when o.header.type == PacketType.beat)
              decodeBeat(o.payload)!,
      ];

  /// How many packets [p] has sent to the relay.
  int relaySends(Phone p) => p.net.sentToInternet.where((x) => x.$2 == relayPort).length;

  final relayIp = InternetAddress(FakeRelay.address.host);

  test('two phones with no box hear each other through the relay', () => fakeAsync((fa) {
        final a = harness.relayPhone('A', id: 0xA), b = harness.relayPhone('B', id: 0xB);
        final heard = <HeardVoice>[];
        b.link.voices.listen(heard.add);
        a.link.start();
        b.link.start();
        fa.elapse(const Duration(seconds: 2));
        expect(a.lastState.peers.keys, [0xB]);
        expect(b.lastState.peers.keys, [0xA]);
        expect(a.lastState.dataPathOn, isTrue);
        a.link.sendVoice(VoiceFrame(frameNo: 0, opus: Uint8List.fromList([1, 2])));
        fa.flushMicrotasks();
        expect(heard, hasLength(1));
        expect(b.lastState.peers[0xA]!.lastPath, RidePath.internet);
      }));

  test('a packet that arrives by both paths plays once', () => fakeAsync((fa) {
        final a = harness.bothPhone('A', id: 0xA), b = harness.bothPhone('B', id: 0xB);
        final heard = <HeardVoice>[];
        b.link.voices.listen(heard.add);
        a.link.start();
        b.link.start();
        harness.box.sendStatus();
        fa.elapse(const Duration(seconds: 2));
        for (var i = 0; i < 5; i++) {
          a.link.sendVoice(VoiceFrame(frameNo: i, opus: Uint8List.fromList([1, 2])));
        }
        fa.flushMicrotasks();
        expect(heard.map((v) => v.frame.frameNo), [0, 1, 2, 3, 4]);
        expect(relaySends(a), greaterThan(5)); // the relay carried them too
      }));

  test("each rider's last path is kept", () => fakeAsync((fa) {
        final a = harness.bothPhone('A', id: 0xA)..link.start();
        fa.elapse(const Duration(seconds: 1));
        a.net.emit(BoxDatagram(boxDataPort, beat7(fa, 0, wallMs())));
        fa.flushMicrotasks();
        expect(a.lastState.peers[7]!.lastPath, RidePath.box);
        a.net.emit(InternetDatagram(relayIp, FakeRelay.address.port, beat7(fa, 1, wallMs())));
        fa.flushMicrotasks();
        expect(a.lastState.peers[7]!.lastPath, RidePath.internet);
      }));

  test("a box rider's data path goes off after two failed probes in a row, and back on", () => fakeAsync((fa) {
        final a = harness.bothPhone('A', id: 0xA)..link.start();
        fa.elapse(const Duration(seconds: 2));
        expect(a.lastState.dataPathOn, isTrue);
        a.net.answerDnsProbes = false;
        fa.elapse(const Duration(seconds: 6)); // the probe at 5 s gave up at 7 s: one lost probe isn't an outage
        expect(a.lastState.dataPathOn, isTrue);
        fa.elapse(const Duration(seconds: 5)); // the probe at 10 s gave up at 12 s
        expect(a.lastState.dataPathOn, isFalse);
        final sent = relaySends(a);
        fa.elapse(const Duration(seconds: 1));
        expect(relaySends(a), sent);
        a.net.answerDnsProbes = true;
        fa.elapse(const Duration(seconds: 2)); // the probe at 15 s succeeds
        expect(a.lastState.dataPathOn, isTrue);
        fa.elapse(const Duration(seconds: 1));
        expect(relaySends(a), greaterThan(sent));
      }));

  test('a rider with no box keeps sending to the relay while probes fail: it has no other path', () => fakeAsync((fa) {
        final a = harness.relayPhone('A', id: 0xA)..link.start();
        fa.elapse(const Duration(seconds: 2));
        a.net.answerDnsProbes = false;
        fa.elapse(const Duration(seconds: 16)); // the probes at 5, 10 and 15 s all gave up
        final sent = relaySends(a);
        fa.elapse(const Duration(seconds: 2));
        expect(relaySends(a), greaterThan(sent));
        expect(a.lastState.dataPathOn, isTrue);
      }));

  test('packets from the relay count as internet, whatever the probe says', () => fakeAsync((fa) {
        final a = harness.bothPhone('A', id: 0xA), b = harness.relayPhone('B', id: 0xB);
        a.link.start();
        b.link.start();
        fa.elapse(const Duration(seconds: 2));
        a.net.answerDnsProbes = false; // a network that blocks the probe, or loses every one
        fa.elapse(const Duration(seconds: 20)); // B's heartbeats keep coming from the relay
        expect(a.lastState.dataPathOn, isTrue);
      }));

  test('heartbeat flags follow the real state', () => fakeAsync((fa) {
        final a = harness.bothPhone('A', id: 0xA)..link.start();
        fa.elapse(const Duration(milliseconds: 1500)); // the data path is on; the box hasn't answered
        var beat = beatsSent(a, fa).last;
        expect(beat.flags & BeatFlags.hasBox, 0);
        expect(beat.flags & BeatFlags.hasInternet, BeatFlags.hasInternet);
        harness.box.sendStatus();
        fa.elapse(const Duration(seconds: 1));
        expect(beatsSent(a, fa).last.flags & BeatFlags.hasBox, BeatFlags.hasBox);
        a.net.answerDnsProbes = false;
        fa.elapse(const Duration(seconds: 11)); // the box went quiet at 4.5 s; the probes at 5 and 10 s gave up by 12 s
        beat = beatsSent(a, fa).last;
        expect(beat.flags & BeatFlags.hasBox, 0);
        expect(beat.flags & BeatFlags.hasInternet, 0);
      }));

  test('a relay given by name is looked up over the internet path', () => fakeAsync((fa) {
        // On an iPhone the box's Wi-Fi can be the default network, so the system's own lookup would ask the box.
        final net = harness.relay.join()..dnsRecords['relay.example.org'] = relayIp;
        final a = Phone(harness.keys, net, 'A', 0xA,
            boxSetUp: false, relay: const RelayAddress('relay.example.org', relayPort))
          ..link.start();
        fa.elapse(const Duration(seconds: 1));
        expect(a.lastState.dataPathOn, isTrue);
        expect(a.logText, contains(',path,relay=10.0.0.9:47100'));
      }));

  test("a relay name the internet doesn't know shows as not found", () => fakeAsync((fa) {
        final a = Phone(harness.keys, harness.relay.join(), 'A', 0xA,
            boxSetUp: false, relay: const RelayAddress('relay.example.org', relayPort))
          ..link.start();
        fa.elapse(const Duration(seconds: 1));
        expect(a.lastState.internetUp, isTrue);
        expect(a.lastState.relayNotFound, isTrue);
        expect(a.lastState.dataPathOn, isFalse);
      }));

  test('without a relay address the data path stays off', () => fakeAsync((fa) {
        final a = harness.phone('A', id: 0xA);
        a.net.answerDnsProbes = true;
        a.link.start();
        fa.elapse(const Duration(seconds: 6));
        expect(a.lastState.internetUp, isTrue);
        expect(a.lastState.dataPathOn, isFalse);
        expect(relaySends(a), 0);
      }));

  // The bridge (architecture §6.4). Phone 1 is on the box only, phone 2 on the box and the relay, phone 3 on the
  // relay only; phone 4, added in some tests, is on both with the lowest rider ID.
  Phone box1() => harness.phone('1', id: 0x30);
  Phone both2() => harness.bothPhone('2', id: 0x20);
  Phone relay3() => harness.relayPhone('3', id: 0x40);
  Phone both4() => harness.bothPhone('4', id: 0x10);

  /// Starts [phones] with the box answering every second, and lets [seconds] pass.
  void ride(FakeAsync fa, List<Phone> phones, {int seconds = 3}) {
    for (final p in phones) {
      p.link.start();
    }
    harness.box.sendStatus();
    Timer.periodic(const Duration(seconds: 1), (_) => harness.box.sendStatus());
    fa.elapse(Duration(seconds: seconds));
  }

  VoiceFrame frame(int n) => VoiceFrame(frameNo: n, opus: Uint8List.fromList([1, 2]));

  test('a box-only rider and an internet-only rider hear each other through the bridge', () => fakeAsync((fa) {
        final p1 = box1(), p2 = both2(), p3 = relay3();
        final heardBy1 = <HeardVoice>[], heardBy3 = <HeardVoice>[];
        p1.link.voices.listen(heardBy1.add);
        p3.link.voices.listen(heardBy3.add);
        ride(fa, [p1, p2, p3]);
        expect(p2.lastState.bridge, isTrue);
        expect(p2.logText, contains('bridge,state=on'));
        p1.link.sendVoice(frame(1));
        p3.link.sendVoice(frame(2));
        fa.flushMicrotasks();
        expect(heardBy3.map((v) => v.src), [0x30]);
        expect(heardBy1.map((v) => v.src), [0x40]);
      }));

  test('the lowest-ID phone with box and data bridges, and a second steps down', () => fakeAsync((fa) {
        final p1 = box1(), p2 = both2(), p3 = relay3();
        final heardBy1 = <HeardVoice>[], heardBy3 = <HeardVoice>[];
        p1.link.voices.listen(heardBy1.add);
        p3.link.voices.listen(heardBy3.add);
        ride(fa, [p1, p2, p3]);
        final p4 = both4()..link.start();
        fa.elapse(const Duration(seconds: 2));
        expect(p4.lastState.bridge, isTrue);
        expect(p2.lastState.bridge, isFalse);
        for (var i = 0; i < 5; i++) {
          p1.link.sendVoice(frame(i));
          p3.link.sendVoice(frame(i));
        }
        fa.flushMicrotasks();
        expect(heardBy3.where((v) => v.src == 0x30).map((v) => v.frame.frameNo), [0, 1, 2, 3, 4]); // once each
        expect(heardBy1.where((v) => v.src == 0x40).map((v) => v.frame.frameNo), [0, 1, 2, 3, 4]);
      }));

  test('when the bridge leaves, the next takes over', () => fakeAsync((fa) {
        final p1 = box1(), p2 = both2(), p3 = relay3(), p4 = both4();
        ride(fa, [p1, p2, p3, p4]);
        expect(p2.lastState.bridge, isFalse);
        p4.link.stop();
        fa.elapse(const Duration(seconds: 5)); // 4 s without hearing phone 4 over the box, then the next heartbeat
        expect(p2.lastState.bridge, isTrue);
      }));

  test('a bridge uploads only riders without data', () => fakeAsync((fa) {
        final p2 = both2(), p3 = relay3(), p4 = both4();
        ride(fa, [p2, p3, p4], seconds: 4);
        expect(p4.lastState.bridge, isTrue);
        final toRelay = [
          for (final (_, port, d) in p4.net.sentToInternet)
            if (port == relayPort) decodeHeader(unwrapEnvelope(d)!.packet)!.src,
        ];
        expect(toRelay, isNotEmpty);
        expect(toRelay.toSet(), {0x10}); // only its own: riders with data upload their own
      }));

  test('a bridged packet goes into the box with ttl 16', () => fakeAsync((fa) {
        final p1 = box1(), p2 = both2();
        ride(fa, [p1, p2]);
        expect(p2.lastState.bridge, isTrue);
        final sentBefore = p2.net.sentToBox.length;
        late Uint8List beat;
        harness.envelopeFrom(0x40, type: PacketType.beat, seq: 1, payload: encodeBeat(Beat(
            platform: 0, flags: BeatFlags.hasInternet, battery: 255, sentAtMs: wallMs(), btNeighbors: const [],
            name: 'Far'))).then((e) => beat = e);
        fa.flushMicrotasks();
        beat[8 + 2] = 5; // it reached the relay with ttl 5
        p2.net.emit(InternetDatagram(relayIp, FakeRelay.address.port, beat));
        fa.flushMicrotasks();
        final intoBox = [
          for (final (_, d) in p2.net.sentToBox.skip(sentBefore))
            if (decodeHeader(unwrapEnvelope(d)!.packet) case final h? when h.src == 0x40) h,
        ];
        expect(intoBox, hasLength(1));
        expect(intoBox.single.ttl, 16);
      }));

  test('a packet replayed after the dedupe window is not played', () => fakeAsync((fa) {
        final a = harness.a..link.start();
        final heard = <HeardVoice>[];
        a.link.voices.listen(heard.add);
        a.net.emit(BoxDatagram(boxDataPort, beat7(fa, 0, wallMs())));
        final voice =
            from7(fa, PacketType.voice, 1, encodeVoice(VoiceFrame(frameNo: 0, opus: Uint8List.fromList([1, 2]))));
        a.net.emit(BoxDatagram(boxDataPort, voice));
        for (var s = 2; s <= 12; s++) {
          fa.elapse(const Duration(seconds: 1));
          a.net.emit(BoxDatagram(boxDataPort, beat7(fa, s, wallMs()))); // rider 7 is still riding
        }
        a.net.emit(BoxDatagram(boxDataPort, voice)); // the same bytes, 11 s later
        fa.flushMicrotasks();
        expect(heard, hasLength(1));
      }));

  test('voice from a rider whose clock is 11 minutes off is not played, and the drop is logged', () => fakeAsync((fa) {
        final a = harness.a..link.start();
        final heard = <HeardVoice>[];
        a.link.voices.listen(heard.add);
        a.net.emit(BoxDatagram(boxDataPort, beat7(fa, 0, wallMs() - 660000)));
        a.net.emit(BoxDatagram(boxDataPort,
            from7(fa, PacketType.voice, 1, encodeVoice(VoiceFrame(frameNo: 0, opus: Uint8List.fromList([1, 2]))))));
        fa.elapse(const Duration(milliseconds: 100));
        expect(heard, isEmpty);
        expect(a.lastState.peers, isEmpty);
        expect(a.logText, contains(',drop,reason=stale'));
      }));

  test("a rider whose clock is 2 h off shows with the gap, so they aren't silently missing", () => fakeAsync((fa) {
        final a = harness.a..link.start();
        a.net.emit(BoxDatagram(boxDataPort, beat7(fa, 0, wallMs() + 7200000)));
        fa.elapse(const Duration(milliseconds: 100));
        expect(a.lastState.peers, isEmpty);
        final gap = a.lastState.clockGaps[7]!;
        expect(gap.name, 'Seven');
        expect(gap.offsetMs, closeTo(7200000, 200));
        fa.elapse(const Duration(seconds: 5));
        expect(a.lastState.clockGaps, isEmpty); // their heartbeats stopped
      }));

  test("an old heartbeat played again isn't taken for a wrong clock while its rider is heard", () => fakeAsync((fa) {
        final a = harness.a..link.start();
        a.net.emit(BoxDatagram(boxDataPort, beat7(fa, 1, wallMs())));
        a.net.emit(BoxDatagram(boxDataPort, beat7(fa, 0, wallMs() - 3600000))); // recorded an hour ago
        fa.elapse(const Duration(milliseconds: 100));
        expect(a.lastState.peers.keys, [7]);
        expect(a.lastState.clockGaps, isEmpty);
      }));

  test('voice from a session with no heartbeat is not played', () => fakeAsync((fa) {
        final a = harness.a..link.start();
        final heard = <HeardVoice>[];
        a.link.voices.listen(heard.add);
        a.net.emit(BoxDatagram(boxDataPort,
            from7(fa, PacketType.voice, 1, encodeVoice(VoiceFrame(frameNo: 0, opus: Uint8List.fromList([1, 2]))))));
        fa.elapse(const Duration(milliseconds: 100));
        expect(heard, isEmpty);
        expect(a.logText, contains(',drop,reason=nobeat'));
      }));

  test('the heartbeat carries the wall clock, and the round trip is measured on it', () => fakeAsync((fa) {
        final a = harness.a..link.start();
        fa.flushMicrotasks();
        final sent = a.net.sentToBox.firstWhere((d) => d.$1 == boxDataPort).$2;
        final opened = harness.openNow(unwrapEnvelope(sent)!.packet, fa)!;
        final sentAt = decodeBeat(opened.payload)!.sentAtMs;
        expect(sentAt, DateTime.utc(2026, 10, 31, 10).millisecondsSinceEpoch & 0xFFFFFFFF);
        a.net.emit(BoxDatagram(boxDataPort, beat7(fa, 0, wallMs())));
        fa.elapse(const Duration(milliseconds: 40));
        a.net.emit(BoxDatagram(boxDataPort, from7(fa, PacketType.echo, 1, encodeEcho(Echo(target: 0xA, sentAtMs: sentAt)))));
        fa.flushMicrotasks();
        expect(a.lastState.peers[7]!.rttMs, 40);
      }, initialTime: DateTime.utc(2026, 10, 31, 10)));

  test('sends a sealed beat to the box every second', () => fakeAsync((fa) {
        final a = harness.phone('A', id: 0xA);
        a.link.start();
        harness.box.sendStatus(); // so the heartbeat says the box answers
        fa.elapse(const Duration(milliseconds: 1100));
        final (port, data) = a.net.sentToBox.last;
        expect(port, boxDataPort);
        final u = unwrapEnvelope(data)!;
        expect(u.groupTag, harness.keys.tag);
        final o = harness.openNow(u.packet, fa)!;
        expect([o.header.type, o.header.ttl, o.header.src], [PacketType.beat, 16, 0xA]);
        final beat = decodeBeat(o.payload)!;
        expect(beat.name, 'A');
        expect(beat.flags & BeatFlags.hasBox, BeatFlags.hasBox);
      }));
  test('each phone lists the other, never itself', () => fakeAsync((fa) {
        harness.startBoth();
        fa.elapse(const Duration(seconds: 2));
        expect(harness.a.lastState.peers.keys, [0xB]);
        expect(harness.a.lastState.peers[0xB]!.name, 'B');
        expect(harness.b.lastState.peers.keys, [0xA]);
      }));
  test('echo replies give a round-trip time', () => fakeAsync((fa) {
        harness.startBoth();
        fa.elapse(const Duration(seconds: 6));
        expect(harness.b.lastState.peers[0xA]!.rttMs, isNotNull);
        expect(harness.a.lastState.peers[0xB]!.rttMs, isNotNull);
      }));
  test('wrong-group packets and garbage are ignored and logged', () => fakeAsync((fa) {
        harness.a.link.start();
        harness.a.net.emit(BoxDatagram(boxDataPort, harness.foreignEnvelope())); // same tag, other key
        harness.a.net.emit(BoxDatagram(boxDataPort, Uint8List.fromList(List.generate(60, (i) => i * 7))));
        fa.elapse(const Duration(seconds: 1));
        expect(harness.a.lastState.peers, isEmpty);
        expect(harness.a.logText, contains(',drop,reason=auth'));
      }));
  test('box goes down after 3 s without status and comes back', () => fakeAsync((fa) {
        harness.a.link.start();
        harness.box.sendStatus();
        fa.elapse(const Duration(milliseconds: 100));
        expect(harness.a.lastState.boxUp, isTrue);
        fa.elapse(const Duration(seconds: 3, milliseconds: 100));
        expect(harness.a.lastState.boxUp, isFalse);
        expect(harness.a.logText, contains(',box,state=down'));
        harness.box.sendStatus();
        fa.elapse(const Duration(milliseconds: 100));
        expect(harness.a.lastState.boxUp, isTrue);
      }));
  test('a restarted app gets a new session but stays one rider', () => fakeAsync((fa) {
        harness.startBoth();
        fa.elapse(const Duration(seconds: 2));
        final s1 = harness.a.link.session;
        harness.a.link.stop();
        harness.a.restartLink();
        harness.a.link.start();
        fa.elapse(const Duration(seconds: 2));
        expect(harness.a.link.session, isNot(s1));
        expect(harness.b.lastState.peers.keys, [0xA]);
      }));
  test('internet state follows the probe', () => fakeAsync((fa) {
        harness.a.link.start();
        harness.a.net.answerDnsProbes = true;
        fa.elapse(const Duration(seconds: 5, milliseconds: 100));
        expect(harness.a.lastState.internetUp, isTrue);
        harness.a.net.answerDnsProbes = false;
        fa.elapse(const Duration(seconds: 12)); // the probes at 10 and 15 s gave up by 17 s
        expect(harness.a.lastState.internetUp, isFalse);
        expect(harness.a.logText, contains(',path,internet=down'));
      }));
  test('stop sends nothing more', () => fakeAsync((fa) {
        harness.a.link.start();
        fa.elapse(const Duration(seconds: 1));
        harness.a.link.stop();
        final n = harness.a.net.sentToBox.length;
        fa.elapse(const Duration(seconds: 3));
        expect(harness.a.net.sentToBox.length, n);
      }));
  test('voice frames reach the other phone with their frame numbers', () => fakeAsync((fa) {
        harness.startBoth();
        final heard = <HeardVoice>[];
        harness.b.link.voices.listen(heard.add);
        harness.a.link.sendVoice(VoiceFrame(frameNo: 7, opus: Uint8List.fromList([1, 2, 3])));
        fa.elapse(const Duration(milliseconds: 100));
        expect(heard.length, 1);
        expect([heard[0].src, heard[0].session, heard[0].frame.frameNo], [0xA, harness.a.link.session, 7]);
        expect(heard[0].frame.opus, [1, 2, 3]);
      }));
  test('a phone never hears its own voice', () => fakeAsync((fa) {
        harness.startBoth();
        final heard = <HeardVoice>[];
        harness.a.link.voices.listen(heard.add);
        harness.a.link.sendVoice(VoiceFrame(frameNo: 0, opus: Uint8List(3)));
        fa.flushMicrotasks();
        // The box never sends a phone's packet back, but another box relaying it could: feed it back as that would.
        harness.a.net.emit(BoxDatagram(boxDataPort, harness.a.net.sentToBox.last.$2));
        fa.elapse(const Duration(milliseconds: 100));
        expect(heard, isEmpty);
      }));
  test('the talking and on-call flags travel in the heartbeat', () => fakeAsync((fa) {
        harness.startBoth();
        harness.a.link
          ..talking = true
          ..onCall = true;
        fa.elapse(const Duration(milliseconds: 1100));
        final a = harness.b.lastState.peers[0xA]!;
        expect([a.talking, a.onCall], [true, true]);
        harness.a.link
          ..talking = false
          ..onCall = false;
        fa.elapse(const Duration(seconds: 1));
        expect([a.talking, a.onCall], [false, false]);
      }));
  test('echoes the 1st and every 5th heartbeat from each rider, whatever its sequence numbers', () async {
    // Voice packets share the sequence counter, so a rider's heartbeats can land on any seq: here never a multiple of 5.
    final beats = [
      for (var k = 0; k < 6; k++)
        await harness.envelopeFrom(0x5,
            type: PacketType.beat,
            seq: 1 + k * 5,
            payload: encodeBeat(Beat(
                platform: 0,
                flags: 0,
                battery: 255,
                sentAtMs: DateTime.now().millisecondsSinceEpoch + k * 1000, // heartbeats carry the wall clock
                btNeighbors: const [],
                name: 'C'))),
    ];
    fakeAsync((fa) {
      harness.a.link.start();
      for (final beat in beats) {
        harness.a.net.emit(BoxDatagram(boxDataPort, beat));
        fa.elapse(const Duration(milliseconds: 200));
      }
      final echoes = harness.a.net.sentToBox
          .map((d) => harness.openNow(unwrapEnvelope(d.$2)!.packet, fa)!)
          .where((o) => o.header.type == PacketType.echo && decodeEcho(o.payload)!.target == 0x5);
      expect(echoes.length, 2); // the 1st and the 6th
    });
  });
}
