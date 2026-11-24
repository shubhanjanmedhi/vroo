// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vroo/main.dart';
import 'package:vroo/ui/ride_screen.dart';
import 'package:vroo_audio/vroo_audio.dart';
import 'package:vroo_net/vroo_net.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

void main() {
  testWidgets('home shows the box, group and ride actions, and the licences', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(VrooApp(net: FakeVrooNet(), audio: FakeVrooAudio()));
    await tester.pumpAndSettle();
    for (final label in ['Set up a box', 'Use a box someone set up', 'Start group', 'Join group', 'Start ride']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byTooltip('Licences'), findsOneWidget);
  });

  testWidgets('the licences page says Vroo is free software with no warranty', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(VrooApp(net: FakeVrooNet(), audio: FakeVrooAudio()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Licences'));
    await tester.pumpAndSettle();
    expect(find.textContaining('free software under the GNU GPL, version 3 or later, with no warranty'), findsOneWidget);
  });

  testWidgets("with no box and no relay server a ride doesn't start, and home says why", (tester) async {
    SharedPreferences.setMockInitialValues(
        {'rider_name': 'Asha', 'group_invite': encodeInvite(Invite(Uint8List(32), 'Sunday ride'))});
    await tester.pumpWidget(VrooApp(net: FakeVrooNet(), audio: FakeVrooAudio()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start ride'));
    await tester.pumpAndSettle();
    expect(find.text('Set up a box, or type a relay server for mobile data, so the group can hear you.'),
        findsOneWidget);
    expect(find.byType(RideScreen), findsNothing);
  });
}
