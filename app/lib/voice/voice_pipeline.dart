// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:vroo_audio/vroo_audio.dart';
import 'package:vroo_opus/vroo_opus.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import '../diag/clock.dart';
import '../diag/ride_log.dart';
import '../net/group_link.dart';
import 'jitter_buffer.dart';
import 'mixer.dart';
import 'talk_slots.dart';
import 'tones.dart';
import 'voice_gate.dart';

/// One sender's playback, for the stats line.
class VoiceStats {
  const VoiceStats({
    required this.played,
    required this.recovered,
    required this.concealed,
    required this.late,
    required this.skipped,
    required this.depth,
    required this.lost,
  });

  final int played, recovered, concealed, late, skipped, depth;

  /// Frames missing inside talk spurts (see [JitterBuffer.lost]).
  final int lost;
}

const _quietSenderMs = 10000;

class _Sender {
  _Sender(this.session, this.decoder, this.lastHeardMs);

  final int session;
  final OpusDecoder decoder;
  final buffer = JitterBuffer();
  int lastHeardMs;
}

/// Voice both ways (architecture §4.2). Each mic frame drives one step: the rider's voice goes through the gate, the
/// talk slots and the encoder to [send], then one 20 ms frame of everyone else, mixed with any alert audio, goes to
/// the speaker. The mic is the clock, so playback keeps pace with the audio hardware.
class VoicePipeline {
  VoicePipeline({
    required this.audio,
    required this.encoder,
    required this.newDecoder,
    required this.send,
    required this.clock,
    required this.gate,
    required this.slots,
    required this.log,
    this.maxVoices = 4,
  });

  final VrooAudio audio;
  final OpusEncoder encoder;
  final OpusDecoder Function() newDecoder;
  final Future<void> Function(VoiceFrame) send;
  final Clock clock;
  final VoiceGate gate;
  final TalkSlots slots;
  final RideLog log;
  final int maxVoices;

  final _senders = <int, _Sender>{}; // in the order they were first heard
  final _alerts = Queue<Int16List>(); // alert audio, a frame at a time
  StreamSubscription<Int16List>? _mic;
  int _frameNo = 0;
  bool _muted = false, _talking = false, _held = false;
  int sentFrames = 0, heldFrames = 0;

  /// Mic frames received, muted or not: the ride's watchdog checks that this keeps growing.
  int micFrames = 0;

  /// The rider's voice is going out.
  bool get talking => _talking;

  /// The last frame the rider spoke was held for a talk slot.
  bool get held => _held;

  /// During calls and interruptions: nothing is sent, silence is played, and what's buffered is dropped.
  bool get muted => _muted;
  set muted(bool value) {
    if (value == _muted) return;
    _muted = value;
    if (!value) return;
    _closeSenders();
    _alerts.clear();
    _talking = _held = false;
  }

  Map<int, VoiceStats> get stats => {
        for (final MapEntry(key: src, value: s) in _senders.entries)
          src: VoiceStats(
            played: s.buffer.played,
            recovered: s.buffer.recovered,
            concealed: s.buffer.concealed,
            late: s.buffer.late,
            skipped: s.buffer.skipped,
            depth: s.buffer.depth,
            lost: s.buffer.lost,
          ),
      };

  void start() => _mic = audio.micFrames.listen(_onMic);

  /// Closes the encoder and every decoder.
  Future<void> stop() async {
    unawaited(_mic?.cancel());
    _mic = null;
    _closeSenders();
    encoder.close();
  }

  /// A voice frame from another rider.
  void onVoice(HeardVoice v) {
    if (_muted) return;
    final now = clock.nowMs();
    slots.heard(v.src, now);
    var sender = _senders[v.src];
    if (sender == null || sender.session != v.session) {
      sender?.decoder.close(); // a new session: that rider's app restarted, so the frame numbers start again
      _senders.remove(v.src);
      sender = _senders[v.src] = _Sender(v.session, newDecoder(), now);
    }
    sender.lastHeardMs = now;
    sender.buffer.put(v.frame.frameNo, v.frame.opus);
  }

  /// Queues alert audio (speech or a tone, 16 kHz) to play over the voices.
  void say(Int16List pcm) {
    for (var i = 0; i < pcm.length; i += audioFrameSamples) {
      _alerts.add(Int16List(audioFrameSamples)..setRange(0, min(audioFrameSamples, pcm.length - i), pcm, i));
    }
  }

  void _onMic(Int16List frame) {
    micFrames++;
    final now = clock.nowMs(), frameNo = _frameNo++;
    if (_muted) {
      audio.play(Int16List(audioFrameSamples));
      return;
    }
    _speak(frame, frameNo, now);
    audio.play(mix([..._hearOneFrame(now), if (_alerts.isNotEmpty) _alerts.removeFirst()]));
  }

  void _speak(Int16List frame, int frameNo, int now) {
    final out = gate.push(frame); // pre-roll frames come first, numbered just before this one
    var sent = false;
    for (var k = 0; k < out.length; k++) {
      switch (slots.decide(now)) {
        case SlotDecision.send:
          unawaited(send(VoiceFrame(frameNo: frameNo - (out.length - 1 - k), opus: encoder.encode(out[k]))));
          sentFrames++;
          sent = true;
          _held = false;
        case SlotDecision.hold:
          heldFrames++;
          _held = true;
        case SlotDecision.holdWithBusyTone:
          heldFrames++;
          _held = true;
          say(busyTone());
          log.write('slot', {'state': 'busy'});
      }
    }
    _talking = sent;
  }

  /// One frame from each of the first [maxVoices] senders with something to play; the rest are kept current.
  List<Int16List> _hearOneFrame(int now) {
    final voices = <Int16List>[];
    for (final MapEntry(key: src, value: s) in _senders.entries.toList()) {
      if (now - s.lastHeardMs > _quietSenderMs) {
        s.decoder.close();
        _senders.remove(src);
        continue;
      }
      final playout = s.buffer.next();
      if (playout == null || voices.length >= maxVoices) continue;
      voices.add(_decode(s.decoder, playout));
    }
    return voices;
  }

  /// A frame libopus can't read is concealed, so nothing from the network can throw here.
  Int16List _decode(OpusDecoder decoder, Playout playout) {
    try {
      return switch (playout) {
        PlayFrame(:final opus) => decoder.decode(opus),
        RecoverFrame(:final nextOpus) => decoder.decode(nextOpus, fec: true),
        ConcealFrame() => decoder.decode(null),
      };
    } on Exception {
      return decoder.decode(null);
    }
  }

  void _closeSenders() {
    for (final s in _senders.values) {
      s.decoder.close();
    }
    _senders.clear();
  }
}
