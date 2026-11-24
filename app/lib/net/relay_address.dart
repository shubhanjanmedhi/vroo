// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:vroo_protocol/vroo_protocol.dart';

/// The relay server a group uses for its mobile-data path (D26): a host name or IPv4 address, and a UDP port.
class RelayAddress {
  const RelayAddress(this.host, this.port);

  final String host;
  final int port;

  @override
  bool operator ==(Object other) => other is RelayAddress && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => '$host:$port';
}

final _host = RegExp(r'^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$');

/// "relay.example.org" or "203.0.113.5:47100", as a rider types it; the port is [relayPort] when left out. Null when
/// it isn't a host, or a host and a port from 1 to 65535.
RelayAddress? parseRelayAddress(String text) {
  final t = text.trim();
  final parts = t.split(':');
  if (parts.length > 2 || !_host.hasMatch(parts.first)) return null;
  if (parts.length == 1) return RelayAddress(t, relayPort);
  final port = int.tryParse(parts[1]);
  return port == null || port < 1 || port > 65535 ? null : RelayAddress(parts.first, port);
}
