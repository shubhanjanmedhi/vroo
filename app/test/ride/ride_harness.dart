// SPDX-License-Identifier: GPL-3.0-or-later
//
// Two phones running whole RideEngines on one FakeBox, with fake audio and the fake codec. Create the rig inside
// fakeAsync, so the phones' clocks and timers follow fake time.
import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:vroo/diag/clock.dart';
import 'package:vroo/diag/ride_log.dart';
import 'package:vroo/net/box_setup.dart';
import 'package:vroo/net/group_link.dart';
import 'package:vroo/net/relay_address.dart';
import 'package:vroo/ride/ride_engine.dart';
import 'package:vroo_audio/vroo_audio.dart';
import 'package:vroo_net/vroo_net.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import '../fake_box.dart';
import '../fake_codec.dart';

Int16List steady(int level) => Int16List(320)..fillRange(0, 320, level);

/// What a talking rider's voice plays as on the other phones (the fake codec carries the level through).
const voiceLevel = 8000;

/// The fake-time clock, with its wall clock set [skew] off, as on a phone whose time was set by hand.
class _SkewedClock extends SystemClock {
  _SkewedClock(this.skew);

  final Duration skew;

  @override
  DateTime wallNow() => super.wallNow().add(skew);
}

class RidePhone {
  /// A phone with the test box set up unless [withBox] is false, the [relay] if given, [mode], and its wall clock
  /// [clockSkew] off.
  RidePhone(this.net, GroupKeys keys, this.name, this.id,
      {bool withBox = true, RelayAddress? relay, BoxMode mode = BoxMode.boxAndData, Duration clockSkew = Duration.zero})
      : clock = _SkewedClock(clockSkew) {
    engine = RideEngine(
      net: net,
      audio: audio,
      box: withBox ? const SavedBox(boxId: 0xA1B2C3, ssid: 'Vroo-A1B2C3', password: 'abcd-efgh-jkmn-pqrs') : null,
      relay: relay,
      mode: mode,
      keys: keys,
      groupName: 'Sunday ride',
      riderId: id,
      riderName: name,
      platform: 1,
      clock: clock,
      log: RideLog(_log, clock),
      newEncoder: FakeEncoder.new,
      newDecoder: () {
        final d = FakeDecoder();
        decoders.add(d);
        return d;
      },
    );
    engine.states.listen((s) => state = s);
  }

  final FakeVrooNet net;
  final String name;
  final int id;
  final audio = FakeVrooAudio();
  final SystemClock clock;
  final _log = StringBuffer();
  final decoders = <FakeDecoder>[];
  late final RideEngine engine;
  RideState? state;
  Int16List _micFrame = steady(10);
  Timer? _mic;

  String get logText => _log.toString();

  /// The mic delivers a frame every 20 ms, quiet until [talk].
  void startMic() => _mic ??= Timer.periodic(const Duration(milliseconds: 20), (_) => audio.emitMic(_micFrame));

  void stopMic() {
    _mic?.cancel();
    _mic = null;
  }

  void talk() => _micFrame = steady(voiceLevel);

  void quiet() => _micFrame = steady(10);

  /// Whether anything played from frame [from] on reached [level], as another rider's voice does.
  bool heardVoiceSince(int from) => audio.played.skip(from).any((f) => f.any((s) => s >= voiceLevel));
}

class RideRig {
  RideRig({bool duplicate = false}) : box = FakeBox(duplicate: duplicate), keys = Harness().keys;

  final FakeBox box;
  final relay = FakeRelay();
  final GroupKeys keys;
  late final a = RidePhone(box.join(), keys, 'A', 0xA);
  late final b = RidePhone(box.join(), keys, 'B', 0xB);

  /// A phone with no box, on the relay.
  RidePhone relayPhone(String name, int id) =>
      RidePhone(relay.join(), keys, name, id, withBox: false, relay: FakeRelay.address);

  /// A phone on the box and the relay.
  RidePhone bothPhone(String name, int id, {BoxMode mode = BoxMode.boxAndData}) =>
      RidePhone(box.join(relay: relay), keys, name, id, relay: FakeRelay.address, mode: mode);

  /// How many packets [phone] has sent to the relay.
  int relaySends(RidePhone phone) => phone.net.sentToInternet.where((x) => x.$2 == relayPort).length;

  /// Starts both rides with their mics on and the box reporting every second, then lets 1 s pass.
  void startBoth(FakeAsync fa) {
    a.engine.start();
    b.engine.start();
    a.startMic();
    b.startMic();
    box.sendStatus();
    Timer.periodic(const Duration(seconds: 1), (_) => box.sendStatus());
    fa.elapse(const Duration(seconds: 1));
  }

  /// The VOICE packets [phone] has sent to the box so far (the type is in the plain header).
  int voiceSent(RidePhone phone) => phone.net.sentToBox
      .where((d) => d.$1 == boxDataPort)
      .where((d) => decodeHeader(unwrapEnvelope(d.$2)!.packet)?.type == PacketType.voice)
      .length;
}
