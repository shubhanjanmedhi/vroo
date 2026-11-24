// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vroo_audio/vroo_audio.dart';
import 'package:vroo_net/vroo_net.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import '../diag/clock.dart';
import '../diag/ride_log.dart';
import '../net/box_setup.dart';
import '../net/group_link.dart';
import '../net/peer.dart';
import '../net/relay_address.dart';
import '../ride/ride_engine.dart';
import '../rider_store.dart';
import '../voice/voice_pipeline.dart';
import 'box_hint.dart';
import 'box_setup_screen.dart';

/// Android asks at run time for the mic, and for notifications (13+) and Bluetooth (12+), which may be refused.
/// On iPhone, vroo_audio asks for the mic itself when the ride starts.
Future<void> askRidePermissions() async {
  if (Platform.isAndroid) {
    await [Permission.microphone, Permission.notification, Permission.bluetoothConnect].request();
  }
}

/// A ride: runs the RideEngine, logs to a file, and shows what it sees.
class RideScreen extends StatefulWidget {
  const RideScreen({
    super.key,
    required this.net,
    required this.audio,
    this.box,
    required this.group,
    required this.riderId,
    required this.riderName,
  });

  final VrooNet net;
  final VrooAudio audio;

  /// The rider's box, or null to ride on mobile data alone.
  final SavedBox? box;
  final Invite group;
  final int riderId;
  final String riderName;

  @override
  State<RideScreen> createState() => _RideScreenState();
}

class _RideScreenState extends State<RideScreen> {
  final _clock = SystemClock();
  RideEngine? _engine;
  RideLog? _log;
  File? _logFile;
  StreamSubscription<RideState>? _states;
  RideState _state = const RideState();
  bool _running = false;
  double _thresholdDb = 12;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  Future<void> _start() async {
    await askRidePermissions();
    await askWifiPermission();
    final store = RiderStore();
    final threshold = await store.micSensitivityDb();
    final relay = parseRelayAddress(await store.relayServer()), mode = await store.boxMode();
    final keys = await GroupKeys.derive(widget.group.secret);
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/ride_${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.txt');
    final log = RideLog(file.openWrite(), _clock)
      ..write('start', {
        'rider': widget.riderName,
        'box': widget.box?.ssid ?? 'none',
        'group': widget.group.name,
        'relay': relay ?? 'none',
        'mode': mode.name,
      });
    if (!mounted) {
      await log.close(); // the screen closed while it was starting
      return;
    }
    final engine = RideEngine(
      net: widget.net,
      audio: widget.audio,
      box: widget.box,
      relay: relay,
      mode: mode,
      keys: keys,
      groupName: widget.group.name,
      riderId: widget.riderId,
      riderName: widget.riderName,
      platform: Platform.isIOS ? 0 : 1,
      clock: _clock,
      log: log,
      sensitivityDb: threshold,
    );
    setState(() {
      _thresholdDb = threshold;
      _logFile = file;
      _log = log;
      _engine = engine;
      _running = true;
    });
    _states = engine.states.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    await engine.start();
  }

  Future<void> _stop() async {
    if (!_running) return;
    _running = false;
    unawaited(_states?.cancel());
    await _engine?.stop();
    _log?.write('stop', {});
    await _log?.close();
    if (mounted) setState(() {});
  }

  /// Stops the ride first, so the whole log is on disk.
  Future<void> _shareLog() async {
    await _stop();
    final file = _logFile;
    if (file != null) await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: 'Vroo ride log'));
  }

  void _setThreshold(double db) {
    setState(() => _thresholdDb = db);
    _engine?.sensitivityDb = db;
    unawaited(RiderStore().saveMicSensitivityDb(db));
  }

  @override
  Widget build(BuildContext context) => RideView(
        state: _state,
        groupName: widget.group.name,
        box: widget.box,
        iOS: Platform.isIOS,
        running: _running,
        thresholdDb: _thresholdDb,
        onThreshold: _setThreshold,
        onStop: _stop,
        onShareLog: _logFile == null ? null : _shareLog,
        onOpenSettings: openAppSettings,
        nowMs: _clock.nowMs(),
      );
}

/// The ride screen's layout, for one [RideState].
class RideView extends StatelessWidget {
  const RideView({
    super.key,
    required this.state,
    required this.groupName,
    this.box,
    required this.iOS,
    required this.running,
    required this.thresholdDb,
    required this.onThreshold,
    required this.onStop,
    required this.onShareLog,
    required this.onOpenSettings,
    required this.nowMs,
  });

  final RideState state;
  final String groupName;

  /// The rider's box, or null when riding on mobile data alone.
  final SavedBox? box;
  final bool iOS, running;

  /// How far above the noise speech must be: 6 dB picks up soft speech, 24 dB only loud.
  final double thresholdDb;
  final ValueChanged<double> onThreshold;
  final VoidCallback onStop;
  final VoidCallback? onShareLog;
  final VoidCallback onOpenSettings;

  /// The clock the riders' lastHeardMs are on.
  final int nowMs;

