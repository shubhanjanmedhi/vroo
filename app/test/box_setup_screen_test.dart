// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/ui/box_setup_screen.dart';
import 'package:vroo_net/vroo_net.dart';

/// Opens the setup screen and taps Next, which joins the box's setup Wi-Fi with [outcome].
Future<void> startSetup(WidgetTester tester, JoinOutcome outcome) async {
  await tester.pumpWidget(MaterialApp(home: BoxSetupScreen(net: FakeVrooNet()..nextJoinOutcome = outcome)));
  await tester.tap(find.text('Next'));
  await tester.pump();
}

void main() {
  testWidgets('a denied join asks for the Wi-Fi permission', (tester) async {
    await startSetup(tester, JoinOutcome.denied);
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi permission is needed to reach the box. Allow it and try again.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
  testWidgets('a manual join says where to look in Settings', (tester) async {
    await startSetup(tester, JoinOutcome.needsManualJoin);
    await tester.pumpAndSettle();
    expect(find.text('Open Settings → Wi-Fi and tap the network starting with Vroo-setup-, then come back.'),
        findsOneWidget);
    expect(find.text("I'm on it"), findsOneWidget);
  });
  testWidgets("a failed join says to check the box's light", (tester) async {
    await startSetup(tester, JoinOutcome.failed);
    await tester.pumpAndSettle();
    expect(find.textContaining('Check its light is blinking once a second'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
  testWidgets("a box that doesn't answer within 5 s says what to check", (tester) async {
    await startSetup(tester, JoinOutcome.joined);
    await tester.pump(const Duration(seconds: 6));
    expect(find.textContaining("The box didn't answer."), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
