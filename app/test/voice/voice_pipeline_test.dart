// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/diag/clock.dart';
import 'package:vroo/diag/ride_log.dart';
import 'package:vroo/net/group_link.dart';
import 'package:vroo/voice/talk_slots.dart';
import 'package:vroo/voice/voice_gate.dart';
import 'package:vroo/voice/voice_pipeline.dart';
import 'package:vroo_audio/vroo_audio.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import '../fake_codec.dart';

/// A steady frame at [level]: 8000 is speech to the gate (about -12 dBFS), 10 is quiet.
Int16List steady(int level) => Int16List(320)..fillRange(0, 320, level);

/// One pipeline on fake audio, a fake codec and a fake clock that moves 20 ms per mic frame.
class Rig {
  Rig() {
    pipeline.start();
  }

  final audio = FakeVrooAudio();
  final clock = FakeClock(ms: 0, wall: DateTime.utc(2026, 10, 28));
  final logBuffer = StringBuffer();
  final sent = <VoiceFrame>[];
  final decoders = <FakeDecoder>[];
  final encoder = FakeEncoder();
  late final pipeline = VoicePipeline(
    audio: audio,
    encoder: encoder,
    newDecoder: () => FakeDecoder()..also(decoders.add),
    send: (f) async => sent.add(f),
    clock: clock,
    gate: VoiceGate(),
    slots: TalkSlots(),
    log: RideLog(logBuffer, clock),
  );

  /// Speaks [frames] into the mic, 20 ms apart.
  void mic(Int16List frame, [int times = 1]) {
    for (var k = 0; k < times; k++) {
      clock.ms += 20;
      audio.emitMic(frame);
    }
  }

  void hear(int src, int frameNo, int level, {int session = 1, Uint8List? opus}) => pipeline
      .onVoice(HeardVoice(src, session, VoiceFrame(frameNo: frameNo, opus: opus ?? packetOf(level))));

  Int16List get lastPlayed => audio.played.last;
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}

void main() {
  test('silence sends nothing, and speech goes out with its pre-roll frame numbers', () {
    final r = Rig()..mic(steady(10), 50);
    expect(r.sent, isEmpty);
    r.mic(steady(8000));
    expect([for (final f in r.sent) f.frameNo], [48, 49, 50]);
    expect(r.pipeline.talking, isTrue);
  });

  test('heard voice plays, one frame out for each mic frame', () {
    final r = Rig();
    for (var n = 0; n < 10; n++) {
      r.hear(2, n, 1000);
    }
    r.mic(steady(10), 10);
    expect(r.audio.played.length, 10);
    expect(r.audio.played.every((f) => f.every((s) => s == 1000)), isTrue);
  });

  test('held frames are dropped, not queued, with one busy tone', () {
    final r = Rig()..mic(steady(10), 50);
    var no = 0;
    for (var k = 0; k < 50; k++) {
      for (final src in [2, 3, 4, 5]) {
        r.hear(src, no, 100);
      }
      no++;
      r.mic(steady(8000)); // this rider talks over four others
    }
    expect(r.sent, isEmpty);
    expect(r.pipeline.held, isTrue);
    expect(RegExp(',slot,state=busy').allMatches(r.logBuffer.toString()).length, 1);
    r.mic(steady(8000), 40); // the others stopped: a slot frees after 500 ms
    expect(r.sent, isNotEmpty);
    // The others were last heard 20 ms before frame 99, so frame 124 is the first past 500 ms: current speech, not
    // the backlog held since frame 50.
    expect(r.sent.first.frameNo, 124);
  });

  test('up to 4 voices are mixed; a fifth sender is not played', () {
    final r = Rig();
    for (final src in [2, 3, 4, 5, 6]) {
      for (var n = 0; n < 3; n++) {
        r.hear(src, n, 1000);
      }
    }
    r.mic(steady(10));
    expect(r.lastPlayed.every((s) => s == 4000), isTrue);
  });

  test('muted: nothing is sent and silence is played', () {
    final r = Rig()..pipeline.muted = true;
    for (var n = 0; n < 3; n++) {
      r.hear(2, n, 1000);
    }
    r.mic(steady(10), 50);
    r.mic(steady(8000), 10);
    expect(r.sent, isEmpty);
    expect(r.audio.played.every((f) => f.every((s) => s == 0)), isTrue);
  });

  test("a new session from the same rider restarts that rider's buffer", () {
    final r = Rig();
    for (var n = 100; n < 103; n++) {
      r.hear(2, n, 1000);
    }
    r.mic(steady(10), 3);
    for (var n = 0; n < 3; n++) {
      r.hear(2, n, 2000, session: 2); // the rider's app restarted: frame numbers start again
    }
    r.mic(steady(10), 3);
    expect(r.audio.played.skip(3).every((f) => f.every((s) => s == 2000)), isTrue);
  });

  test('a sender quiet for 10 s is removed and its decoder closed', () {
    final r = Rig();
    for (var n = 0; n < 3; n++) {
      r.hear(2, n, 1000);
    }
    r.mic(steady(10), 502); // 10.04 s
    expect(r.decoders.single.closed, isTrue);
    expect(r.pipeline.stats.containsKey(2), isFalse);
  });

  test('alert audio mixes over the voices', () {
    final r = Rig()..pipeline.say(Int16List(420)..fillRange(0, 420, 500)); // 26 ms of alert
    r.mic(steady(10), 3);
    expect(r.audio.played[0].every((s) => s == 500), isTrue);
    expect(r.audio.played[1].sublist(0, 100).every((s) => s == 500), isTrue);
    expect(r.audio.played[1].sublist(100).every((s) => s == 0), isTrue);
    expect(r.audio.played[2].every((s) => s == 0), isTrue);
  });

  test("a packet the codec can't read is concealed, and nothing throws", () {
    final r = Rig();
    r.hear(2, 0, 1000);
    r.hear(2, 1, 0, opus: Uint8List(3)); // unreadable
    r.hear(2, 2, 1000);
    r.mic(steady(10), 3);
    expect(r.audio.played[1].every((s) => s == 0), isTrue);
    expect(r.audio.played[2].every((s) => s == 1000), isTrue);
  });

  test('stop closes the encoder and every decoder', () async {
    final r = Rig();
    for (var n = 0; n < 3; n++) {
      r.hear(2, n, 1000);
    }
    r.mic(steady(10));
    await r.pipeline.stop();
    expect([r.encoder.closed, r.decoders.single.closed], [true, true]);
  });
}
