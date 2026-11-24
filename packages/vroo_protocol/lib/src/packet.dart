// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'constants.dart';

/// The 15 plain bytes in front of every sealed packet (architecture §5.2).
class PacketHeader {
  const PacketHeader({
    required this.version,
    required this.type,
    required this.ttl,
    required this.src,
    required this.session,
    required this.seq,
  });

  final int version;

  /// A [PacketType].
  final int type;

  /// Hops left. Relays lower it, so it's left out of the authenticated bytes.
  final int ttl;

  /// The sender's rider ID, its ride session, and its packet counter within that session.
  final int src, session, seq;

  (int, int, int, int, int, int) get _fields => (version, type, ttl, src, session, seq);

  @override
  bool operator ==(Object other) => other is PacketHeader && other._fields == _fields;

  @override
  int get hashCode => _fields.hashCode;

  @override
  String toString() => 'PacketHeader$_fields';
}

Uint8List encodeHeader(PacketHeader h) => (ByteData(headerSize)
      ..setUint8(0, h.version)
      ..setUint8(1, h.type)
      ..setUint8(2, h.ttl)
      ..setUint32(3, h.src)
      ..setUint32(7, h.session)
      ..setUint32(11, h.seq))
    .buffer
    .asUint8List();

/// The header at the front of [packet], or null if it's too short or not protocol v1.
PacketHeader? decodeHeader(Uint8List packet) {
  if (packet.length < headerSize || packet[0] != protocolVersion) return null;
  final d = ByteData.sublistView(packet);
  return PacketHeader(
    version: packet[0],
    type: packet[1],
    ttl: packet[2],
    src: d.getUint32(3),
    session: d.getUint32(7),
    seq: d.getUint32(11),
  );
}

/// The authenticated header bytes: all but ttl (byte 2).
Uint8List aadOf(Uint8List packetOrHeader) => Uint8List(headerSize - 1)
  ..setRange(0, 2, packetOrHeader)
  ..setRange(2, headerSize - 1, packetOrHeader, 3);

/// src ‖ session ‖ seq: 12 bytes that never repeat for a group key.
Uint8List nonceOf(PacketHeader h) => encodeHeader(h).sublist(3);
