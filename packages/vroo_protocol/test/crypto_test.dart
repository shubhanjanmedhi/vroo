// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import 'fixtures.dart';
import 'hex.dart';

void main() {
  late Sealer s;
  setUp(() async => s = Sealer(await GroupKeys.derive(secret)));

  test('seals the v1 vector', () async {
    expect(hex(await s.seal(h, payload)), sealed);
  });
  test('opens what it seals, even after a relay changed the ttl', () async {
    final p = await s.seal(h, payload)..[2] = 15;
    final o = (await s.open(p))!;
    expect(o.payload, payload);
    expect(o.header.ttl, 15);
  });
  test('wrong key, flipped bit or short packet opens to null', () async {
    final other = Sealer(await GroupKeys.derive(Uint8List(32)));
    final p = await s.seal(h, payload);
    expect(await other.open(p), isNull);
    expect(await s.open(Uint8List.fromList(p)..[20] ^= 1), isNull);
    expect(await s.open(p.sublist(0, 30)), isNull);
  });
}
