// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:vroo_net/vroo_net.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import '../diag/clock.dart';
import '../diag/ride_log.dart';
import 'peer.dart';
import 'relay_address.dart';

const _beatEvery = Duration(seconds: 1);
const _probeEvery = Duration(seconds: 5);
const _statusTimeout = Duration(seconds: 3);
const _peerLostMs = 4000; // four heartbeat intervals of silence (architecture §5.4)

/// A rider with a box picks whether it also uses mobile data (spec G10, CO5).
enum BoxMode { boxAndData, boxOnly }

class GroupLinkState {
  const GroupLinkState({
    required this.boxUp,
    this.status,
    this.internetUp,
    required this.peers,
    this.dataPathOn = false,
    this.bridge = false,
    this.relayNotFound = false,
    this.clockGaps = const {},
  });

  /// Whether the box sent a BOX_STATUS in the last 3 s.
  final bool boxUp;
  final BoxStatus? status;

  /// The last internet probe's answer; null before the first one finishes.
  final bool? internetUp;

  /// The riders heard on any path, by rider ID. Never this phone.
  final Map<int, PeerInfo> peers;

  /// Whether this phone sends over mobile data to the relay now (architecture §4.3).
  final bool dataPathOn;

  /// Whether this phone is its box riders' bridge to the internet (§6.4).
  final bool bridge;

  /// The internet is up, but the relay's name wasn't found, so nothing goes over mobile data.
  final bool relayNotFound;

  /// By rider ID, riders whose heartbeats were refused in the last 4 s because their clock and this phone's are too
  /// far apart, and who aren't heard otherwise.
  final Map<int, ClockGap> clockGaps;
}

/// A rider cut off by the clock check (architecture §5.2). Their heartbeat passed the seal, so this is their own.
class ClockGap {
  const ClockGap(this.name, this.offsetMs);

  final String name;

  /// Their clock minus this phone's.
  final int offsetMs;
}

/// A voice frame from another rider, after decryption and dedupe.
class HeardVoice {
  const HeardVoice(this.src, this.session, this.frame);

  final int src, session;
  final VoiceFrame frame;
}

/// This phone's link to the group (architecture §4.3): every packet goes on each path that's on, through the box and
/// over mobile data to the relay, and the first copy to arrive wins. It sends a heartbeat every second, carries
/// voice, heartbeats and echoes from the others, watches the box's health, and probes the internet every 5 s.
class GroupLink {
  GroupLink({
    required this.net,
    required this.keys,
    required this.myId,
    required this.myName,
    required this.platform,
    required this.clock,
    required this.log,
    required this.boxSetUp,
    this._relay,
    this.mode = BoxMode.boxAndData,
    Random? random,
  })  : _random = random ?? Random.secure(),
        _sealer = Sealer(keys);

  /// Whether this rider has a box set up. (The heartbeat's hasBox says whether it answers.)
  final bool boxSetUp;

  /// The mode a rider with a box picked; it can change mid-ride.
  BoxMode mode;

  RelayAddress? _relay;
  late InternetAddress? _relayIp = _addressOf(_relay); // an IP address at once; a name after a successful probe
  bool _dataPathWas = false;
  bool _bridge = false;

  /// The relay server for the mobile-data path, or null for none. It can change mid-ride.
  RelayAddress? get relay => _relay;
  set relay(RelayAddress? r) {
    if (r == _relay) return;
    _relay = r;
    _relayIp = _addressOf(r);
  }

  static InternetAddress? _addressOf(RelayAddress? r) => r == null ? null : InternetAddress.tryParse(r.host);

  /// Whether packets go to the relay now: a relay is set and found, and the rider has no box (the relay is their only
  /// path, so they send whatever the probe says), or picked Box + data and the internet is up.
  bool get dataPathOn =>
      _relay != null && _relayIp != null && (!boxSetUp || _internetUp == true && mode == BoxMode.boxAndData);

  final VrooNet net;
  final GroupKeys keys;
  final int myId;
  final String myName;

  /// 0 iOS, 1 Android.
  final int platform;
  final Clock clock;
  final RideLog log;
  final Random _random;
  final Sealer _sealer;