  @override
  Widget build(BuildContext context) {
    final link = state.link, status = link?.status, peers = link?.peers ?? const {}, box = this.box;
    final hint = box == null
        ? null
        : boxHint(state.connection, boxUp: link?.boxUp == true, ssid: box.ssid, password: box.password, iOS: iOS);
    final riders = 1 + peers.length;
    // While riding, back (or an edge swipe while putting the phone away) mustn't end the ride: only Stop does.
    return PopScope(canPop: !running, child: Scaffold(
      appBar: AppBar(
        title: Text('$groupName · $riders ${riders == 1 ? 'rider' : 'riders'}'),
        actions: [TextButton(onPressed: running ? onStop : null, child: const Text('Stop'))],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ...switch (state.problem) {
          RideProblem.micDenied => [
              const Text('Allow the microphone in Settings, then start the ride again.'),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(onPressed: onOpenSettings, child: const Text('Open Settings')),
              ),
              const Divider(),
            ],
          RideProblem.audioFailed => [Text("Audio didn't start: ${state.problemText ?? ''}"), const Divider()],
          null => const <Widget>[],
        },
        if (box != null)
          ListTile(
            title: Text('Box ${box.ssid}: ${link?.boxUp == true ? 'up' : 'down'}'),
            subtitle:
                status == null ? null : Text('${status.phones} phones · drops dup ${status.dropDup} tag ${status.dropTag}'),
          ),
        if (hint != null) ListTile(leading: const Icon(Icons.info_outline), title: Text(hint)),
        for (final line in _clockLines()) ListTile(leading: const Icon(Icons.schedule), title: Text(line)),
        ListTile(title: Text('Paths: ${_pathsLine()}')),
        if (link?.relayNotFound == true)
          const ListTile(
            leading: Icon(Icons.warning_amber),
            title: Text('Relay server not found. Check its name on the home screen.'),
          ),
        if (link?.bridge == true)
          const ListTile(leading: Icon(Icons.link), title: Text('This phone links the box riders to the internet')),
        ListTile(title: Text('Internet: ${switch (link?.internetUp) { true => '✓', false => '✗', null => '…' }}')),
        ListTile(title: Text('Audio: ${_audioLine()}')),
        if (state.audioIssue != null)
          ListTile(leading: const Icon(Icons.warning_amber), title: Text(state.audioIssue!)),
        ListTile(title: Text('You: ${_youLine()}')),
        ListTile(
          title: const Text('Mic sensitivity'),
          subtitle: Slider(
            min: 6,
            max: 24,
            divisions: 18,
            value: 30 - thresholdDb, // right is more sensitive: a lower threshold
            label: thresholdDb <= 9 ? 'high' : (thresholdDb >= 18 ? 'low' : 'medium'),
            onChanged: (v) => onThreshold(30 - v),
          ),
        ),
        const Divider(),
        Text('Riders', style: Theme.of(context).textTheme.titleMedium),
        if (peers.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Nobody heard yet.')),
        for (final p in peers.values)
          ListTile(
            title: Text('${state.names[p.id] ?? p.name}${p.talking ? ' 🎙' : ''}${p.onCall ? ' 📞' : ''}'),
            subtitle: Text(_riderLine(p, state.voice[p.id])),
          ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(onPressed: onShareLog, child: const Text('Share log')),
        ),
      ]),
    ));
  }

  String _audioLine() {
    final rate = state.routeRate > 0 ? ' (${(state.routeRate / 1000).round()} kHz)' : '';
    return switch (state.route) {
      AudioRoute.bluetooth => 'Bluetooth$rate',
      AudioRoute.wired => 'Wired',
      AudioRoute.speaker => 'Loudspeaker',
      AudioRoute.earpiece => 'Earpiece',
      AudioRoute.other => 'Other${state.routeName == null || state.routeName!.isEmpty ? '' : ': ${state.routeName}'}',
      null => '…',
    };
  }

  String _youLine() => state.onCall
      ? 'on a call'
      : state.interrupted
          ? 'paused'
          : state.held
              ? 'waiting for a slot'
              : state.talking
                  ? 'talking'
                  : 'quiet';

  /// Riders cut off by the clock check. When this phone hears nobody and two or more of them agree, it's this phone's
  /// clock that's wrong; with nobody heard and only one, either phone could be.
  List<String> _clockLines() {
    final gaps = state.link?.clockGaps.values.toList() ?? const <ClockGap>[];
    if (gaps.isEmpty) return const [];
    final heard = (state.link?.peers.values ?? const <PeerInfo>[]).any((p) => nowMs - p.lastHeardMs <= 4000);
    final offsets = gaps.map((g) => g.offsetMs);
    if (!heard && gaps.length >= 2 && offsets.reduce(max) - offsets.reduce(min) <= 60000) {
      return [
        "This phone's clock is ${_span(gaps.first.offsetMs)} off, so the group can't hear you. "
            'Set the date and time to automatic.',
      ];
    }
    return [
      for (final g in gaps)
        heard
            ? "${g.name}'s phone clock is ${_span(g.offsetMs)} off, so the group can't hear them. "
                'Ask ${g.name} to set the time to automatic.'
            : "${g.name}'s phone clock and this one are ${_span(g.offsetMs)} apart, so you can't hear each other. "
                'Set both to automatic time.',
    ];
  }

  static String _span(int ms) {
    final minutes = (ms.abs() / 60000).round();
    if (minutes < 90) return '$minutes min';
    final hours = (minutes / 60).round();
    return hours < 48 ? '$hours h' : '${(hours / 24).round()} days';
  }

  /// The box line, and the data path: on, off, or off because the rider picked Box only.
  String _pathsLine() {
    final link = state.link;
    final data = box != null && state.mode == BoxMode.boxOnly
        ? 'data off (Box only)'
        : 'data ${link?.dataPathOn == true ? '✓' : '✗'}';
    return 'box ${link?.boxUp == true ? '✓' : '✗'} · $data';
  }

  String _riderLine(PeerInfo p, VoiceStats? voice) {
    final parts = [
      ?p.lastPath?.name, // box or internet
      'heard ${((nowMs - p.lastHeardMs) / 1000).toStringAsFixed(0)} s ago',
    ];
    if (p.rttMs case final rtt?) parts.add('$rtt ms round trip');
    if (voice != null && voice.played + voice.lost > 0) {
      parts.add('lost ${(100 * voice.lost / (voice.played + voice.lost)).toStringAsFixed(0)}%');
    }
    return parts.join(' · ');
  }
}
