// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/net/relay_address.dart';

void main() {
  test('a host alone gets port 47100', () {
    expect(parseRelayAddress('relay.example.org'), const RelayAddress('relay.example.org', 47100));
    expect(parseRelayAddress(' 203.0.113.5 '), const RelayAddress('203.0.113.5', 47100));
  });

  test('a host and a port', () {
    expect(parseRelayAddress('203.0.113.5:47200'), const RelayAddress('203.0.113.5', 47200));
  });

  test('malformed addresses are refused', () {
    for (final bad in ['', ':47100', 'host:0', 'host:70000', 'host:port', 'two words', 'a:b:c']) {
      expect(parseRelayAddress(bad), isNull, reason: bad);
    }
  });
}
