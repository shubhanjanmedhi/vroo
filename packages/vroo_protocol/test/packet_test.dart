// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import 'fixtures.dart';
import 'hex.dart';

void main() {
  test('header is 15 big-endian bytes', () => expect(hex(encodeHeader(h)), '010310010203040a0b0c0d00000007'));
  test('header round-trips', () => expect(decodeHeader(encodeHeader(h)), h));
  test('short or wrong-version headers are rejected', () {
    expect(decodeHeader(Uint8List(14)), isNull);
    expect(decodeHeader(unhex('020310010203040a0b0c0d00000007')), isNull);
  });
  test('aad skips ttl', () => expect(hex(aadOf(encodeHeader(h))), '0103010203040a0b0c0d00000007'));
  test('nonce is src, session, seq', () => expect(hex(nonceOf(h)), '010203040a0b0c0d00000007'));
}
