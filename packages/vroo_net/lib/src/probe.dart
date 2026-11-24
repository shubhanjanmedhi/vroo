// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../vroo_net.dart';

/// A DNS query for [name]'s A record (example.com's by default), with recursion desired.
Uint8List encodeDnsQuery(int id, [String name = 'example.com']) => Uint8List.fromList([
      id >> 8 & 0xFF, id & 0xFF, 0x01, 0x00, // id, then flags: a standard query, recursion desired
      0, 1, 0, 0, 0, 0, 0, 0, // one question
      for (final label in name.split('.')) ...[label.length, ...label.codeUnits],
      0,
      0, 1, 0, 1, // type A, class IN
    ]);

/// Whether [bytes] is a DNS response (QR bit set) to query [id].
bool isDnsResponseFor(int id, Uint8List bytes) =>
    bytes.length >= 12 && bytes[0] == (id >> 8 & 0xFF) && bytes[1] == (id & 0xFF) && bytes[2] & 0x80 != 0;

/// The first IPv4 address answered in DNS [response], or null for an error, no address, or a response cut short.
InternetAddress? firstIPv4In(Uint8List response) {
  if (response.length < 12 || response[3] & 0x0F != 0) return null; // the error code isn't 0
  final d = ByteData.sublistView(response);
  int? afterName(int at) {
    while (at < response.length) {
      final length = response[at];
      if (length == 0) return at + 1;
      if (length & 0xC0 == 0xC0) return at + 2; // a pointer to a name earlier in the response
      at += 1 + length;
    }
    return null;
  }

  int? at = 12;
  for (var q = d.getUint16(4); q > 0 && at != null; q--) {
    at = afterName(at);
    if (at != null) at += 4; // type and class
  }
  for (var a = d.getUint16(6); a > 0 && at != null; a--) {
    final name = afterName(at);
    if (name == null || name + 10 > response.length) return null;
    final type = d.getUint16(name), klass = d.getUint16(name + 2), length = d.getUint16(name + 8), data = name + 10;
    if (data + length > response.length) return null;
    if (type == 1 && klass == 1 && length == 4) return InternetAddress.fromRawAddress(response.sublist(data, data + 4));
    at = data + length; // a CNAME or another record
  }
  return null;
}

/// The "has internet" test: does a DNS query to 1.1.1.1:53 get an answer within [timeout]?
Future<bool> probeInternet(VrooNet net, {Duration timeout = const Duration(seconds: 2), Random? random}) async =>
    await _askDns(net, 'example.com', timeout, random) != null;

/// [host]'s IPv4 address, asked of 1.1.1.1 over the internet path like the probe. The system's own lookup can't be
/// used: on an iPhone the box's Wi-Fi can be the default network, so it would ask the box, which can't answer. Null
/// if no address comes within [timeout].
Future<InternetAddress?> lookupOverInternet(VrooNet net, String host,
    {Duration timeout = const Duration(seconds: 2), Random? random}) async {
  final answer = await _askDns(net, host, timeout, random);
  return answer == null ? null : firstIPv4In(answer);
}

/// Sends a DNS query for [name] to 1.1.1.1:53 over the internet path, and returns the response, or null if none comes
/// within [timeout].
Future<Uint8List?> _askDns(VrooNet net, String name, Duration timeout, Random? random) async {
  final id = (random ?? Random()).nextInt(1 << 16);
  final answered = Completer<Uint8List?>();
  final sub = net.events.listen((e) {
    if (e is InternetDatagram && isDnsResponseFor(id, e.data) && !answered.isCompleted) answered.complete(e.data);
  });
  try {
    await net.sendToInternet(encodeDnsQuery(id, name), InternetAddress('1.1.1.1'), 53);
    return await answered.future.timeout(timeout, onTimeout: () => null);
  } on Exception {
    return null; // no route to send on is no internet
  } finally {
    unawaited(sub.cancel()); // nothing waits on the cancel
  }
}
