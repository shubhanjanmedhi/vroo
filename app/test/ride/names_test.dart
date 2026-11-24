// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/net/peer.dart';

Map<int, PeerInfo> riders(Map<int, String> names) =>
    {for (final e in names.entries) e.key: PeerInfo(id: e.key, name: e.value, lastHeardMs: 0)};

void main() {
  test('two riders with the same name are "Ravi" and "Ravi 2"', () {
    expect(displayNames(riders({5: 'Ravi', 9: 'Ravi'}), myId: 1, myName: 'Me'), {5: 'Ravi', 9: 'Ravi 2'});
  });

  test('my own name counts, and an empty name is "Rider"', () {
    expect(displayNames(riders({7: 'Ravi', 8: ' '}), myId: 3, myName: 'Ravi'), {7: 'Ravi 2', 8: 'Rider'});
  });
}
