// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo_audio/src/channel_vroo_audio.dart';
import 'package:vroo_audio/vroo_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('vroo_audio');
  const mic = EventChannel('vroo_audio/mic');
  const events = EventChannel('vroo_audio/events');
  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(mic, null);
    messenger.setMockStreamHandler(events, null);
    messenger.setMockMessageHandler('vroo_audio/play', null);
  });

  /// 640 bytes of samples -160..159, little-endian, starting one byte into a buffer, so the offset is odd.
  Uint8List oddFrame() {
    final buffer = Uint8List(641);
    final data = ByteData.sublistView(buffer, 1);
    for (var i = 0; i < 320; i++) {
      data.setInt16(i * 2, i - 160, Endian.little);
    }
    return Uint8List.sublistView(buffer, 1);
  }

  test('mic bytes become 320-sample frames, also from an odd offset', () async {
    final direct = pcmFromBytes(oddFrame());
    expect([direct.length, direct.first, direct.last], [320, -160, 159]);
    messenger.setMockStreamHandler(mic, MockStreamHandler.inline(onListen: (_, sink) => sink.success(oddFrame())));
    final frame = await createVrooAudio().micFrames.first;
    expect([frame.length, frame.first, frame.last], [320, -160, 159]);
  });

  test('call, interruption and route events are decoded', () async {
    messenger.setMockStreamHandler(events, MockStreamHandler.inline(onListen: (_, sink) {
      sink.success({'type': 'call', 'state': 'ringing'});
      sink.success({'type': 'interruption', 'began': true});
      sink.success({'type': 'route', 'output': 'bluetooth', 'name': 'Intercom', 'rate': 16000});
      sink.success({'type': 'failed', 'message': 'no mic'});
      sink.success({'type': 'route', 'output': 'something new', 'name': 'x', 'rate': 8000});
      sink.success({'type': 'call', 'state': 'something new'}); // unknown: dropped
      sink.success({'type': 'interruption', 'began': false});
    }));
    final got = await createVrooAudio().events.take(6).toList();
    expect((got[0] as CallStateChanged).state, CallState.ringing);
    expect((got[1] as InterruptionChanged).began, isTrue);
    final route = got[2] as RouteChanged;
    expect([route.output, route.name, route.hardwareRate], [AudioRoute.bluetooth, 'Intercom', 16000]);
    expect((got[3] as AudioFailed).message, 'no mic');
    expect((got[4] as RouteChanged).output, AudioRoute.other);
    expect((got[5] as InterruptionChanged).began, isFalse);
  });

  test("start maps the platform's answer", () async {
    for (final (answer, result) in [
      ('started', StartResult.started),
      ('micDenied', StartResult.micDenied),
      ('failed', StartResult.failed),
      ('something new', StartResult.failed),
    ]) {
      messenger.setMockMethodCallHandler(methods, (call) async {
        expect([call.method, call.arguments], ['start', {'notificationText': 'Riding'}]);
        return answer;
      });
      expect(await createVrooAudio().start(notificationText: 'Riding'), result, reason: answer);
    }
    messenger.setMockMethodCallHandler(methods, (call) async => throw PlatformException(code: 'error'));
    expect(await createVrooAudio().start(notificationText: 'Riding'), StartResult.failed);
  });

  test('restart asks the platform to restart the streams', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(methods, (call) async => calls.add(call.method));
    await createVrooAudio().restart();
    expect(calls, ['restart']);
  });

  test('play sends 640 little-endian bytes', () async {
    ByteData? sent;
    messenger.setMockMessageHandler('vroo_audio/play', (data) async {
      sent = data;
      return null;
    });
    createVrooAudio().play(Int16List(320)
      ..[0] = 0x0102
      ..[319] = -2);
    await pumpEventQueue();
    expect(sent!.lengthInBytes, 640);
    expect([sent!.getUint8(0), sent!.getUint8(1), sent!.getInt16(638, Endian.little)], [0x02, 0x01, -2]);
  });

  test('synthesize resamples speech to 16 kHz', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect([call.method, call.arguments], ['synthesize', {'text': 'Meera joined'}]);
      return {'rate': 22050, 'pcm': Uint8List(2205 * 2)}; // 0.1 s
    });
    expect((await createVrooAudio().synthesize('Meera joined')).length, 1600);
  });
}
