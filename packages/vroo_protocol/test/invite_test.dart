// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:test/test.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import 'fixtures.dart';

void main() {
  const link = 'vroo://join?v=1&s=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&n=Sunday%20ride';

  test('encodes the v1 invite link', () {
    expect(encodeInvite(Invite(secret, 'Sunday ride')), link);
  });

  test('decodes what it encodes', () {
    final i = decodeInvite(link)!;
    expect(i.secret, secret);
    expect(i.name, 'Sunday ride');
  });

  test('a missing name decodes as empty', () {
    expect(decodeInvite(link.split('&n=').first)!.name, '');
  });

  test('rejects foreign or broken links', () {
    expect(decodeInvite(link.replaceFirst('vroo://', 'https://')), isNull);
    expect(decodeInvite(link.replaceFirst('v=1', 'v=2')), isNull);
    expect(decodeInvite('vroo://join?v=1&s=AAEC&n=x'), isNull); // not 32 bytes
    expect(decodeInvite('not a link'), isNull);
  });

  test('broken percent-escapes are rejected, not thrown', () {
    for (final bad in ['vroo://join?v=%ff', 'vroo://join?v=1&s=%ff', '$link%C3']) {
      expect(decodeInvite(bad), isNull, reason: bad);
    }
  });
}
