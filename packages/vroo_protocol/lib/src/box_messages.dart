// SPDX-License-Identifier: GPL-3.0-or-later
//
// Box messages: plain (unencrypted) and only between a box and its own phones (architecture §5.2).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'constants.dart';

const _version = 1;
const _statusSize = 30;
const _passwordChars = 'abcdefghjkmnpqrstuvwxyz23456789';

/// BOX_CONFIG: the fields a phone sets on its box. Only the fields given change.
class BoxConfig {
  const BoxConfig({this.groupTag, this.channel, this.wifiPassword});

  final Uint8List? groupTag;

  /// 1, 6 or 11.
  final int? channel;

  /// The box hotspot's WPA2 password: 8–63 printable ASCII characters.
  final String? wifiPassword;
}

Uint8List encodeBoxConfig(BoxConfig c) {
  final pw = c.wifiPassword == null ? null : ascii.encode(c.wifiPassword!);
  return Uint8List.fromList([
    _version,
    BoxMsgType.config,
    (c.groupTag == null ? 0 : 1) | (c.channel == null ? 0 : 2) | (pw == null ? 0 : 4),
    ...?c.groupTag,
    ?c.channel,
    if (pw != null) ...[pw.length, ...pw],
  ]);
}

/// Null unless [b] is a well-formed BOX_CONFIG whose values the box would accept.
BoxConfig? decodeBoxConfig(Uint8List b) {
  if (b.length < 3 || b[0] != _version || b[1] != BoxMsgType.config) return null;
  final mask = b[2];
  var at = 3;
  Uint8List? tag;
  int? channel;
  String? pw;
  if (mask & 1 != 0) {
    if (b.length < at + groupTagSize) return null;
    tag = b.sublist(at, at + groupTagSize);
    at += groupTagSize;
  }
  if (mask & 2 != 0) {
    if (b.length <= at || !const [1, 6, 11].contains(b[at])) return null;
    channel = b[at++];
  }
  if (mask & 4 != 0) {
    if (b.length <= at) return null;
    final n = b[at++];
    if (n < 8 || n > 63 || b.length < at + n) return null;
    final chars = b.sublist(at, at + n);
    if (chars.any((c) => c < 0x20 || c > 0x7E)) return null;
    pw = String.fromCharCodes(chars);
  }
  return BoxConfig(groupTag: tag, channel: channel, wifiPassword: pw);
}

/// BOX_STATUS: what a box reports to its phones every second.
class BoxStatus {
  const BoxStatus({
    required this.boxId,
    required this.fwVersion,
    required this.uptimeS,
    required this.setupMode,
    required this.phones,
    required this.rxFromPhones,
    required this.txToPhones,
    required this.dropDup,
    required this.dropTag,
  });

  final int boxId, fwVersion, uptimeS;

  /// True while the box runs its open setup hotspot.
  final bool setupMode;

  /// Phones the box heard from in the last 30 s.
  final int phones;

  /// Packet counters: received from and sent to phones, and dropped as duplicates or for a foreign group tag.
  final int rxFromPhones, txToPhones, dropDup, dropTag;

  (int, int, int, bool, int, int, int, int, int) get _fields =>
      (boxId, fwVersion, uptimeS, setupMode, phones, rxFromPhones, txToPhones, dropDup, dropTag);

  @override
  bool operator ==(Object other) => other is BoxStatus && other._fields == _fields;

  @override
  int get hashCode => _fields.hashCode;

  @override
  String toString() => 'BoxStatus$_fields';
}

Uint8List encodeBoxStatus(BoxStatus s) => (ByteData(_statusSize)
      ..setUint8(0, _version)
      ..setUint8(1, BoxMsgType.status)
      ..setUint32(2, s.boxId)
      ..setUint16(6, s.fwVersion)
      ..setUint32(8, s.uptimeS)
      ..setUint8(12, s.setupMode ? 1 : 0)
      ..setUint8(13, s.phones)
      ..setUint32(14, s.rxFromPhones)
      ..setUint32(18, s.txToPhones)
      ..setUint32(22, s.dropDup)
      ..setUint32(26, s.dropTag))
    .buffer
    .asUint8List();

BoxStatus? decodeBoxStatus(Uint8List b) {
  if (b.length < _statusSize || b[0] != _version || b[1] != BoxMsgType.status) return null;
  final d = ByteData.sublistView(b);
  return BoxStatus(
    boxId: d.getUint32(2),
    fwVersion: d.getUint16(6),
    uptimeS: d.getUint32(8),
    setupMode: b[12] & 1 != 0,
    phones: b[13],
    rxFromPhones: d.getUint32(14),
    txToPhones: d.getUint32(18),
    dropDup: d.getUint32(22),
    dropTag: d.getUint32(26),
  );
}

/// The hotspot name of a configured box, e.g. `Vroo-A1B2C3`.
String boxSsid(int boxId) => 'Vroo-${_idDigits(boxId)}';

/// The open hotspot a box runs until it's set up, e.g. `Vroo-setup-A1B2C3`.
String setupSsid(int boxId) => 'Vroo-setup-${_idDigits(boxId)}';

String _idDigits(int boxId) => (boxId & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0');

/// Whether the box would take [p] as its WPA2 password: 8–63 printable ASCII characters, the BOX_CONFIG rule.
bool isBoxPassword(String p) => p.length >= 8 && p.length <= 63 && p.codeUnits.every((c) => c >= 0x20 && c <= 0x7E);

/// A new hotspot password such as `abcd-efgh-jkmn-pqrs`, without look-alike characters.
/// Pass `Random.secure()` everywhere except tests.
String newBoxPassword(Random r) => [
      for (var g = 0; g < 4; g++)
        String.fromCharCodes([for (var i = 0; i < 4; i++) _passwordChars.codeUnitAt(r.nextInt(_passwordChars.length))]),
    ].join('-');
