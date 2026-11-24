// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../vroo_net.dart';

/// A [VrooNet] for tests: it records what's joined and sent, and delivers whatever the test [emit]s.
class FakeVrooNet implements VrooNet {
  final sentToBox = <(int, Uint8List)>[];
  final sentToInternet = <(InternetAddress, int, Uint8List)>[];

  /// The SSID of each join, with `Vroo-setup-` standing for [joinSetupNetwork].
  final joins = <String>[];
  JoinOutcome nextJoinOutcome = JoinOutcome.joined;

  /// How long a join takes to answer (null: at once). As in the Android plugin, a new join or [leaveBox] answers
  /// the one still waiting [JoinOutcome.failed].
  Duration? joinDelay;
  Completer<JoinOutcome>? _waiting;

  /// While on, every query sent to 1.1.1.1:53 gets a matching DNS response, as if the internet were up.
  bool answerDnsProbes = false;

  /// The names those responses give an address for; any other name gets none.
  final dnsRecords = <String, InternetAddress>{};
  final _events = StreamController<NetEvent>.broadcast();

  void emit(NetEvent e) => _events.add(e);

  @override
  Stream<NetEvent> get events => _events.stream;

  @override
  Future<JoinOutcome> joinBox({required String ssid, String? password}) {
    joins.add(ssid);
    return _answer();
  }

  @override
  Future<JoinOutcome> joinSetupNetwork() {
    joins.add('Vroo-setup-');
    return _answer();
  }

  Future<JoinOutcome> _answer() {
    _withdraw();
    final delay = joinDelay;
    if (delay == null) return Future.value(nextJoinOutcome);
    final waiting = _waiting = Completer<JoinOutcome>();
    Timer(delay, () {
      if (!waiting.isCompleted) waiting.complete(nextJoinOutcome);
    });
    return waiting.future;
  }

  void _withdraw() {
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete(JoinOutcome.failed);
  }

  @override
  Future<void> leaveBox() async => _withdraw();

  @override
  Future<void> sendToBox(Uint8List data, {required int port}) async => sentToBox.add((port, data));

  @override
  Future<void> sendToInternet(Uint8List data, InternetAddress host, int port) async {
    sentToInternet.add((host, port, data));
    if (answerDnsProbes && host.address == '1.1.1.1' && port == 53 && data.length >= 12) {
      final address = dnsRecords[_queryName(data)];
      emit(InternetDatagram(host, port, Uint8List.fromList([
        data[0], data[1], 0x81, 0x80, 0, 1, 0, address == null ? 0 : 1, 0, 0, 0, 0, // one question, and the answer
        ...data.sublist(12), // the question, as asked
        if (address != null) ...[0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, ...address.rawAddress], // its A record
      ])));
    }
  }

  static String _queryName(Uint8List query) => [
        for (var at = 12; at < query.length && query[at] != 0; at += 1 + query[at])
          String.fromCharCodes(query.sublist(at + 1, at + 1 + query[at])),
      ].join('.');

  @override
  Future<void> dispose() => _events.close();
}
