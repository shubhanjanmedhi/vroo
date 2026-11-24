// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/net/peer.dart';
import 'package:vroo/ride/alerts.dart';

const lost = "You've lost the group. Move closer to the others.";
const clocks = 'The phone clocks are too far apart to hear each other. Check the date and time are set to automatic.';

/// Drives one [Alerts] in whole seconds; riders are added with [rider] and heard with [hear].
class Ride {
  final alerts = Alerts();
  final peers = <int, PeerInfo>{};
  bool boxUp = true, myCall = false, clockGap = false;

  void rider(int id, String name, int ms) => peers[id] = PeerInfo(id: id, name: name, lastHeardMs: ms);
  void hear(int id, int ms) => peers[id]!.lastHeardMs = ms;

  /// What's said at [ms], with the tone as `<tone>`.
  List<String> at(int ms) => [
        for (final a in alerts.update(
            peers: peers,
            names: displayNames(peers, myId: 1, myName: 'Me'),
            boxUp: boxUp,
            myCall: myCall,
            clockGap: clockGap,
            nowMs: ms))
          switch (a) {
            Say(:final text) => text,
            BackTone() => '<tone>',
          },
      ];
}

void main() {
  test('a new rider is announced once', () {
    final r = Ride()..rider(2, 'Meera', 0);
    expect(r.at(0), ['Meera joined']);
    r.hear(2, 1000);
    expect(r.at(1000), isEmpty);
  });

  test('a rider silent for 4 s dropped off, and is back with a tone', () {
    final r = Ride()
      ..rider(2, 'Meera', 0)
      ..rider(3, 'Arjun', 0);
    r.at(0);
    for (var s = 1; s <= 4; s++) {
      r.hear(3, s * 1000); // Arjun stays in range
      expect(r.at(s * 1000), isEmpty);
    }
    r.hear(3, 5000);
    expect(r.at(5000), ['Meera dropped off']);
    r
      ..hear(2, 6000)
      ..hear(3, 6000);
    expect(r.at(6000), ['<tone>', 'Meera is back']);
  });

  test('alone for 4 s after riding together: move closer, every 60 s', () {
    final r = Ride()..rider(2, 'Meera', 0);
    r.at(0);
    expect(r.at(4000), isEmpty);
    expect(r.at(5000), ['Meera dropped off', lost]);
    for (var s = 6; s < 65; s++) {
      expect(r.at(s * 1000), isEmpty, reason: '$s s');
    }
    expect(r.at(65000), [lost]);
  });

  test('alone at the start says nothing', () {
    final r = Ride();
    for (var s = 0; s <= 70; s++) {
      expect(r.at(s * 1000), isEmpty);
    }
  });

  test('hearing nobody because of the phone clocks is said once', () {
    final r = Ride()..clockGap = true;
    expect(r.at(0), [clocks]);
    expect([for (var s = 1; s <= 70; s++) ...r.at(s * 1000)], isEmpty);
  });

  test('a wrong clock elsewhere in a group this phone hears is only shown, not said', () {
    final r = Ride()
      ..rider(2, 'Meera', 0)
      ..clockGap = true;
    expect(r.at(0), ['Meera joined']);
  });

  test('the box down for 10 s is said once', () {
    final r = Ride()..boxUp = false;
    final said = [for (var s = 0; s <= 30; s++) ...r.at(s * 1000)];
    expect(said, ['Your box is disconnected']);
    r.boxUp = true;
    r.at(31000);
    r.boxUp = false;
    expect([for (var s = 32; s <= 42; s++) ...r.at(s * 1000)], ['Your box is disconnected']); // a new outage
  });

  test('call flag changes are announced', () {
    final r = Ride()..rider(2, 'Dev', 0);
    r.at(0);
    r.peers[2]!.onCall = true;
    r.hear(2, 1000);
    expect(r.at(1000), ['Dev is on a call']);
    r.peers[2]!.onCall = false;
    r.hear(2, 2000);
    expect(r.at(2000), ['Dev is off the call']);
  });

  test('nothing is said during my own call', () {
    final r = Ride()..myCall = true;
    r.rider(2, 'Meera', 0);
    expect(r.at(0), isEmpty);
    expect(r.at(5000), isEmpty); // Meera dropped off, and I'm alone
    r.myCall = false;
    expect(r.at(6000), isEmpty); // nothing replays afterwards
  });

  test('above 10 riders only my own messages play', () {
    final r = Ride()..boxUp = false;
    for (var id = 2; id <= 11; id++) {
      r.rider(id, 'Rider$id', 0); // 10 others, 11 riders with me
    }
    final said = <String>[];
    for (var s = 0; s <= 10; s++) {
      for (var id = 2; id <= 11; id++) {
        r.hear(id, s * 1000);
      }
      said.addAll(r.at(s * 1000));
    }
    expect(said, ['Your box is disconnected']);
  });
}
