// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import 'fixtures.dart';
import 'hex.dart';

void main() {
  test('the relay forwards to every other address of the group', () {
    final t = RelayTable();
    expect(t.heard('aa', 'A:1', 0)!.to, isEmpty);
    expect(t.heard('aa', 'B:1', 10)!.to, ['A:1']);
    expect(t.heard('aa', 'A:1', 20)!.to, ['B:1']);
    expect(t.heard('bb', 'C:1', 30)!.to, isEmpty); // another group
  });

  test('an address not heard for 30 s is forgotten', () {
    final t = RelayTable()..heard('aa', 'A:1', 0);
    expect(t.heard('aa', 'B:1', 30000)!.to, ['A:1']);
    expect(t.heard('aa', 'B:1', 30001)!.to, isEmpty);
  });

  test('a full group of 256 addresses refuses a new one, and its riders still send', () {
    final t = RelayTable();
    for (var i = 0; i < 256; i++) {
      expect(t.heard('aa', '10.0.${i ~/ 16}.${i % 16}:5000', 0), isNotNull);
    }
    expect(t.heard('aa', '10.1.0.0:5000', 0), isNull);
    expect(t.heard('aa', '10.0.0.0:5000', 1)!.to, hasLength(255));
    expect(t.heard('bb', '10.1.0.0:5000', 1), isNotNull); // another group has room
  });

  test('one host holds at most 16 addresses of a group', () {
    // Riders on one café Wi-Fi, or behind one carrier address, share a host: 16 leaves room for them.
    final t = RelayTable();
    for (var port = 1; port <= 16; port++) {
      expect(t.heard('aa', '203.0.113.5:$port', 0), isNotNull);
    }
    expect(t.heard('aa', '203.0.113.5:17', 0), isNull);
    expect(t.heard('aa', '203.0.113.6:1', 0), isNotNull);
    expect(t.heard('bb', '203.0.113.5:17', 0), isNotNull);
  });

  test('the relay holds at most 50,000 addresses in all, and has room again once they are forgotten', () {
    final t = RelayTable();
    for (var i = 0; i < 50000; i++) {
      t.heard('g${i ~/ 100}', '10.${i >> 16 & 255}.${i >> 8 & 255}.${i & 255}:1', 0);
    }
    expect(t.addresses, 50000);
    expect(t.heard('new', '192.0.2.1:1', 0), isNull);
    expect(t.heard('new', '192.0.2.1:1', 30001), isNotNull);
  });

  test("a group's riders share its rate limit and talker cap, which are forgotten with them", () {
    final t = RelayTable();
    final a = t.heard('aa', 'A:1', 0)!, b = t.heard('aa', 'B:1', 0)!;
    expect(b.limit, same(a.limit));
    expect(b.cap, same(a.cap));
    expect(t.heard('bb', 'C:1', 0)!.limit, isNot(same(a.limit)));
    final later = t.heard('aa', 'A:1', 30001)!; // every address was forgotten, and their groups with them
    expect(later.limit, isNot(same(a.limit)));
    expect(later.cap, isNot(same(a.cap)));
    expect(t.groups, 1);
  });

  test('a bucket of 200 a second allows a burst of 400, then 200 a second', () {
    final r = RateLimiter(perSecond: 200, burst: 400);
    expect(List.generate(401, (_) => r.take(0)).where((ok) => ok).length, 400);
    expect(List.generate(201, (_) => r.take(1000)).where((ok) => ok).length, 200);
  });

  test('the cap admits four talkers and refuses a fifth', () {
    final cap = TalkerCap();
    for (final src in [1, 2, 3, 4]) {
      expect(cap.admit(src, 0), isTrue);
    }
    expect(cap.admit(5, 500), isFalse); // four are active
    expect(cap.admit(1, 999), isTrue); // a talker keeps its slot; rider 1 is refreshed at 999
    expect(cap.admit(5, 1000), isFalse); // 2, 3 and 4 were last heard at 0: still active at exactly 1000
    expect(cap.admit(5, 1001), isTrue); // their slots free up once more than 1000 ms have passed
  });

  test('a relay datagram needs 39 to 512 bytes and a v1 header', () {
    final ok = unhex('$tagHex$sealed'); // the shared test vector
    expect(parseRelayDatagram(ok)!.groupTag, tagHex);
    expect(parseRelayDatagram(ok.sublist(0, 38)), isNull);
    expect(parseRelayDatagram(Uint8List(513)..setRange(0, ok.length, ok)), isNull);
    expect(parseRelayDatagram(Uint8List.fromList(ok)..[8] = 2), isNull); // version 2
  });
}