  final _states = StreamController<GroupLinkState>.broadcast();
  final _voices = StreamController<HeardVoice>.broadcast();
  final _replay = ReplayGuard();
  final _peers = <int, PeerInfo>{};
  final _beatsHeard = <int, int>{}; // per rider, for choosing which heartbeats to echo
  final _clockGaps = <int, (ClockGap, int)>{}; // per rider: the gap, and when it was last seen
  final _lastDropLogMs = <String, int>{};
  StreamSubscription<NetEvent>? _events;
  Timer? _beatTimer, _probeTimer, _statusWatchdog;
  int _session = 0, _seq = 0;
  bool _boxUp = false;
  BoxStatus? _status;
  bool? _internetUp;
  int _probeFails = 0; // in a row
  int? _relayHeardMs; // when a datagram last came from the relay

  /// What this phone's heartbeat says about its rider: talking now, and on a phone call.
  bool talking = false, onCall = false;

  /// After every change, and every second.
  Stream<GroupLinkState> get states => _states.stream;

  /// The other riders' voice. Never this phone's own.
  Stream<HeardVoice> get voices => _voices.stream;

  /// Sends one voice frame, sealed with the same sequence counter as every other packet.
  Future<void> sendVoice(VoiceFrame frame) => _send(PacketType.voice, encodeVoice(frame));

  int get session => _session;

  bool get _running => _events != null;

  Future<void> start() async {
    _session = _random.nextInt(1 << 32);
    _seq = 0;
    _events = net.events.listen(_onEvent);
    _beatTimer = Timer.periodic(_beatEvery, (_) => _tick());
    _probeTimer = Timer.periodic(_probeEvery, (_) => _probe());
    _tick();
    unawaited(_probe());
  }

  Future<void> stop() async {
    _beatTimer?.cancel();
    _probeTimer?.cancel();
    _statusWatchdog?.cancel();
    _beatTimer = _probeTimer = _statusWatchdog = null;
    unawaited(_events?.cancel()); // not awaited: nothing depends on it, and an awaited cancel stalls fake time
    _events = null;
  }

  void _tick() {
    unawaited(_send(
      PacketType.beat,
      encodeBeat(Beat(
        platform: platform,
        flags: (_boxUp ? BeatFlags.hasBox : 0) |
            (dataPathOn ? BeatFlags.hasInternet : 0) |
            (talking ? BeatFlags.talking : 0) |
            (onCall ? BeatFlags.onCall : 0),
        battery: 255, // unknown
        sentAtMs: _wallMs(), // the wall clock, so the others can tell a replayed heartbeat (architecture §5.2)
        btNeighbors: const [],
        name: myName,
      )),
    ));
    final on = dataPathOn;
    if (on != _dataPathWas) {
      _dataPathWas = on;
      log.write('path', {'data': on ? 'on' : 'off'});
    }
    _electBridge();
    _emit();
  }

  /// This phone bridges its box riders to the internet (architecture §6.4) when its data path and box are both up,
  /// and no rider heard through the box in the last 4 heartbeat intervals has both too with a lower rider ID.
  void _electBridge() {
    final now = clock.nowMs();
    final lower = _peers.values.any((p) => p.id < myId && p.hasInternet && p.hasBox && _local(p, now));
    final bridge = dataPathOn && _boxUp && !lower;
    if (bridge == _bridge) return;
    _bridge = bridge;
    log.write('bridge', {'state': bridge ? 'on' : 'off'});
  }

  /// A rider is local when their own heartbeat says their box answers and their packets came through the box in the
  /// last 4 heartbeat intervals. A rider with no box is never local, though a bridge may have brought their packets
  /// into the box: so after a bridge hands over, the new one brings such riders in at once.
  bool _local(PeerInfo p, int now) =>
      p.hasBox && switch (p.lastBoxMs) { final t? => now - t <= _peerLostMs, null => false };

  /// As the bridge: uploads what box riders without internet send, and brings into the box, with a fresh ttl, what
  /// riders not heard through the box send over the internet. Other phones upload only their own packets.
  void _bridgeOn(Uint8List datagram, int src, RidePath path) {
    final peer = _peers[src], relay = _relay, ip = _relayIp;
    if (!_bridge || !_running || peer == null || relay == null || ip == null) return;
    if (path == RidePath.box && !peer.hasInternet) {
      unawaited(net.sendToInternet(datagram, ip, relay.port));
    } else if (path == RidePath.internet && !_local(peer, clock.nowMs())) {
      unawaited(net.sendToBox(Uint8List.fromList(datagram)..[groupTagSize + 2] = originTtl, port: boxDataPort));
    }
  }

