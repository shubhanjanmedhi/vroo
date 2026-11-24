// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vroo_opus/vroo_opus.dart';

/// [samples] of a [hz] sine at [dbfs] peak, 16 kHz, continuing from sample [start] so frames join smoothly.
Int16List sine(double hz, int samples, double dbfs, {int start = 0}) {
  final amp = 32767 * pow(10, dbfs / 20);
  return Int16List.fromList([for (var i = 0; i < samples; i++) (amp * sin(2 * pi * hz * (start + i) / 16000)).round()]);
}

/// RMS level in dBFS, floored at -90.
double rmsDb(Int16List frame) {
  final sum = frame.fold(0.0, (s, x) => s + x * x);
  final rms = sqrt(sum / frame.length);
  return rms < 1 ? -90 : 20 * log(rms / 32768) / ln10;
}

List<Int16List> frames(int n, {double hz = 440, double dbfs = -12}) =>
    [for (var k = 0; k < n; k++) sine(hz, 320, dbfs, start: k * 320)];

void main() {
  test('a 20 ms frame of voice-band sound becomes a small packet', () {
    final enc = OpusEncoder();
    final packets = frames(50).map(enc.encode).toList();
    enc.close();
    expect(packets.every((p) => p.isNotEmpty && p.length <= 120), isTrue);
    expect(packets.skip(10).fold(0, (s, p) => s + p.length) / 40, inInclusiveRange(20, 70));
  });

  test('decoded audio is about as loud as the input', () {
    final enc = OpusEncoder(), dec = OpusDecoder();
    final input = frames(50);
    final out = [for (final f in input) dec.decode(enc.encode(f))];
    for (var k = 5; k < 50; k++) {
      expect(rmsDb(out[k]), closeTo(rmsDb(input[k]), 3), reason: 'frame $k');
    }
    enc.close();
    dec.close();
  });

  test('silence stays quiet', () {
    final enc = OpusEncoder(), dec = OpusDecoder();
    for (var k = 0; k < 50; k++) {
      expect(rmsDb(dec.decode(enc.encode(Int16List(320)))), lessThan(-60), reason: 'frame $k');
    }
  });

  test('a lost frame is concealed with a full frame', () {
    final enc = OpusEncoder(), dec = OpusDecoder();
    for (final f in frames(5)) {
      dec.decode(enc.encode(f));
    }
    expect(dec.decode(null).length, 320);
  });

  test('FEC rebuilds a lost frame from the next packet', () {
    final enc = OpusEncoder(), dec = OpusDecoder();
    final input = frames(40);
    final p = input.map(enc.encode).toList();
    for (var k = 0; k < 30; k++) {
      dec.decode(p[k]);
    }
    final rebuilt = dec.decode(p[31], fec: true); // frame 30 is lost
    expect(rebuilt.length, 320);
    expect(rmsDb(rebuilt), closeTo(rmsDb(input[30]), 6));
    expect(dec.decode(p[31]).length, 320);
  });

  test('frames of the wrong length are refused', () {
    expect(() => OpusEncoder().encode(Int16List(319)), throwsArgumentError);
  });

  test('a closed encoder refuses to encode', () {
    final enc = OpusEncoder()..close();
    expect(() => enc.encode(Int16List(320)), throwsStateError);
    enc.close(); // safe to call twice
  });

  test('the libopus licence is included', () {
    expect(libopusLicense, allOf(contains('Xiph.Org'), contains('Redistribution and use in source and binary forms')));
  });
}
