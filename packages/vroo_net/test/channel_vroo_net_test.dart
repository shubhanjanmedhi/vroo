// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo_net/src/channel_vroo_net.dart';
import 'package:vroo_net/vroo_net.dart';

/// A socket whose buffer is always full (every send returns 0), or whose sends throw when [throws] is set. With
/// [reportsLater], a send fails the way dart:io's do when the OS refuses it (no network): it returns 0 and the error
/// arrives on the socket's stream a moment later.
class _FakeSocket extends Stream<RawSocketEvent> implements RawDatagramSocket {
  _FakeSocket({this.throws = false, this.reportsLater = false});

  final bool throws, reportsLater;
  final _events = StreamController<RawSocketEvent>();
  int sends = 0;
  bool closed = false;

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    sends++;
    if (throws) throw const SocketException('Network is down');
    if (reportsLater) _events.addError(const SocketException('Send failed (OS Error: Network is unreachable)'));
    return 0;
  }

  @override
  void close() => closed = true;

  @override
  StreamSubscription<RawSocketEvent> listen(void Function(RawSocketEvent event)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _events.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('vroo_net');
  const events = EventChannel('vroo_net/events');
  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
  });

  test('a new listener learns the box network is already up', () async {
    var listens = 0;
    messenger.setMockStreamHandler(events, MockStreamHandler.inline(onListen: (_, sink) {
      if (listens++ == 0) sink.success({'kind': 'boxNetwork', 'available': true}); // the platform says it once
    }));
    final net = createVrooNet();
    expect(((await net.events.first) as BoxNetworkChanged).available, isTrue);
    final later = await net.events.first.timeout(const Duration(seconds: 1)); // a listener that came later
    expect((later as BoxNetworkChanged).available, isTrue);
  });

  test('on iOS, a full send buffer drops the datagram but keeps the socket', () async {
    // At 50 packets a second the socket's buffer fills now and then. A new socket is a new source port, and the box
    // would keep the old one for 30 s in its 4-entry phone table.
    final sockets = <_FakeSocket>[];
    final net = ChannelVrooNet(ios: true, bindSocket: () async => (sockets..add(_FakeSocket())).last);
    await net.sendToBox(Uint8List(4), port: 47000);
    await net.sendToBox(Uint8List(4), port: 47000);
    expect(sockets, hasLength(1));
    expect(sockets.single.sends, 2);
    expect(sockets.single.closed, isFalse);
  });

  test('on iOS, a socket error replaces the socket', () async {
    final sockets = <_FakeSocket>[];
    final net =
        ChannelVrooNet(ios: true, bindSocket: () async => (sockets..add(_FakeSocket(throws: sockets.isEmpty))).last);
    await net.sendToBox(Uint8List(4), port: 47000); // the first socket throws: iOS can leave it dead after a Wi-Fi drop
    await net.sendToBox(Uint8List(4), port: 47000);
    expect(sockets, hasLength(2));
    expect(sockets.first.closed, isTrue);
    expect(sockets.last.sends, 1);
  });

  test('on Android, the internet probe says no internet when there is no network to send on', () async {
    // The desk Android has no SIM: on the box's Wi-Fi a send to the internet fails with "Network is unreachable".
    final net = ChannelVrooNet(ios: false, bindSocket: () async => _FakeSocket(reportsLater: true));
    expect(await probeInternet(net, timeout: const Duration(milliseconds: 50)), isFalse);
    await pumpEventQueue(); // an error the socket reported must have been handled, not left for the zone
  });

  test('a platform error during a join answers failed', () async {
    // Android refuses a WPA2 passphrase with characters outside ASCII.
    messenger.setMockMethodCallHandler(methods, (call) async => throw PlatformException(code: 'error'));
    expect(await createVrooNet().joinBox(ssid: 'Vroo-A1B2C3', password: 'abcd’efgh'), JoinOutcome.failed);
  });
}
