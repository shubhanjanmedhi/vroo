// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/voice/voice_gate.dart';

/// A 20 ms frame of 440 Hz whose RMS level is [db] dBFS; -90 gives digital silence.
Int16List level(double db) {
  if (db <= -90) return Int16List(320);
  final amp = 32768 * pow(10, db / 20) * sqrt2;
  return Int16List.fromList([for (var i = 0; i < 320; i++) (amp * sin(2 * pi * 440 * i / 16000)).round()]);
}

/// Pushes [n] frames at [db] and returns how many frames the gate sent.
int pushMany(VoiceGate gate, int n, double db) {
  var sent = 0;
  for (var k = 0; k < n; k++) {
    sent += gate.push(level(db)).length;
  }
  return sent;
}

void main() {
  test('silence and quiet noise send nothing', () {
    final gate = VoiceGate();
    expect(pushMany(gate, 250, -90) + pushMany(gate, 250, -60), 0);
    expect(gate.open, isFalse);
  });

  test('speech opens the gate with 40 ms of pre-roll', () {
    final gate = VoiceGate();
    final quiet = [for (var k = 0; k < 50; k++) level(-60)];
    for (final f in quiet) {
      expect(gate.push(f), isEmpty);
    }
    final loud = level(-20);
    final sent = gate.push(loud);
    expect(sent.length, 3);
    expect(identical(sent[0], quiet[48]) && identical(sent[1], quiet[49]) && identical(sent[2], loud), isTrue);
    expect(gate.open, isTrue);
  });

  test('the gate stays open 300 ms after speech, then closes', () {
    final gate = VoiceGate();
    pushMany(gate, 50, -60);
    expect(pushMany(gate, 10, -20), 2 + 10);
    expect(pushMany(gate, 15, -60), 15);
    expect(gate.open, isFalse);
    expect(pushMany(gate, 5, -60), 0);
  });

  test('a steady loud noise closes the gate within 6 s', () {
    final gate = VoiceGate();
    pushMany(gate, 50, -60);
    var lastSent = -1;
    for (var k = 0; k < 300; k++) {
      if (gate.push(level(-25)).isNotEmpty) lastSent = k;
    }
    expect(lastSent, inInclusiveRange(0, 298));
    expect(gate.open, isFalse);
  });

  test('a 6 dB threshold opens on soft speech that 24 dB ignores', () {
    final sensitive = VoiceGate(thresholdDb: 6), deaf = VoiceGate(thresholdDb: 24);
    pushMany(sensitive, 50, -60);
    pushMany(deaf, 50, -60);
    expect(sensitive.push(level(-45)), isNotEmpty);
    expect(deaf.push(level(-45)), isEmpty);
  });

  test('frameDb measures RMS in dBFS', () {
    expect(frameDb(level(-20)), closeTo(-20, 0.1));
    expect(frameDb(Int16List(320)), -90);
  });
}
