// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import '../vroo_audio.dart';

/// A [VrooAudio] for tests: mic frames and events come from the test, and what's played or spoken is recorded.
/// Events are delivered at once, so a test sees their effect on the next line.
class FakeVrooAudio implements VrooAudio {
  FakeVrooAudio({this.startResult = StartResult.started});

  /// What [start] answers.
  StartResult startResult;

  /// While on, [synthesize] fails, as with no speech engine.
  bool speechFails = false;

  /// When set, [start] waits for it before answering, as a slow platform does.
  Completer<void>? startGate;

  /// Speech comes back as half a second at this steady level, so tests can find it in the mix.
  static const speechLevel = 1000;

  final played = <Int16List>[];
  final spoken = <String>[];
  bool running = false;
  final _mic = StreamController<Int16List>.broadcast(sync: true);
  final _events = StreamController<AudioEvent>.broadcast(sync: true);

  void emitMic(Int16List frame) => _mic.add(frame);

  void emit(AudioEvent e) => _events.add(e);

  @override
  Stream<Int16List> get micFrames => _mic.stream;

  @override
  Stream<AudioEvent> get events => _events.stream;

  @override
  Future<StartResult> start({required String notificationText}) async {
    await startGate?.future;
    running = startResult == StartResult.started;
    return startResult;
  }

  @override
  Future<void> stop() async => running = false;

  /// How many times [restart] was called.
  int restarts = 0;

  @override
  Future<void> restart() async => restarts++;

  @override
  void play(Int16List frame) => played.add(frame);

  @override
  Future<Int16List> synthesize(String text) async {
    spoken.add(text);
    if (speechFails) throw StateError('no speech engine');
    return Int16List(audioSampleRate ~/ 2)..fillRange(0, audioSampleRate ~/ 2, speechLevel);
  }
}
