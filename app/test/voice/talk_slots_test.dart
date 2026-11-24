// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/voice/talk_slots.dart';

/// Runs 20 ms steps from [fromMs] to [toMs]: each step the [talking] riders are heard, then this phone decides.
List<(int, SlotDecision)> run(TalkSlots slots, int fromMs, int toMs, {required List<int> talking}) {
  final out = <(int, SlotDecision)>[];
  for (var t = fromMs; t < toMs; t += 20) {
    for (final id in talking) {
      slots.heard(id, t);
    }
    out.add((t, slots.decide(t)));
  }
  return out;
}

void main() {
  test('sends while fewer than 4 others are talking', () {
    final decisions = run(TalkSlots(), 0, 1000, talking: [2, 3, 4]);
    expect(decisions.every((d) => d.$2 == SlotDecision.send), isTrue);
  });

  test('a fifth talker is held and hears one busy tone every 5 s', () {
    final decisions = run(TalkSlots(), 0, 6000, talking: [2, 3, 4, 5]);
    expect(decisions.where((d) => d.$2 == SlotDecision.send), isEmpty);
    expect([for (final d in decisions) if (d.$2 == SlotDecision.holdWithBusyTone) d.$1], [0, 5000]);
  });

  test('the held talker is carried once a slot has been free for 500 ms', () {
    final slots = TalkSlots();
    run(slots, 0, 1000, talking: [2, 3, 4, 5]); // held; rider 5 is last heard at 980 ms
    final after = run(slots, 1000, 1600, talking: [2, 3, 4]);
    expect(after.firstWhere((d) => d.$2 == SlotDecision.send).$1, 1500); // at 1480, rider 5 still counts
  });

  test('a rider already talking keeps the slot when others start', () {
    final slots = TalkSlots();
    run(slots, 0, 200, talking: []); // this phone talks alone
    final later = run(slots, 200, 2000, talking: [2, 3, 4, 5]);
    expect(later.every((d) => d.$2 == SlotDecision.send), isTrue);
  });
}
