// SPDX-License-Identifier: GPL-3.0-or-later
//
// Codec stand-ins for pipeline tests: a "packet" is the frame's first sample in two bytes, so what plays shows
// which frame it came from and how (decoded, rebuilt by FEC at half the value, or concealed as silence).
import 'dart:typed_data';

import 'package:vroo_opus/vroo_opus.dart';

Uint8List packetOf(int level) => Uint8List.fromList([level >> 8 & 0xFF, level & 0xFF]);

class FakeEncoder implements OpusEncoder {
  bool closed = false;

  @override
  int get frameSamples => 320;

  @override
  Uint8List encode(Int16List frame) => packetOf(frame[0]);

  @override
  void close() => closed = true;
}

/// Throws for a packet that isn't two bytes, like libopus with a packet it can't read.
class FakeDecoder implements OpusDecoder {
  int decoded = 0, recovered = 0, concealed = 0;
  bool closed = false;

  @override
  int get frameSamples => 320;

  @override
  Int16List decode(Uint8List? packet, {bool fec = false}) {
    if (packet == null) {
      concealed++;
      return Int16List(320);
    }
    if (packet.length != 2) throw const FormatException('unreadable packet');
    final level = (packet[0] << 8 | packet[1]).toSigned(16);
    if (fec) {
      recovered++;
    } else {
      decoded++;
    }
    return Int16List(320)..fillRange(0, 320, fec ? level ~/ 2 : level);
  }

  @override
  void close() => closed = true;
}
