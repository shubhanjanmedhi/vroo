// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import '../vroo_net.dart';

/// [VrooNet] over the plugin's platform channels.
/// - Android: the box's Wi-Fi never becomes the default network, so box datagrams go through a native socket bound
///   to it, and internet datagrams through a plain Dart socket on the default network (mobile data).
/// - iOS: the other way round. iOS routes 192.168.4.x over the box's Wi-Fi by itself, so box datagrams use a Dart
///   socket, and internet datagrams go native so they can be pinned to mobile data while the box's Wi-Fi is up.
class ChannelVrooNet implements VrooNet {
  /// [ios] and [bindSocket] let tests run the iOS paths on any machine.
  ChannelVrooNet({@visibleForTesting bool? ios, @visibleForTesting Future<RawDatagramSocket> Function()? bindSocket})
      : _ios = ios ?? Platform.isIOS,
        _bind = bindSocket ?? (() => RawDatagramSocket.bind(InternetAddress.anyIPv4, 0));

  final bool _ios;
  final Future<RawDatagramSocket> Function() _bind;

  static const _methods = MethodChannel('vroo_net');
  static const _eventChannel = EventChannel('vroo_net/events');
  static final _boxAddress = InternetAddress(boxIp);

  late final _events = StreamController<NetEvent>.broadcast(onListen: _listenNative, onCancel: _cancelNative);
  StreamSubscription<Object?>? _native;
  Timer? _boxNetworkPoll; // iOS
  Future<RawDatagramSocket>? _internet; // Android
  Future<RawDatagramSocket>? _box; // iOS

  /// While the box's Wi-Fi is up, iOS must send internet traffic over mobile data explicitly.
  bool _boxUp = false;

  /// Whether [_boxUp] has been observed yet. The platform reports only changes, so a listener that comes later is
  /// told the current state when it starts listening.
  bool _boxKnown = false;

  @override
  Stream<NetEvent> get events => Stream.multi((listener) {
        if (_boxKnown) listener.add(BoxNetworkChanged(_boxUp));
        final sub = _events.stream.listen(listener.add, onError: listener.addError, onDone: listener.close);
        listener.onCancel = sub.cancel;
      }, isBroadcast: true);

  void _listenNative() {
    _native = _eventChannel.receiveBroadcastStream().listen((raw) {
      final e = _event(raw);
      if (e != null) _events.add(e);
    });
    if (_ios) {
      _checkBoxNetwork();
      _boxNetworkPoll = Timer.periodic(const Duration(seconds: 2), (_) => _checkBoxNetwork());
    }
  }

  void _cancelNative() {
    _native?.cancel();
    _native = null;
    _boxNetworkPoll?.cancel();
    _boxNetworkPoll = null;
  }

  NetEvent? _event(Object? raw) {
    final m = raw as Map<Object?, Object?>;
    switch (m['kind']) {
      case 'boxNetwork':
        _boxKnown = true;
        return BoxNetworkChanged(_boxUp = m['available']! as bool);
      case 'box':
        return BoxDatagram(m['fromPort']! as int, m['data']! as Uint8List);
      case 'internet':
        return InternetDatagram(InternetAddress(m['host']! as String), m['port']! as int, m['data']! as Uint8List);
    }
    return null;
  }

  /// iOS has no box-network callback: the phone is on the box's Wi-Fi while it holds a 192.168.4.x address.
  // ponytail: a home network on 192.168.4.x looks like a box too; the box's BOX_STATUS tells them apart if needed.
  Future<void> _checkBoxNetwork() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final up = interfaces.any((i) => i.addresses.any((a) => a.address.startsWith('192.168.4.')));
    _boxKnown = true;
    if (up && !_boxUp) _closeBoxSocket(); // a fresh socket for the box's Wi-Fi coming back
    if (up != _boxUp && !_events.isClosed) _events.add(BoxNetworkChanged(_boxUp = up));
  }

  @override
  Future<JoinOutcome> joinBox({required String ssid, String? password}) =>
      _join('joinBox', {'ssid': ssid, 'password': ?password});

  @override
  Future<JoinOutcome> joinSetupNetwork() => _join('joinSetupNetwork', {});

  Future<JoinOutcome> _join(String method, Map<String, Object> args) async {
    try {
      return JoinOutcome.values.byName(await _methods.invokeMethod<String>(method, args) ?? 'failed');
    } on PlatformException {
      return JoinOutcome.failed; // for example, Android refuses a passphrase with characters outside ASCII
    }
  }

  @override
  Future<void> leaveBox() => _methods.invokeMethod('leaveBox');

  @override
  Future<void> sendToBox(Uint8List data, {required int port}) async {
    if (!_ios) return _methods.invokeMethod('sendToBox', {'port': port, 'data': data});
    final s = await (_box ??= _openSocket((d) => d.address == _boxAddress ? BoxDatagram(d.port, d.data) : null));
    try {
      // 0 means the socket's buffer is full, as happens now and then at 50 packets a second: this datagram is lost,
      // and the socket stays. A new socket would be a new source port, held by the box for 30 s in its phone table.
      s.send(data, _boxAddress, port);
    } on SocketException {
      _closeBoxSocket(); // iOS can leave a socket dead for good after the Wi-Fi drops, so the next send opens one
    }
  }

  void _closeBoxSocket() {
    final box = _box;
    _box = null;
    box?.then((s) => s.close());
  }

  @override
  Future<void> sendToInternet(Uint8List data, InternetAddress host, int port) async {
    if (!_ios) {
      (await (_internet ??= _openSocket((d) => InternetDatagram(d.address, d.port, d.data)))).send(data, host, port);
    } else {
      await _methods
          .invokeMethod('sendToInternet', {'host': host.address, 'port': port, 'data': data, 'viaCellular': _boxUp});
    }
  }

  /// A Dart UDP socket whose datagrams become events through [toEvent] (null drops one).
  Future<RawDatagramSocket> _openSocket(NetEvent? Function(Datagram d) toEvent) async {
    final s = await _bind();
    s.listen(
      (event) {
        final d = event == RawSocketEvent.read ? s.receive() : null;
        final e = d == null ? null : toEvent(d);
        if (e != null && !_events.isClosed) _events.add(e);
      },
      // dart:io doesn't throw when the OS refuses a send (no network, say): send returns 0 and the error comes here
      // a moment later. A datagram is best effort, so it's simply lost.
      onError: (Object _) {},
    );
    return s;
  }

  @override
  Future<void> dispose() async {
    (await _internet)?.close();
    (await _box)?.close();
    _cancelNative();
    await _events.close();
  }
}
