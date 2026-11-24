// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:vroo_protocol/vroo_protocol.dart';

import 'hex.dart';

/// The fixed test secret 00 01 … 1f. Every v1 vector in these tests derives from it (see tool/oracle.py).
final secret = Uint8List.fromList(List.generate(32, (i) => i));

/// The v1 test header: a BEAT from rider 0x01020304, session 0x0A0B0C0D, seq 7.
const h = PacketHeader(version: 1, type: PacketType.beat, ttl: 16, src: 0x01020304, session: 0x0A0B0C0D, seq: 7);

/// The group tag derived from [secret].
const tagHex = 'a9968d2a1c900625';

/// The test beat payload: Android, has internet and a box, battery 77, sentAt 123456, no neighbours, name 'Ravi'.
final payload = unhex('010c4d0001e240000452617669');

/// [h] and [payload], sealed with the key derived from [secret].
const sealed = '010310010203040a0b0c0d000000070d0130763dd9b37750eade2038afcac4ca4ded54f5a07110b999e56896';
