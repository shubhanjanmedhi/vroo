// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/net/box_connection.dart';
import 'package:vroo/net/group_link.dart';
import 'package:vroo/net/peer.dart';
import 'package:vroo/ride/ride_engine.dart';
import 'package:vroo_audio/vroo_audio.dart';

import '../fake_box.dart';
import 'ride_harness.dart';

void main() {
  setUpAll(Harness.prepare);

  test('riders with no box talk over the relay', () => fakeAsync((fa) {
        final r = RideRig();
        final a = r.relayPhone('A', 0xA), b = r.relayPhone('B', 0xB);
        a.engine.start();
        b.engine.start();
        a.startMic();
        b.startMic();
        fa.elapse(const Duration(seconds: 2));
        a.talk();
        fa.elapse(const Duration(seconds: 1));
        expect(b.heardVoiceSince(0), isTrue);
        expect(b.state!.link!.peers[0xA]!.lastPath, RidePath.internet);
      }));

  test('a rider with no box never hears "Your box is disconnected"', () => fakeAsync((fa) {
        final a = RideRig().relayPhone('A', 0xA);
        a.engine.start();
        a.startMic();
        fa.elapse(const Duration(seconds: 15));
        expect(a.audio.spoken, isNot(contains('Your box is disconnected')));
      }));

  test('in Box only mode nothing goes to the relay', () => fakeAsync((fa) {
        final r = RideRig();
        final a = r.bothPhone('A', 0xA, mode: BoxMode.boxOnly);
        a.engine.start();
        a.startMic();
        r.box.sendStatus();
        fa.elapse(const Duration(seconds: 3));
        expect(r.relaySends(a), 0);
      }));

  test('switching to Box only stops sending to the relay within a second', () => fakeAsync((fa) {
        final r = RideRig();
        final a = r.bothPhone('A', 0xA);
        a.engine.start();
        a.startMic();
        fa.elapse(const Duration(seconds: 2));
        expect(r.relaySends(a), greaterThan(0));
        a.engine.mode = BoxMode.boxOnly;
        fa.flushMicrotasks();
        final sent = r.relaySends(a);
        fa.elapse(const Duration(seconds: 3));
        expect(r.relaySends(a), sent);
        expect(a.logText, contains('path,mode=boxOnly'));
      }));

  test('a rider on the box and one on the relay hear each other when the box rider has data', () => fakeAsync((fa) {
        final r = RideRig();
        final a = r.bothPhone('A', 0xA), b = r.relayPhone('B', 0xB);
        a.engine.start();
        b.engine.start();
        a.startMic();
        b.startMic();
        r.box.sendStatus();
        fa.elapse(const Duration(seconds: 2));
        a.talk();
        fa.elapse(const Duration(seconds: 1));
        expect(b.heardVoiceSince(0), isTrue);
        a.quiet();
        fa.elapse(const Duration(seconds: 1));
        final from = a.audio.played.length;
        b.talk();
        fa.elapse(const Duration(seconds: 1));
        expect(a.heardVoiceSince(from), isTrue);
      }));

  test('phones whose clocks are 2 h apart say why they hear nobody', () => fakeAsync((fa) {
        const said =
            'The phone clocks are too far apart to hear each other. Check the date and time are set to automatic.';
        final r = RideRig();
        final b = RidePhone(r.box.join(), r.keys, 'B', 0xB, clockSkew: const Duration(hours: 2));
        r.a.engine.start();
        b.engine.start();
        r.a.startMic();
        b.startMic();
        r.box.sendStatus();
        fa.elapse(const Duration(seconds: 3));
        expect(r.a.audio.spoken, contains(said)); // with two riders, either clock could be the wrong one
        expect(b.audio.spoken, contains(said));
      }));

  test("A's voice plays on B and never on A", () => fakeAsync((fa) {
        final r = RideRig()..startBoth(fa);
        expect(r.a.state!.connection, BoxConnectionState.joined);
        r.a.talk();
        fa.elapse(const Duration(seconds: 1));
        expect(r.b.heardVoiceSince(0), isTrue);
        expect(r.a.heardVoiceSince(0), isFalse);
        expect(r.b.state!.link!.peers[0xA]!.talking, isTrue);
      }));

  test('a stop during the start undoes the start once it finishes', () => fakeAsync((fa) {
        // The ride screen closed while the platform was still starting the audio: no ride may keep running unseen.
        final r = RideRig();
        final gate = r.a.audio.startGate = Completer<void>();
        r.a.engine.start();
        r.a.engine.stop();
        fa.flushMicrotasks();
        gate.complete();
        fa.elapse(const Duration(seconds: 1));
        expect(r.a.audio.running, isFalse);
        final sent = r.a.net.sentToBox.length;
        fa.elapse(const Duration(seconds: 3));
        expect(r.a.net.sentToBox.length, sent); // no heartbeats: the box link is stopped too
      }));

  test('a mic that stops is logged, shown and restarted, and clears when it comes back', () => fakeAsync((fa) {
        final r = RideRig()..startBoth(fa);
        r.a.stopMic();
        fa.elapse(const Duration(seconds: 3));
        expect(r.a.logText, contains('audio,mic=stalled'));
        expect(r.a.state!.audioIssue, 'The microphone stopped. Restarting the audio…');
        expect(r.a.audio.restarts, 1);
        r.a.startMic();
        fa.elapse(const Duration(seconds: 2));
        expect(r.a.state!.audioIssue, isNull);
        expect(r.a.logText, contains('audio,mic=back'));
      }));

  test('restarts for a stalled mic are at least 10 s apart', () => fakeAsync((fa) {
        final r = RideRig()..startBoth(fa);
        r.a.stopMic();
        fa.elapse(const Duration(seconds: 15));
        expect(r.a.audio.restarts, 2);
      }));

  test('a quiet mic during a call is not a stall', () => fakeAsync((fa) {
        final r = RideRig()..startBoth(fa);
        r.a.audio.emit(CallStateChanged(CallState.active));
        r.a.stopMic();
        fa.elapse(const Duration(seconds: 5));
        expect(r.a.audio.restarts, 0);
        expect(r.a.state!.audioIssue, isNull);
      }));

  test('an audio failure shows on the screen', () => fakeAsync((fa) {
        final r = RideRig()..startBoth(fa);
        r.a.audio.emit(AudioFailed('call detection needs the phone permission'));
        fa.flushMicrotasks(); // the state reaches listeners on the next microtask
        expect(r.a.state!.audioIssue, 'call detection needs the phone permission');
      }));

  test('an interruption shows in the state', () => fakeAsync((fa) {
        final r = RideRig()..startBoth(fa);
        r.a.audio.emit(InterruptionChanged(true));
        fa.flushMicrotasks();
        expect(r.a.state!.interrupted, isTrue);
        r.a.audio.emit(InterruptionChanged(false));
        fa.flushMicrotasks();
        expect(r.a.state!.interrupted, isFalse);
      }));

  test('each frame plays once when the box delivers it twice', () => fakeAsync((fa) {
        final r = RideRig(duplicate: true)..startBoth(fa);
        r.a.talk();
        fa.elapse(const Duration(seconds: 1));
        r.a.quiet();
        fa.elapse(const Duration(seconds: 2));
        final played = r.b.decoders.fold(0, (n, d) => n + d.decoded + d.recovered);
        expect(played, r.voiceSent(r.a));
        expect(played, greaterThan(50));
      }));

  test('a call mutes both ways, and the others hear about it', () => fakeAsync((fa) {
        final r = RideRig()..startBoth(fa);
        r.a.audio.emit(CallStateChanged(CallState.ringing));
        final sentBefore = r.voiceSent(r.a), playedBefore = r.a.audio.played.length;
        r.a.talk();
        r.b.talk();
        fa.elapse(const Duration(seconds: 2));
        expect(r.voiceSent(r.a), sentBefore); // the group can't hear A
        expect(r.a.audio.played.skip(playedBefore).every((f) => f.every((s) => s == 0)), isTrue); // nor A the group
        expect(r.a.state!.onCall, isTrue);
        expect(r.b.audio.spoken, contains('A is on a call'));
        r.b.quiet();
        fa.elapse(const Duration(milliseconds: 500));
        final playedOnB = r.b.audio.played.length;
        r.a.audio.emit(CallStateChanged(CallState.idle));
        fa.elapse(const Duration(milliseconds: 100));
        expect(r.b.heardVoiceSince(playedOnB), isTrue); // A is back within 100 ms
        fa.elapse(const Duration(seconds: 1));
        expect(r.b.audio.spoken, contains('A is off the call'));
        expect(r.a.logText, contains(',call,state=ringing'));
      }));

  test('a declined call brings the rider straight back', () => fakeAsync((fa) {
        final r = RideRig()..startBoth(fa);
        r.a.audio.emit(CallStateChanged(CallState.ringing));
        fa.elapse(const Duration(seconds: 1));
        r.a.audio.emit(CallStateChanged(CallState.idle)); // declined
        final playedOnB = r.b.audio.played.length;
        r.a.talk();
        fa.elapse(const Duration(milliseconds: 100));
        expect(r.b.heardVoiceSince(playedOnB), isTrue);
        expect(r.a.state!.onCall, isFalse);
      }));

  test('an interruption mutes until it ends', () => fakeAsync((fa) {
        final r = RideRig()..startBoth(fa);
        r.a.audio.emit(InterruptionChanged(true));
        final sentBefore = r.voiceSent(r.a);
        r.a.talk();
        fa.elapse(const Duration(seconds: 1));
        expect(r.voiceSent(r.a), sentBefore);
        r.a.audio.emit(InterruptionChanged(false));
        fa.elapse(const Duration(milliseconds: 100));
        expect(r.voiceSent(r.a), greaterThan(sentBefore));
        expect(r.a.logText, contains(',audio,interruption=began'));
      }));

  test('a route change keeps the ride going, and is logged', () => fakeAsync((fa) {
        final r = RideRig()..startBoth(fa);
        r.a.audio.emit(RouteChanged(AudioRoute.bluetooth, 'Intercom', 16000));
        final playedOnB = r.b.audio.played.length;
        r.a.talk();
        fa.elapse(const Duration(milliseconds: 200));
        expect(r.a.logText, contains(',audio,route=bluetooth name=Intercom rate=16000'));
        expect([r.a.state!.route, r.a.state!.routeName, r.a.state!.routeRate], [AudioRoute.bluetooth, 'Intercom', 16000]);
        expect(r.b.heardVoiceSince(playedOnB), isTrue);
      }));

  test('mic denied stops the start', () => fakeAsync((fa) {
        final r = RideRig();
        r.a.audio.startResult = StartResult.micDenied;
        StartResult? result;
        r.a.engine.start().then((x) => result = x);
        fa.elapse(const Duration(seconds: 2));
        expect(result, StartResult.micDenied);
        expect(r.a.state!.problem, RideProblem.micDenied);
        expect(r.a.net.sentToBox, isEmpty); // nothing goes on the box
      }));

  test("a failed speech engine doesn't stop the ride", () => fakeAsync((fa) {
        final r = RideRig();
        r.b.audio.speechFails = true;
        r.startBoth(fa); // B tries to say "A joined"
        expect(r.b.logText, contains(',audio,speech=failed'));
        final playedOnB = r.b.audio.played.length;
        r.a.talk();
        fa.elapse(const Duration(milliseconds: 200));
        expect(r.b.heardVoiceSince(playedOnB), isTrue);
      }));

  test('spoken alerts reach the speaker', () => fakeAsync((fa) {
        final r = RideRig()..startBoth(fa);
        fa.elapse(const Duration(seconds: 1));
        r.a
          ..stopMic()
          ..engine.stop();
        final playedOnB = r.b.audio.played.length;
        fa.elapse(const Duration(seconds: 6));
        expect(r.b.audio.spoken, contains('A dropped off'));
        expect(
            r.b.audio.played.skip(playedOnB).any((f) => f.every((s) => s == FakeVrooAudio.speechLevel)), isTrue);
      }));

  test('stats are logged every 5 s', () => fakeAsync((fa) {
        final r = RideRig()..startBoth(fa);
        r.a.talk();
        fa.elapse(const Duration(seconds: 5));
        expect(r.b.logText, contains(',stats,peer=A rx='));
        expect(r.b.logText, contains(',stats,peer=me tx='));
      }));
}
