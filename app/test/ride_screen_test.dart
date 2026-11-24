// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/net/box_connection.dart';
import 'package:vroo/net/group_link.dart';
import 'package:vroo/net/box_setup.dart';
import 'package:vroo/net/peer.dart';
import 'package:vroo/ride/ride_engine.dart';
import 'package:vroo/ui/ride_screen.dart';
import 'package:vroo_audio/vroo_audio.dart';

RideView rideView(RideState state, {bool running = true, bool withBox = true}) => RideView(
      state: state,
      groupName: 'Sunday ride',
      box: withBox ? const SavedBox(boxId: 0xA1B2C3, ssid: 'Vroo-A1B2C3', password: 'abcd-efgh-jkmn-pqrs') : null,
      iOS: false,
      running: running,
      thresholdDb: 12,
      onThreshold: (_) {},
      onStop: () {},
      onShareLog: null,
      onOpenSettings: () {},
      nowMs: 5000,
    );

/// The ride screen's layout for [state]; RideEngine's tests cover how each state comes about.
Widget view(RideState state) => MaterialApp(home: rideView(state));

/// The ride screen opened from a home screen, as the app does, then the system back (Android) or edge swipe (iOS).
Future<void> openThenGoBack(WidgetTester tester, {required bool running}) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => rideView(const RideState(), running: running))),
        child: const Text('home'),
      ),
    ),
  ));
  await tester.tap(find.text('home'));
  await tester.pumpAndSettle();
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the paths line shows box and data', (tester) async {
    await tester.pumpWidget(view(const RideState(link: GroupLinkState(boxUp: true, peers: {}, dataPathOn: true))));
    expect(find.text('Paths: box ✓ · data ✓'), findsOneWidget);
  });

  testWidgets('the bridge line shows while this phone bridges', (tester) async {
    await tester.pumpWidget(
        view(const RideState(link: GroupLinkState(boxUp: true, peers: {}, dataPathOn: true, bridge: true))));
    expect(find.text('This phone links the box riders to the internet'), findsOneWidget);
    await tester.pumpWidget(view(const RideState(link: GroupLinkState(boxUp: true, peers: {}, dataPathOn: true))));
    expect(find.text('This phone links the box riders to the internet'), findsNothing);
  });

  testWidgets("a relay that isn't found says so", (tester) async {
    await tester.pumpWidget(
        view(const RideState(link: GroupLinkState(boxUp: true, peers: {}, internetUp: true, relayNotFound: true))));
    expect(find.text('Relay server not found. Check its name on the home screen.'), findsOneWidget);
  });

  testWidgets("a rider whose clock is off is named while the others are heard", (tester) async {
    final peers = {2: PeerInfo(id: 2, name: 'Meera', lastHeardMs: 4000)};
    await tester.pumpWidget(view(RideState(
        link: GroupLinkState(boxUp: true, peers: peers, clockGaps: const {3: ClockGap('Ravi', 7200000)}))));
    expect(
        find.text("Ravi's phone clock is 2 h off, so the group can't hear them. "
            'Ask Ravi to set the time to automatic.'),
        findsOneWidget);
  });

  testWidgets('with nobody heard and one clock apart, neither phone is blamed', (tester) async {
    await tester.pumpWidget(view(const RideState(
        link: GroupLinkState(boxUp: true, peers: {}, clockGaps: {3: ClockGap('Ravi', -900000)}))));
    expect(
        find.text("Ravi's phone clock and this one are 15 min apart, so you can't hear each other. "
            'Set both to automatic time.'),
        findsOneWidget);
  });

  testWidgets("when every rider's clock is off by the same, it's this phone's clock", (tester) async {
    await tester.pumpWidget(view(const RideState(
        link: GroupLinkState(
            boxUp: true, peers: {}, clockGaps: {2: ClockGap('Meera', 7200000), 3: ClockGap('Ravi', 7230000)}))));
    expect(find.text("This phone's clock is 2 h off, so the group can't hear you. Set the date and time to automatic."),
        findsOneWidget);
    expect(find.textContaining('Meera'), findsNothing);
  });

  testWidgets('Box only says so', (tester) async {
    await tester.pumpWidget(view(const RideState(link: GroupLinkState(boxUp: true, peers: {}), mode: BoxMode.boxOnly)));
    expect(find.text('Paths: box ✓ · data off (Box only)'), findsOneWidget);
  });

  testWidgets('a rider heard over the internet says internet', (tester) async {
    final peers = {2: PeerInfo(id: 2, name: 'Meera', lastHeardMs: 4000)..lastPath = RidePath.internet};
    await tester.pumpWidget(view(RideState(link: GroupLinkState(boxUp: false, peers: peers), names: const {2: 'Meera'})));
    expect(find.textContaining(RegExp(r'^internet · ')), findsOneWidget);
  });

  testWidgets('with no box there is no box line', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: rideView(const RideState(link: GroupLinkState(boxUp: false, peers: {}, dataPathOn: true)), withBox: false)));
    expect(find.textContaining('Box Vroo'), findsNothing);
    expect(find.text('Paths: box ✗ · data ✓'), findsOneWidget);
  });

  testWidgets('an interruption shows the rider as paused', (tester) async {
    await tester.pumpWidget(view(const RideState(interrupted: true)));
    expect(find.text('You: paused'), findsOneWidget);
  });

  testWidgets('an audio problem shows on the screen', (tester) async {
    await tester.pumpWidget(view(const RideState(audioIssue: 'The microphone stopped. Restarting the audio…')));
    expect(find.text('The microphone stopped. Restarting the audio…'), findsOneWidget);
  });

  testWidgets("going back doesn't end a running ride", (tester) async {
    await openThenGoBack(tester, running: true);
    expect(find.byType(RideView), findsOneWidget);
  });

  testWidgets('after Stop, going back leaves the ride screen', (tester) async {
    await openThenGoBack(tester, running: false);
    expect(find.byType(RideView), findsNothing);
  });

  testWidgets('mic denied shows how to fix it', (tester) async {
    await tester.pumpWidget(view(const RideState(problem: RideProblem.micDenied)));
    expect(find.text('Allow the microphone in Settings, then start the ride again.'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
  });

  testWidgets('a talking rider shows the mic, and a rider on a call shows the phone', (tester) async {
    final peers = {
      2: PeerInfo(id: 2, name: 'Meera', lastHeardMs: 4000)..talking = true,
      3: PeerInfo(id: 3, name: 'Dev', lastHeardMs: 3000)..onCall = true,
    };
    await tester.pumpWidget(view(RideState(
      link: GroupLinkState(boxUp: true, peers: peers),
      connection: BoxConnectionState.joined,
      names: const {2: 'Meera', 3: 'Dev'},
    )));
    expect(find.text('Meera 🎙'), findsOneWidget);
    expect(find.text('Dev 📞'), findsOneWidget);
    expect(find.text('Sunday ride · 3 riders'), findsOneWidget);
  });

  testWidgets('no headset shows Loudspeaker', (tester) async {
    await tester.pumpWidget(view(const RideState(route: AudioRoute.speaker)));
    expect(find.text('Audio: Loudspeaker'), findsOneWidget);
  });

  testWidgets('the intercom shows with its rate', (tester) async {
    await tester.pumpWidget(view(const RideState(route: AudioRoute.bluetooth, routeName: 'Intercom', routeRate: 16000)));
    expect(find.text('Audio: Bluetooth (16 kHz)'), findsOneWidget);
  });

  testWidgets('the box instruction shows under the box line', (tester) async {
    await tester.pumpWidget(view(const RideState(connection: BoxConnectionState.needsManualJoin)));
    expect(find.textContaining('Open Settings → Wi-Fi, tap Vroo-A1B2C3'), findsOneWidget);
  });

  testWidgets('this rider waiting for a slot says so', (tester) async {
    await tester.pumpWidget(view(const RideState(held: true)));
    expect(find.text('You: waiting for a slot'), findsOneWidget);
  });
}
