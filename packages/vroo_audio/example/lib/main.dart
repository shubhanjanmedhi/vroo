// SPDX-License-Identifier: GPL-3.0-or-later
//
// The audio check: proves the voice path on a real phone and intercom before the app uses it. "Hear yourself" plays
// the mic back half a second later, through the same call link the ride uses.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vroo_audio/vroo_audio.dart';

void main() => runApp(MaterialApp(
      title: 'Vroo audio check',
      theme: ThemeData(colorSchemeSeed: Colors.deepOrange),
      home: const AudioCheck(),
    ));

class AudioCheck extends StatefulWidget {
  const AudioCheck({super.key});

  @override
  State<AudioCheck> createState() => _AudioCheckState();
}

class _AudioCheckState extends State<AudioCheck> {
  final _audio = createVrooAudio();
  final _log = <String>[];
  final _delay = <Int16List>[]; // the last 500 ms of the mic, for Hear yourself
  final _speech = <Int16List>[]; // the test message, a frame at a time
  StreamSubscription<Int16List>? _mic;
  StreamSubscription<AudioEvent>? _events;
  bool _running = false, _hearYourself = false;
  String _route = '…';
  double _levelDb = -90;
  int _frames = 0;

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _note(String line) => setState(() => _log.insert(0, '${TimeOfDay.now().format(context)}  $line'));

  Future<void> _start() async {
    await [Permission.microphone, Permission.notification, Permission.bluetoothConnect].request();
    _events = _audio.events.listen((e) {
      if (e is RouteChanged) setState(() => _route = '${e.output.name} ${e.name}'.trim());
      _note(switch (e) {
        CallStateChanged(:final state) => 'call ${state.name}',
        InterruptionChanged(:final began) => 'interruption ${began ? 'began' : 'ended'}',
        RouteChanged(:final output, :final name, :final hardwareRate) => 'route ${output.name} $name $hardwareRate Hz',
        AudioFailed(:final message) => 'failed: $message',
      });
    });
    _mic = _audio.micFrames.listen(_onMic);
    final result = await _audio.start(notificationText: 'Audio check');
    setState(() => _running = result == StartResult.started);
    _note('start: ${result.name}');
  }

  Future<void> _stop() async {
    if (!_running) return;
    await _audio.stop();
    unawaited(_mic?.cancel());
    unawaited(_events?.cancel());
    _delay.clear();
    _speech.clear();
    if (mounted) setState(() => _running = false);
  }

  /// One frame in, one frame out: the mic paces playback.
  void _onMic(Int16List frame) {
    _delay.add(frame);
    final late = _delay.length > 25 ? _delay.removeAt(0) : null;
    _audio.play(_speech.isNotEmpty ? _speech.removeAt(0) : (_hearYourself && late != null ? late : Int16List(320)));
    if (++_frames % 10 == 0) setState(() => _levelDb = _db(frame));
  }

  Future<void> _sayTestMessage() async {
    try {
      final pcm = await _audio.synthesize('This is Vroo. Can you hear me?');
      for (var i = 0; i < pcm.length; i += 320) {
        _speech.add(Int16List(320)..setRange(0, min(320, pcm.length - i), pcm, i));
      }
      _note('speech: ${(pcm.length / 16000).toStringAsFixed(1)} s');
    } catch (e) {
      _note('speech failed: $e');
    }
  }

  static double _db(Int16List frame) {
    final rms = sqrt(frame.fold(0.0, (s, x) => s + x * x) / frame.length);
    return rms < 1 ? -90 : 20 * log(rms / 32768) / ln10;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Vroo audio check')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: _running ? null : _start, child: const Text('Start')),
            OutlinedButton(onPressed: _running ? _stop : null, child: const Text('Stop')),
          ]),
          ListTile(title: Text('Route: $_route'), subtitle: Text('Mic level: ${_levelDb.toStringAsFixed(0)} dBFS')),
          SwitchListTile(
            title: const Text('Hear yourself'),
            subtitle: const Text('Plays your voice back half a second later'),
            value: _hearYourself,
            onChanged: _running ? (on) => setState(() => _hearYourself = on) : null,
          ),
          OutlinedButton(onPressed: _running ? _sayTestMessage : null, child: const Text('Say a test message')),
          const Divider(),
          for (final line in _log) Text(line, style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}
