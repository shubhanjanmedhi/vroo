// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import 'package:vroo_audio/vroo_audio.dart';
import 'package:vroo_net/vroo_net.dart';
import 'package:vroo_opus/vroo_opus.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import '../diag/clock.dart';
import '../diag/ride_log.dart';
import '../net/box_connection.dart';
import '../net/group_link.dart';
import '../net/box_setup.dart';
import '../net/relay_address.dart';
import '../voice/talk_slots.dart';
import '../voice/tones.dart';
import '../voice/voice_gate.dart';
import '../voice/voice_pipeline.dart';
import 'alerts.dart';

enum RideProblem { micDenied, audioFailed }

/// What the ride screen shows.
class RideState {
  const RideState({
    this.link,
    this.connection = BoxConnectionState.idle,
    this.route,
    this.routeName,
    this.routeRate = 0,
    this.talking = false,
    this.onCall = false,
    this.held = false,
    this.interrupted = false,
    this.audioIssue,
    this.mode = BoxMode.boxAndData,
    this.names = const {},
    this.voice = const {},
    this.problem,
    this.problemText,
  });

  final GroupLinkState? link;
  final BoxConnectionState connection;
  final AudioRoute? route;
  final String? routeName;

  /// The audio hardware's rate, or 0 where the platform doesn't say (Android's SCO link).
  final int routeRate;

  /// This rider: their voice is going out, they're on a phone call, or they're waiting for a talk slot.
  final bool talking, onCall, held;

  /// Another app (an assistant, an alarm) has the audio for now: the group is paused both ways.
  final bool interrupted;

  /// What's wrong with the audio, in the rider's words, while it lasts: a stalled mic, or the platform's message.
  final String? audioIssue;

  /// The mode a rider with a box picked: whether it also uses mobile data.
  final BoxMode mode;

  /// Display names of the riders heard (GR5).
  final Map<int, String> names;
  final Map<int, VoiceStats> voice;
  final RideProblem? problem;
  final String? problemText;
}

/// One ride (architecture §4.1): keeps the phone on its box if it has one, carries voice both ways over the box and
/// mobile data, plays the spoken alerts, and goes quiet both ways for the rider's phone calls (spec 7.6).
class RideEngine {
  RideEngine({
    required this.net,
    required this.audio,
    this.box,
    this._relay,
    this._mode = BoxMode.boxAndData,
    required this.keys,
    required this.groupName,
    required this.riderId,
    required this.riderName,
    required this.platform,
    required this.clock,
    required this.log,
    double sensitivityDb = 12,
    this.newEncoder = OpusEncoder.new,
    this.newDecoder = OpusDecoder.new,
  }) : _gate = VoiceGate(thresholdDb: sensitivityDb);

  final VrooNet net;
  final VrooAudio audio;
  /// The rider's box, or null to ride on mobile data alone.
  final SavedBox? box;
  final RelayAddress? _relay;
  final BoxMode _mode;
  final GroupKeys keys;
  final String groupName, riderName;
  final int riderId;

  /// 0 iOS, 1 Android.
  final int platform;
  final Clock clock;
  final RideLog log;
  final OpusEncoder Function() newEncoder;
  final OpusDecoder Function() newDecoder;
  final VoiceGate _gate;

  late final _connection = switch (box) {
    final b? => BoxConnection(net: net, ssid: b.ssid, password: b.password),
    null => null,
  };
  late final _link = GroupLink(
      net: net,
      keys: keys,
      myId: riderId,
      myName: riderName,
      platform: platform,
      clock: clock,
      log: log,
      boxSetUp: box != null,
      relay: _relay,
      mode: _mode);
  final _alerts = Alerts();
  final _speech = <String, Int16List>{}; // each text is synthesized once
  final _states = StreamController<RideState>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  VoicePipeline? _pipeline;
  Timer? _statsTimer;
  Future<void> _alertQueue = Future.value(); // one alert after another, in order
  GroupLinkState? _linkState;
  CallState _call = CallState.idle;
  bool _interrupted = false;
  AudioRoute? _route;
  String? _routeName;
  int _routeRate = 0;
  RideProblem? _problem;
  String? _problemText;
  String? _audioIssue;
  Timer? _micWatch;
  int _micSeen = 0, _micQuietSinceMs = 0;
  int? _lastMicRestartMs;

