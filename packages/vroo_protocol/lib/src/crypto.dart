// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'constants.dart';
import 'group.dart';
import 'packet.dart';

/// A packet that opened: its header as received (ttl included) and the decrypted payload.
class Opened {
  const Opened(this.header, this.payload);

  final PacketHeader header;
  final Uint8List payload;
}

/// Seals and opens packets with the group key: ChaCha20-Poly1305 over the payload, with the header
/// (minus ttl) authenticated (architecture §5.2).
class Sealer {
  Sealer(GroupKeys keys) : _key = SecretKey(keys.key);

  static final _aead = Chacha20.poly1305Aead();
  final SecretKey _key;

  /// header ‖ ciphertext ‖ 16-byte tag.
  Future<Uint8List> seal(PacketHeader header, Uint8List payload) async {
    final head = encodeHeader(header);
    final box = await _aead.encrypt(payload, secretKey: _key, nonce: nonceOf(header), aad: aadOf(head));
    return Uint8List.fromList([...head, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Null if [packet] is short, not protocol v1, or fails authentication (wrong group or altered).
  Future<Opened?> open(Uint8List packet) async {
    final header = decodeHeader(packet);
    if (header == null || packet.length < headerSize + aeadTagSize) return null;
    final box = SecretBox(
      packet.sublist(headerSize, packet.length - aeadTagSize),
      nonce: nonceOf(header),
      mac: Mac(packet.sublist(packet.length - aeadTagSize)),
    );
    try {
      return Opened(header, Uint8List.fromList(await _aead.decrypt(box, secretKey: _key, aad: aadOf(packet))));
    } on SecretBoxAuthenticationError {
      return null;
    }
  }
}
