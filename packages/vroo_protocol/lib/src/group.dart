// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'constants.dart';

/// Everything a phone derives from a group's 32-byte secret (architecture §5.1).
class GroupKeys {
  GroupKeys._(this.secret, this.key, this.tag, this.channel, this.bleIos, this.bleAndroid);

  final Uint8List secret;

  /// ChaCha20-Poly1305 key that seals every packet.
  final Uint8List key;

  /// Plain routing tag that boxes and the relay server filter on. It reveals nothing about [key].
  final Uint8List tag;

  /// Wi-Fi channel the group's boxes use: 1, 6 or 11, so nearby groups spread out.
  final int channel;

  /// Bluetooth service UUIDs for the fallback path, one per platform.
  final String bleIos, bleAndroid;

  static Future<GroupKeys> derive(Uint8List secret) async {
    if (secret.length != secretSize) {
      throw ArgumentError.value(secret.length, 'secret', 'must be $secretSize bytes');
    }
    final key = await _hkdf(secret, 'vroo/v1/key', 32);
    final tag = await _hkdf(secret, 'vroo/v1/tag', groupTagSize);
    return GroupKeys._(
      Uint8List.fromList(secret),
      key,
      tag,
      const [1, 6, 11][tag[0] % 3],
      _uuid(await _hkdf(secret, 'vroo/v1/ble-ios', 16)),
      _uuid(await _hkdf(secret, 'vroo/v1/ble-android', 16)),
    );
  }
}

/// HKDF-SHA256 with an empty salt.
Future<Uint8List> _hkdf(Uint8List secret, String info, int length) async {
  final out = await Hkdf(hmac: Hmac.sha256(), outputLength: length)
      .deriveKey(secretKey: SecretKey(secret), nonce: const [], info: utf8.encode(info));
  return Uint8List.fromList(await out.extractBytes());
}

/// RFC 4122 version-4 bits over 16 derived bytes, upper-case 8-4-4-4-12.
String _uuid(Uint8List b) {
  b[6] = (b[6] & 0x0F) | 0x40;
  b[8] = (b[8] & 0x3F) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
