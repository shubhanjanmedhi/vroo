// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';

import 'package:test/test.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import 'fixtures.dart';
import 'hex.dart';

void main() {
  const pw = 'abcd-efgh-jkmn-pqrs';
  const full = '011007$tagHex' '0b' '13' '616263642d656667682d6a6b6d6e2d70717273';
  const statusHex = '0111' '00a1b2c3' '0001' '00000e10' '00' '02' '00000064' '0000005a' '00000003' '00000001';

  test('box config with every field', () {
    expect(hex(encodeBoxConfig(BoxConfig(groupTag: unhex(tagHex), channel: 11, wifiPassword: pw))), full);
    final c = decodeBoxConfig(unhex(full))!;
    expect([hex(c.groupTag!), c.channel, c.wifiPassword], [tagHex, 11, pw]);
  });
  test('box config with only the tag', () {
    expect(hex(encodeBoxConfig(BoxConfig(groupTag: unhex(tagHex)))), '011001$tagHex');
  });
  test('bad box configs are rejected', () {
    expect(decodeBoxConfig(unhex('011002' '05')), isNull); // channel 5
    expect(decodeBoxConfig(unhex('011004' '03' '616263')), isNull); // password too short
    expect(decodeBoxConfig(unhex('011001' '0e8d')), isNull); // truncated tag
    expect(decodeBoxConfig(unhex('011004' '08' '616263640a666768')), isNull); // control character in password
  });
  test('box status layout', () {
    const s = BoxStatus(boxId: 0x00A1B2C3, fwVersion: 1, uptimeS: 3600, setupMode: false, phones: 2, rxFromPhones: 100, txToPhones: 90, dropDup: 3, dropTag: 1);
    expect(hex(encodeBoxStatus(s)), statusHex);
    expect(decodeBoxStatus(unhex(statusHex)), s);
    expect(decodeBoxStatus(unhex(statusHex).sublist(0, 29)), isNull);
  });
  test('box names and passwords', () {
    expect(boxSsid(0x00A1B2C3), 'Vroo-A1B2C3');
    expect(setupSsid(0x00A1B2C3), 'Vroo-setup-A1B2C3');
    expect(newBoxPassword(Random(1)), matches(RegExp(r'^[a-hjkmnp-z2-9]{4}(-[a-hjkmnp-z2-9]{4}){3}$')));
  });
  test('box passwords are 8 to 63 printable ASCII characters', () {
    expect(isBoxPassword(pw), isTrue);
    expect(isBoxPassword('x' * 63), isTrue);
    expect(isBoxPassword('abcdefg'), isFalse); // 7
    expect(isBoxPassword('x' * 64), isFalse);
    expect(isBoxPassword('abcd\u2019efgh'), isFalse); // autocorrect's curly apostrophe
    expect(isBoxPassword('abcd\nefgh'), isFalse);
  });
}
