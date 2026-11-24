// SPDX-License-Identifier: GPL-3.0-or-later

/// Vroo's network plugin: joins the box's Wi-Fi and carries datagrams to the box and to the internet.
library;

import 'dart:io';
import 'dart:typed_data';

import 'src/channel_vroo_net.dart';

export 'src/fake_vroo_net.dart';
export 'src/probe.dart';

sealed class NetEvent {}

/// The box's Wi-Fi came up or went away.
final class BoxNetworkChanged extends NetEvent {
  BoxNetworkChanged(this.available);

  final bool available;
}

/// A datagram from the box (192.168.4.1), and the box port it came from.
final class BoxDatagram extends NetEvent {
  BoxDatagram(this.fromPort, this.data);

  final int fromPort;
  final Uint8List data;
}

/// A datagram from the internet.
final class InternetDatagram extends NetEvent {
  InternetDatagram(this.from, this.fromPort, this.data);

  final InternetAddress from;
  final int fromPort;
  final Uint8List data;
}

enum JoinOutcome { joined, needsManualJoin, denied, failed }

abstract interface class VrooNet {
  Stream<NetEvent> get events;

  /// Joins the box's hotspot. A null [password] means an open network.
  Future<JoinOutcome> joinBox({required String ssid, String? password});

  /// Joins any open network whose name starts with `Vroo-setup-`.
  Future<JoinOutcome> joinSetupNetwork();

  Future<void> leaveBox();

  /// Sends to 192.168.4.1:[port] over the box's Wi-Fi. Fire and forget: with no box to reach, it's dropped.
  Future<void> sendToBox(Uint8List data, {required int port});

  /// Sends over the phone's internet connection, which is mobile data while the box's Wi-Fi is up.
  Future<void> sendToInternet(Uint8List data, InternetAddress host, int port);

  Future<void> dispose();
}

VrooNet createVrooNet() => ChannelVrooNet();