  /// Seals with the next seq (shared by every packet type) and sends it on every path that's on.
  Future<void> _send(int type, Uint8List payload) async {
    final header =
        PacketHeader(version: protocolVersion, type: type, ttl: originTtl, src: myId, session: _session, seq: _seq++);
    final envelope = wrapEnvelope(keys.tag, await _sealer.seal(header, payload));
    if (!_running) return;
    if (boxSetUp) unawaited(net.sendToBox(envelope, port: boxDataPort));
    final relay = _relay, ip = _relayIp;
    if (dataPathOn && relay != null && ip != null) unawaited(net.sendToInternet(envelope, ip, relay.port));
  }

  void _onEvent(NetEvent e) {
    switch (e) {
      case BoxDatagram(fromPort: boxControlPort, :final data):
        final status = decodeBoxStatus(data);
        if (status != null) _onStatus(status);
      case BoxDatagram(fromPort: boxDataPort, :final data):
        unawaited(_onPacket(data, RidePath.box));
      case InternetDatagram(:final from, :final fromPort, :final data)
          when from == _relayIp && fromPort == _relay?.port:
        _relayHeardMs = clock.nowMs();
        unawaited(_onPacket(data, RidePath.internet));
      default:
        break;
    }
  }

  void _onStatus(BoxStatus status) {
    _status = status;
    _statusWatchdog?.cancel();
    _statusWatchdog = Timer(_statusTimeout, () => _setBoxUp(false));
    _setBoxUp(true);
  }

  void _setBoxUp(bool up) {
    if (up != _boxUp) {
      _boxUp = up;
      log.write('box', {'state': up ? 'up' : 'down'});
    }
    _emit();
  }

  Future<void> _onPacket(Uint8List datagram, RidePath path) async {
    final envelope = unwrapEnvelope(datagram);
    final header = envelope == null ? null : decodeHeader(envelope.packet);
    if (envelope == null || header == null) {
      _drop('short');
      return;
    }
    if (!listEquals(envelope.groupTag, keys.tag)) {
      _drop('auth');
      return;
    }
    if (header.src == myId) return; // our own packet, back through another box's relay
    final opened = await _sealer.open(envelope.packet);
    if (opened == null) {
      _drop('auth');
      return;
    }
    final h = opened.header;
    if (!_running) return;
    final beat = h.type == PacketType.beat ? decodeBeat(opened.payload) : null;
    if (h.type == PacketType.beat && beat == null) return;
    switch (_replay.check(h, nowMs: clock.nowMs(), wallMs: _wallMs(), beatSentAtMs: beat?.sentAtMs)) {
      case ReplayVerdict.accepted:
        break;
      case ReplayVerdict.duplicate:
        _heardOn(h.src, path); // a copy by another path still shows the rider can be reached on it
        return;
      case ReplayVerdict.staleBeat:
        _drop('stale'); // the sender's clock is far off, or this is an old heartbeat played again
        final offsetMs = ((beat!.sentAtMs - _wallMs()) & 0xFFFFFFFF).toSigned(32); // their clock minus ours
        _clockGaps[h.src] = (ClockGap(beat.name, offsetMs), clock.nowMs());
        _emit();
        return;
      case ReplayVerdict.noRecentBeat:
        _drop('nobeat');
        return;
      case ReplayVerdict.tooOld:
        return; // a replay
    }
    switch (h.type) {
      case PacketType.beat:
        _onBeat(h, beat!);
      case PacketType.echo:
        final echo = decodeEcho(opened.payload);
        if (echo != null && echo.target == myId) _onEcho(h.src, echo);
      case PacketType.voice:
        final voice = decodeVoice(opened.payload);
        if (voice == null) return;
        _peers[h.src]?.lastHeardMs = clock.nowMs(); // talking shows the rider is still here
        _voices.add(HeardVoice(h.src, h.session, voice));
    }
    _heardOn(h.src, path); // after handling, so a rider's first heartbeat counts too
    _peers[h.src]?.lastPath = path;
    _bridgeOn(datagram, h.src, path);
  }

