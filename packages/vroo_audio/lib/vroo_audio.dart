// SPDX-License-Identifier: GPL-3.0-or-later

/// Voice in and out through the intercom's call link (architecture §4.5): 20 ms frames of 16 kHz mono audio, the
/// phone's calls and routes, speech as audio, and keeping the app alive for the ride. Mixing and decisions stay in
/// Dart.
library;

import 'dart:typed_data';

import 'src/channel_vroo_audio.dart';

export 'src/fake_vroo_audio.dart';
export 'src/resample.dart';

const audioSampleRate = 16000, audioFrameSamples = 320;

enum CallState { idle, ringing, active }

enum AudioRoute { bluetooth, wired, speaker, earpiece, other }

enum StartResult { started, micDenied, failed }

sealed class AudioEvent {}

/// The phone's own call, from the first ring (or from dialling) until it's idle again.
final class CallStateChanged extends AudioEvent {
  CallStateChanged(this.state);

  final CallState state;
}

/// Another app took the audio for a while: an assistant, an alarm, another app's call.
final class InterruptionChanged extends AudioEvent {
  InterruptionChanged(this.began);

  final bool began;
}

/// Where the voice goes in and out now.
final class RouteChanged extends AudioEvent {
  RouteChanged(this.output, this.name, this.hardwareRate);

  final AudioRoute output;
  final String name;
  final int hardwareRate;
}

final class AudioFailed extends AudioEvent {
  AudioFailed(this.message);

  final String message;
}

abstract interface class VrooAudio {
  /// The rider's voice, [audioFrameSamples] samples at a time.
  Stream<Int16List> get micFrames;

  Stream<AudioEvent> get events;

  /// Opens the call-style session on the intercom, starts mic and playback, and keeps the app alive until [stop]:
  /// background audio on iOS, a foreground service showing [notificationText] on Android.
  Future<StartResult> start({required String notificationText});

  Future<void> stop();

  /// Starts the mic and playback afresh without ending the ride (on Android the foreground service stays): for a
  /// mic that has gone quiet. Problems come back as [AudioFailed].
  Future<void> restart();

  /// Queues one frame of [audioFrameSamples] samples for the helmet.
  void play(Int16List frame);

  /// [text] in the phone's own voice, as [audioSampleRate] mono audio to mix into the output.
  Future<Int16List> synthesize(String text);
}

VrooAudio createVrooAudio() => ChannelVrooAudio();
