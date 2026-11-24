// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import 'fixtures.dart';
import 'hex.dart';

void main() {
  test('envelope is tag then packet', () {
    expect(hex(wrapEnvelope(unhex(tagHex), unhex(sealed))), '$tagHex$sealed');
    final u = unwrapEnvelope(unhex('$tagHex$sealed'))!;
    expect(hex(u.groupTag), tagHex);
    expect(hex(u.packet), sealed);
    expect(unwrapEnvelope(Uint8List(38)), isNull);
  });
}