  /// Notes that [src] is reachable on [path]: any authentic copy counts, the first or a later one (the bridge, §6.4).
  void _heardOn(int src, RidePath path) {
    final peer = _peers[src];
    if (peer == null) return;
    final now = clock.nowMs();
    if (path == RidePath.box) {
      peer.lastBoxMs = now;
    } else {
      peer.lastInternetMs = now;
    }
  }

  /// Logs a dropped datagram, at most once a second for each reason so the log isn't flooded.
  void _drop(String reason) {
    final now = clock.nowMs();
    final last = _lastDropLogMs[reason];
    if (last != null && now - last < 1000) return;
    _lastDropLogMs[reason] = now;
    log.write('drop', {'reason': reason});
  }

  void _onBeat(PacketHeader h, Beat beat) {
    final now = clock.nowMs();
    final known = _peers[h.src];
    final peer = known ?? (_peers[h.src] = PeerInfo(id: h.src, name: beat.name, lastHeardMs: now));
    if (known != null && now - known.lastHeardMs > _peerLostMs) log.write('peer_back', {'peer': beat.name});
    peer
      ..name = beat.name
      ..lastHeardMs = now
      ..talking = beat.flags & BeatFlags.talking != 0
      ..onCall = beat.flags & BeatFlags.onCall != 0
      ..hasBox = beat.flags & BeatFlags.hasBox != 0
      ..hasInternet = beat.flags & BeatFlags.hasInternet != 0;
    // Echo the 1st and every 5th heartbeat from each rider, counted here: voice packets share the sender's sequence
    // counter, so its heartbeats' seq values can't pick them.
    final heard = _beatsHeard[h.src] = (_beatsHeard[h.src] ?? 0) + 1;
    if (heard % 5 == 1) {
      unawaited(_send(PacketType.echo, encodeEcho(Echo(target: h.src, sentAtMs: beat.sentAtMs))));
    }
    _emit();
  }

  void _onEcho(int from, Echo echo) {
    final peer = _peers[from];
    if (peer == null) return;
    peer
      ..lastHeardMs = clock.nowMs()
      ..rttMs = (_wallMs() - echo.sentAtMs) & 0xFFFFFFFF; // sentAt is our own heartbeat's wall clock, low 32 bits
    _emit();
  }

  int _wallMs() => clock.wallNow().millisecondsSinceEpoch;

  /// The internet is up while the probe answers or the relay is heard; one lost probe isn't an outage, so it goes down
  /// only after two failures in a row (CO1).
  Future<void> _probe() async {
    final answered = await probeInternet(net);
    if (!_running) return;
    final relayHeard = switch (_relayHeardMs) { final t? => clock.nowMs() - t <= 3000, null => false };
    _probeFails = answered || relayHeard ? 0 : _probeFails + 1;
    final up = _probeFails == 0 || _internetUp == true && _probeFails < 2;
    if (up && _relayIp == null) await _resolveRelay();
    if (up == _internetUp) return;
    _internetUp = up;
    log.write('path', {'internet': up ? 'up' : 'down'});
    _emit();
  }

  /// Finds a relay name's IPv4 address over the internet path, once the internet is up; it's tried again after the
  /// next probe if it isn't found.
  Future<void> _resolveRelay() async {
    final relay = _relay;
    if (relay == null) return;
    final ip = await lookupOverInternet(net, relay.host);
    if (ip == null || relay != _relay) return; // not found, or changed while it was being looked up
    _relayIp = ip;
    log.write('path', {'relay': '${ip.address}:${relay.port}'});
  }

  void _emit() {
    final now = clock.nowMs();
    bool heard(int id) => switch (_peers[id]) { final p? => now - p.lastHeardMs <= _peerLostMs, null => false };
    _states.add(GroupLinkState(
      boxUp: _boxUp,
      status: _status,
      internetUp: _internetUp,
      peers: Map.unmodifiable(_peers),
      dataPathOn: dataPathOn,
      bridge: _bridge,
      relayNotFound: _relay != null && _relayIp == null && _internetUp == true,
      clockGaps: {
        // A rider who is heard isn't cut off: a refused heartbeat of theirs is an old one played again.
        for (final MapEntry(key: id, value: (gap, at)) in _clockGaps.entries)
          if (now - at <= _peerLostMs && !heard(id)) id: gap,
      },
    ));
  }
}
