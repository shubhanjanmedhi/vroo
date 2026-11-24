// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo_net/vroo_net.dart';

import 'hex.dart';

/// A phone with no route to the internet at all: every send fails.
class _NoRoute extends FakeVrooNet {
  @override
  Future<void> sendToInternet(Uint8List data, InternetAddress host, int port) async =>
      throw const SocketException('Network is unreachable');
}

void main() {
  test('dns query layout', () {
    expect(hex(encodeDnsQuery(0x1234)), '123401000001000000000000076578616d706c6503636f6d0000010001');
  });
  test('dns response matching', () {
    final r = unhex('123481800001000100000000');
    expect(isDnsResponseFor(0x1234, r), isTrue);
    expect(isDnsResponseFor(0x1235, r), isFalse);
    expect(isDnsResponseFor(0x1234, unhex('123401000001000000000000')), isFalse); // a query, not a response
    expect(isDnsResponseFor(0x1234, unhex('1234')), isFalse);
  });
  test('probe succeeds on a matching reply and fails on timeout', () {
    fakeAsync((fa) {
      final net = FakeVrooNet();
      bool? ok;
      probeInternet(net, random: Random(7)).then((v) => ok = v);
      fa.flushMicrotasks();
      final q = net.sentToInternet.single;
      expect([q.$1.address, q.$2], ['1.1.1.1', 53]);
      net.emit(InternetDatagram(InternetAddress('1.1.1.1'), 53, Uint8List.fromList([...q.$3.sublist(0, 2), 0x81, 0x80, ...List.filled(8, 0)])));
      fa.flushMicrotasks();
      expect(ok, isTrue);
      ok = null;
      probeInternet(net).then((v) => ok = v);
      fa.elapse(const Duration(seconds: 3));
      expect(ok, isFalse);
    });
  });
  test('a send that fails means no internet', () async {
    expect(await probeInternet(_NoRoute()), isFalse);
  });

  test('dns query for any name', () {
    expect(hex(encodeDnsQuery(0x1234, 'relay.example.org')),
        '1234010000010000000000000572656c6179076578616d706c65036f72670000010001');
  });

  test("an answer's first IPv4 address, after a CNAME", () {
    // relay.example.org → CNAME host.example.net → A 203.0.113.5, with compressed names, as resolvers answer.
    final answer = unhex('1234818000010002000000000572656c6179076578616d706c65036f72670000010001c00c000500010000012c'
        '001204686f7374076578616d706c65036e657400c02f000100010000003c0004cb007105');
    expect(firstIPv4In(answer)?.address, '203.0.113.5');
    expect(firstIPv4In(answer.sublist(0, answer.length - 2)), isNull); // cut short
    // No such name: an error code and no answers.
    expect(firstIPv4In(unhex('1234818300010000000000000572656c6179076578616d706c65036f72670000010001')), isNull);
  });

  test("a relay's name is looked up through 1.1.1.1 over the internet path", () {
    fakeAsync((fa) {
      final net = FakeVrooNet()
        ..answerDnsProbes = true
        ..dnsRecords['relay.example.org'] = InternetAddress('203.0.113.5');
      InternetAddress? found;
      lookupOverInternet(net, 'relay.example.org').then((a) => found = a);
      fa.flushMicrotasks();
      expect([net.sentToInternet.single.$1.address, net.sentToInternet.single.$2], ['1.1.1.1', 53]);
      expect(found?.address, '203.0.113.5');
      var done = false;
      lookupOverInternet(net, 'unknown.example.org').then((a) => [found = a, done = true]);
      fa.elapse(const Duration(seconds: 3));
      expect([done, found], [true, null]);
    });
  });
}
