// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import 'fixtures.dart';
import 'hex.dart';

void main() {
  test('derives the v1 group values', () async {
    final k = await GroupKeys.derive(secret);
    expect(hex(k.key), '5d5963441c8d63c15877eaf570cfa8636c65e94ab6b39abdb3fa0e26fb072d72');
    expect(hex(k.tag), 'a9968d2a1c900625');
    expect(k.channel, 6);
    expect(k.bleIos, '3A71E67C-5341-4D83-BC33-B18B4C5E1151');
    expect(k.bleAndroid, 'C048D642-ED40-4171-A32C-FB272D6C5C6B');
  });

  test('rejects a secret that is not 32 bytes', () {
    expect(GroupKeys.derive(Uint8List(31)), throwsArgumentError);
  });
}
