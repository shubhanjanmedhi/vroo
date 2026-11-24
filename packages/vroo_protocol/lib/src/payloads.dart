// SPDX-License-Identifier: GPL-3.0-or-later
//
// Payload codecs (architecture §5.3). Integers are big-endian; u32 fields keep the low 32 bits, so the
// millisecond clock in BEAT and ECHO wraps like the u32 it is. Decoders ignore trailing bytes.
import 'dart:convert';
import 'dart:typed_data';

const _maxNameBytes = 32;

abstract final class BeatFlags {
  static const talking = 1, onCall = 2, hasInternet = 4, hasBox = 8, bluetoothOn = 16, diagnostics = 32;
}

/// The heartbeat. [lat], [lon] and [accuracyM] travel only with [BeatFlags.diagnostics]; before the first GPS
/// fix lat and lon go out as NaN, and decode as null.
class Beat {
  const Beat({
    required this.platform,
    required this.flags,
    required this.battery,
    required this.sentAtMs,
    required this.btNeighbors,
    required this.name,
    this.lat,
    this.lon,
    this.accuracyM,
  });

  /// 0 iOS, 1 Android.
  final int platform;

  /// [BeatFlags] bits.
  final int flags;

  final int battery;

  /// The sender's millisecond clock.
  final int sentAtMs;

  /// Rider IDs of the sender's Bluetooth neighbours, for the Bluetooth relay rule.
  final List<int> btNeighbors;

  final String name;
  final double? lat, lon;
  final int? accuracyM;

  (int, int, int, int, String, double?, double?, int?) get _fields =>
      (platform, flags, battery, sentAtMs, name, lat, lon, accuracyM);

  @override
  bool operator ==(Object other) =>
      other is Beat && other._fields == _fields && _sameInts(other.btNeighbors, btNeighbors);

  @override
  int get hashCode => Object.hash(_fields, Object.hashAll(btNeighbors));
}

Uint8List encodeBeat(Beat b) {
  final out = BytesBuilder(copy: false)
    ..add([b.platform, b.flags, b.battery])
    ..add(_u32(b.sentAtMs))
    ..addByte(b.btNeighbors.length);
  for (final id in b.btNeighbors) {
    out.add(_u32(id));
  }
  out.add(_name(b.name));
  if (b.flags & BeatFlags.diagnostics != 0) {
    out.add((ByteData(10)
          ..setFloat32(0, b.lat ?? double.nan)
          ..setFloat32(4, b.lon ?? double.nan)
          ..setUint16(8, (b.accuracyM ?? 0xFFFF).clamp(0, 0xFFFF)))
        .buffer
        .asUint8List());
  }
  return out.toBytes();
}

Beat? decodeBeat(Uint8List p) {
  if (p.length < 8) return null;
  final nameAt = 8 + 4 * p[7];
  if (p.length <= nameAt) return null;
  final gpsAt = nameAt + 1 + p[nameAt];
  final diagnostics = p[1] & BeatFlags.diagnostics != 0;
  if (p.length < gpsAt + (diagnostics ? 10 : 0)) return null;
  final d = ByteData.sublistView(p);
  final lat = diagnostics ? d.getFloat32(gpsAt) : double.nan;
  final lon = diagnostics ? d.getFloat32(gpsAt + 4) : double.nan;
  final fix = !lat.isNaN && !lon.isNaN;
  return Beat(
    platform: p[0],
    flags: p[1],
    battery: p[2],
    sentAtMs: d.getUint32(3),
    btNeighbors: [for (var i = 0; i < p[7]; i++) d.getUint32(8 + 4 * i)],
    name: _readName(p, nameAt),
    lat: fix ? lat : null,
    lon: fix ? lon : null,
    accuracyM: fix ? d.getUint16(gpsAt + 8) : null,
  );
}

/// A reply to a BEAT, so its sender can measure the round trip.
class Echo {
  const Echo({required this.target, required this.sentAtMs});

  /// The rider whose BEAT this answers.
  final int target;

  /// That BEAT's sentAt, sent back unchanged.
  final int sentAtMs;
}

Uint8List encodeEcho(Echo e) => Uint8List.fromList([..._u32(e.target), ..._u32(e.sentAtMs)]);

Echo? decodeEcho(Uint8List p) {
  if (p.length < 8) return null;
  final d = ByteData.sublistView(p);
  return Echo(target: d.getUint32(0), sentAtMs: d.getUint32(4));
}

/// The first packet both ways on a Bluetooth link.
class Hello {
  const Hello({required this.platform, required this.name});

  /// 0 iOS, 1 Android.
  final int platform;
  final String name;
}

Uint8List encodeHello(Hello h) => Uint8List.fromList([h.platform, ..._name(h.name)]);

Hello? decodeHello(Uint8List p) =>
    p.length < 2 || p.length < 2 + p[1] ? null : Hello(platform: p[0], name: _readName(p, 1));

/// One 20 ms Opus frame and its number, which the jitter buffer orders by.
class VoiceFrame {
  const VoiceFrame({required this.frameNo, required this.opus});

  final int frameNo;
  final Uint8List opus;
}

Uint8List encodeVoice(VoiceFrame v) => Uint8List.fromList([..._u32(v.frameNo), ...v.opus]);

VoiceFrame? decodeVoice(Uint8List p) =>
    p.length < 4 ? null : VoiceFrame(frameNo: ByteData.sublistView(p).getUint32(0), opus: p.sublist(4));

Uint8List _u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();

/// A u8 length, then [name] as UTF-8, cut to 32 bytes without splitting a character.
List<int> _name(String name) {
  var b = utf8.encode(name);
  if (b.length > _maxNameBytes) {
    var end = _maxNameBytes;
    while (b[end] & 0xC0 == 0x80) {
      end--; // b[end] continues the previous character, so the cut would split it
    }
    b = b.sublist(0, end);
  }
  return [b.length, ...b];
}

/// The name whose length byte is at [at]. The caller has checked the bytes are there.
String _readName(Uint8List p, int at) => utf8.decode(p.sublist(at + 1, at + 1 + p[at]), allowMalformed: true);

bool _sameInts(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
