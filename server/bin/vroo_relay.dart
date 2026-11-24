// SPDX-License-Identifier: AGPL-3.0-or-later
//
// vroo_relay [--port 47100]: runs the relay server until it's stopped, with a line of counters every 10 s.
import 'dart:async';
import 'dart:io';

import 'package:vroo_protocol/vroo_protocol.dart';
import 'package:vroo_relay/relay_server.dart';

Future<void> main(List<String> args) async {
  var port = relayPort;
  for (var i = 0; i < args.length; i++) {
    final value = i + 1 < args.length ? int.tryParse(args[i + 1]) : null;
    if (args[i] == '--port' && value != null && value > 0 && value < 65536) {
      port = value;
      i++;
    } else {
      stderr.writeln('usage: vroo_relay [--port 1-65535]   (default $relayPort)');
      exit(64);
    }
  }
  final relay = await RelayServer.bind(port: port);
  stdout.writeln('${_now()} vroo_relay listening on udp/${relay.port}');
  final status = Timer.periodic(const Duration(seconds: 10), (_) => stdout.writeln('${_now()} ${relay.statusLine()}'));
  Future<void> shutDown(ProcessSignal signal) async {
    status.cancel();
    stdout.writeln('${_now()} stopping (${signal.name}): ${relay.statusLine()}');
    await relay.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutDown);
  ProcessSignal.sigterm.watch().listen(shutDown);
}

String _now() => DateTime.now().toUtc().toIso8601String();