  Stream<RideState> get states => _states.stream;

  /// The ride screen's mic sensitivity: how far above the noise speech must be.
  set sensitivityDb(double db) => _gate.thresholdDb = db;

  /// The relay for the mobile-data path. A change takes effect at once, with no restart.
  set relay(RelayAddress? r) {
    _link.relay = r;
    log.write('path', {'relay': r ?? 'none'});
    _emit();
  }

  /// Box + data or Box only. A change takes effect at once, with no restart.
  set mode(BoxMode m) {
    _link.mode = m;
    log.write('path', {'mode': m.name});
    _emit();
  }

  Future<StartResult>? _starting;

  Future<StartResult> start() => _starting = _start();

  Future<StartResult> _start() async {
    _subscriptions.add(audio.events.listen(_onAudioEvent)); // before start, so the first route isn't missed
    final result = await audio.start(notificationText: 'Riding with $groupName');
    log.write('audio', {'start': result.name});
    if (result != StartResult.started) {
      _problem = result == StartResult.micDenied ? RideProblem.micDenied : RideProblem.audioFailed;
      _problemText = result == StartResult.micDenied ? 'The microphone is off for Vroo.' : "Audio didn't start.";
      await _cancelSubscriptions();
      _emit();
      return result;
    }
    final pipeline = _pipeline = VoicePipeline(
      audio: audio,
      encoder: newEncoder(),
      newDecoder: newDecoder,
      send: _link.sendVoice,
      clock: clock,
      gate: _gate,
      slots: TalkSlots(),
      log: log,
    );
    _subscriptions
      ..add(_link.voices.listen(pipeline.onVoice))
      ..add(_link.states.listen(_onLinkState));
    _connection?.state.addListener(_emit);
    unawaited(_connection?.start());
    unawaited(_link.start());
    pipeline.start();
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) => _logStats());
    _micQuietSinceMs = clock.nowMs();
    _micWatch = Timer.periodic(const Duration(seconds: 1), (_) => _watchMic());
    _emit();
    return result;
  }

  Future<void> stop() async {
    await _starting; // a stop while the start is under way waits for it, then undoes it
    _statsTimer?.cancel();
    _micWatch?.cancel();
    _statsTimer = _micWatch = null;
    await _cancelSubscriptions();
    final pipeline = _pipeline;
    _pipeline = null;
    if (pipeline == null) return; // the start never got going
    _connection?.state.removeListener(_emit);
    await pipeline.stop();
    await _link.stop();
    await _connection?.stop();
    await audio.stop();
  }

  Future<void> _cancelSubscriptions() async {
    for (final s in _subscriptions) {
      unawaited(s.cancel()); // not awaited: an awaited cancel stalls fake time in tests
    }
    _subscriptions.clear();
  }

  void _onAudioEvent(AudioEvent e) {
    switch (e) {
      case CallStateChanged(:final state):
        _call = state;
        log.write('call', {'state': state.name});
      case InterruptionChanged(:final began):
        _interrupted = began;
        log.write('audio', {'interruption': began ? 'began' : 'ended'});
      case RouteChanged(:final output, :final name, :final hardwareRate):
        _route = output;
        _routeName = name;
        _routeRate = hardwareRate;
        log.write('audio', {'route': output.name, 'name': name, 'rate': hardwareRate});
      case AudioFailed(:final message):
        log.write('error', {'audio': message});
        _audioIssue = message;
    }
    final onCall = _call != CallState.idle;
    _pipeline?.muted = onCall || _interrupted; // both ways, from the first ring until hang-up (PC2)
    _link.onCall = onCall;
    _emit();
  }

  void _onLinkState(GroupLinkState s) {
    _linkState = s;
    final pipeline = _pipeline;
    if (pipeline == null) return;
    _link.talking = pipeline.talking;
    final alerts = _alerts.update(
      peers: s.peers,
      names: displayNames(s.peers, myId: riderId, myName: riderName),
      boxUp: box == null || s.boxUp, // "Your box is disconnected" only for a rider with a box (spec 7.5)
      myCall: _call != CallState.idle,
      clockGap: s.clockGaps.isNotEmpty,
      nowMs: clock.nowMs(),
    );
    for (final alert in alerts) {
      _alertQueue = _alertQueue.then((_) => _play(alert));
    }
    _emit();
  }

  Future<void> _play(Alert alert) async {
    switch (alert) {
      case BackTone():
        _pipeline?.say(backTone());
      case Say(:final text):
        try {
          final speech = _speech[text] ??= await audio.synthesize(text);
          _pipeline?.say(speech);
        } catch (_) {
          log.write('audio', {'speech': 'failed'}); // the message is skipped; the ride goes on
        }
    }
  }

  static const _micStalled = 'The microphone stopped. Restarting the audio…';

  /// Mic frames are the pipeline's clock: if they stop outside a call or an interruption, the ride would go silent
  /// both ways with nothing said. After 2 s, say so on screen and restart the audio, at most once every 10 s.
  void _watchMic() {
    final pipeline = _pipeline;
    if (pipeline == null) return;
    final now = clock.nowMs();
    if (pipeline.micFrames != _micSeen || pipeline.muted) {
      _micSeen = pipeline.micFrames;
      _micQuietSinceMs = now;
      if (_audioIssue == _micStalled && !pipeline.muted) {
        _audioIssue = null;
        log.write('audio', {'mic': 'back'});
        _emit();
      }
      return;
    }
    if (now - _micQuietSinceMs < 2000) return;
    if (_audioIssue != _micStalled) {
      _audioIssue = _micStalled;
      log.write('audio', {'mic': 'stalled'});
      _emit();
    }
    final last = _lastMicRestartMs;
    if (last == null || now - last >= 10000) {
      _lastMicRestartMs = now;
      log.write('audio', {'restart': 'mic'});
      unawaited(audio.restart());
    }
  }

  void _logStats() {
    final pipeline = _pipeline;
    if (pipeline == null) return;
    final peers = _linkState?.peers ?? const {};
    final names = displayNames(peers, myId: riderId, myName: riderName);
    for (final MapEntry(key: src, value: v) in pipeline.stats.entries) {
      log.write('stats', {
        'peer': names[src] ?? src.toRadixString(16),
        'rx': v.played,
        'fec': v.recovered,
        'plc': v.concealed,
        'late': v.late,
        'skip': v.skipped,
        'lost': v.lost,
        'depth': v.depth,
        'rtt': peers[src]?.rttMs ?? '',
      });
    }
    log.write('stats', {'peer': 'me', 'tx': pipeline.sentFrames, 'held': pipeline.heldFrames});
  }

  void _emit() {
    final s = _linkState, pipeline = _pipeline;
    _states.add(RideState(
      link: s,
      connection: _connection?.state.value ?? BoxConnectionState.idle,
      route: _route,
      routeName: _routeName,
      routeRate: _routeRate,
      talking: pipeline?.talking ?? false,
      onCall: _call != CallState.idle,
      held: pipeline?.held ?? false,
      interrupted: _interrupted,
      audioIssue: _audioIssue,
      mode: _link.mode,
      names: s == null ? const {} : displayNames(s.peers, myId: riderId, myName: riderName),
      voice: pipeline?.stats ?? const {},
      problem: _problem,
      problemText: _problemText,
    ));
  }
}
