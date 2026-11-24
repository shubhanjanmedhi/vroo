// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/net/box_connection.dart';
import 'package:vroo/ui/box_hint.dart';

void main() {
  const ssid = 'Vroo-A1B2C3', password = 'abcd-efgh-jkmn-pqrs';
  String? hint(BoxConnectionState s, {bool boxUp = false, bool iOS = false}) =>
      boxHint(s, boxUp: boxUp, ssid: ssid, password: password, iOS: iOS);

  test('nothing to do while the box answers', () {
    expect(hint(BoxConnectionState.joined, boxUp: true), isNull);
    expect(hint(BoxConnectionState.idle), isNull);
  });
  test('joining on Android says to tap Connect', () {
    expect(hint(BoxConnectionState.joining), contains('tap Connect'));
  });
  test('a manual join says where in Settings, with the password', () {
    final h = hint(BoxConnectionState.needsManualJoin, iOS: true)!;
    expect(h, allOf(contains('Settings → Wi-Fi'), contains(ssid), contains(password)));
  });
  test('denied says what to check and how to try again', () {
    expect(hint(BoxConnectionState.denied), allOf(contains('box is on'), contains('Stop')));
  });
  test('on the Wi-Fi with no answer names Local Network on iPhone only', () {
    expect(hint(BoxConnectionState.joined, iOS: true), contains('Local Network'));
    expect(hint(BoxConnectionState.joined), allOf(contains('light'), isNot(contains('Local Network'))));
  });
}
