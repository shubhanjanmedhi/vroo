// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../vroo_audio.dart';

/// [VrooAudio] over the plugin's platform channels. Audio crosses them as int16 little-endian bytes.
class ChannelVrooAudio implements VrooAudio {
  static const _methods = MethodChannel('vroo_audio');
  static const _mic = EventChannel('vroo_audio/mic');
  static const _events = EventChannel('vroo_audio/events');
  static const _play = BasicMessageChannel<ByteData>('vroo_audio/play', BinaryCodec());

  @override
  late final Stream<Int16List> micFrames = _mic.receiveBroadcastStream().map((raw) => pcmFromBytes(raw as Uint8List));

  @override
  late final Stream<AudioEvent> events = _events.receiveBroadcastStream().expand((raw) {
    final e = eventFrom(raw as Map<Object?, Object?>);
    return e == null ? const <AudioEvent>[] : [e];
  });

  @override
  Future<StartResult> start({required String notificationText}) async {
    try {
      final answer = await _methods.invokeMethod<String>('start', {'notificationText': notificationText});
      return _byName(StartResult.values, answer) ?? StartResult.failed;
    } on PlatformException {
      return StartResult.failed;
    }
  }

  @override
  Future<void> stop() => _methods.invokeMethod<void>('stop');

  @override
  Future<void> restart() => _methods.invokeMethod<void>('restart');

  @override
  void play(Int16List frame) => unawaited(_play.send(ByteData.sublistView(bytesFromPcm(frame))));

  @override
  Future<Int16List> synthesize(String text) async {
    final speech = await _methods.invokeMapMethod<String, Object?>('synthesize', {'text': text});
    if (speech == null) throw StateError('the phone gave no speech');
    return resample(pcmFromBytes(speech['pcm']! as Uint8List), speech['rate']! as int, audioSampleRate);
  }
}

/// int16 little-endian bytes as samples. Reads through ByteData, so the bytes' offset needn't be even.
Int16List pcmFromBytes(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return Int16List.fromList([for (var i = 0; i + 1 < bytes.length; i += 2) data.getInt16(i, Endian.little)]);
}

Uint8List bytesFromPcm(Int16List pcm) {
  final data = ByteData(pcm.length * 2);
  for (var i = 0; i < pcm.length; i++) {
    data.setInt16(i * 2, pcm[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

/// One platform event, or null for one this version doesn't know.
AudioEvent? eventFrom(Map<Object?, Object?> m) => switch (m['type']) {
      'call' => switch (_byName(CallState.values, m['state'])) {
          final state? => CallStateChanged(state),
          null => null,
        },
      'interruption' => InterruptionChanged(m['began'] == true),
      'route' => RouteChanged(_byName(AudioRoute.values, m['output']) ?? AudioRoute.other, m['name'] as String? ?? '',
          m['rate'] as int? ?? 0),
      'failed' => AudioFailed(m['message'] as String? ?? ''),
      _ => null,
    };

T? _byName<T extends Enum>(List<T> values, Object? name) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}
