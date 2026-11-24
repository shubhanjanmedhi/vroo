// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Net check": the device test screen for vroo_net (plan Tasks 9 and 10). Join the box, register with it and
// probe the internet, while the events scroll by.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vroo_net/vroo_net.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

void main() => runApp(const MaterialApp(title: 'Vroo net check', home: NetCheck()));

class NetCheck extends StatefulWidget {
  const NetCheck({super.key});

  @override
  State<NetCheck> createState() => _NetCheckState();
}

class _NetCheckState extends State<NetCheck> {
  final _net = createVrooNet();
  final _ssid = TextEditingController(text: 'Vroo-');
  final _password = TextEditingController(text: 'abcd-efgh-jkmn-pqrs');
  final _log = <String>[];
  late final StreamSubscription<NetEvent> _events;

  @override
  void initState() {
    super.initState();
    _events = _net.events.listen((e) => _add(switch (e) {
          BoxNetworkChanged(:final available) => 'boxNetwork ${available ? 'available' : 'lost'}',
          BoxDatagram(:final fromPort, :final data) => 'box from $fromPort: ${decodeBoxStatus(data) ?? '${data.length} bytes'}',
          InternetDatagram(:final from, :final fromPort, :final data) =>
            'internet from ${from.address}:$fromPort, ${data.length} bytes',
        }));
  }

  @override
  void dispose() {
    _events.cancel();
    _net.dispose();
    super.dispose();
  }

  void _add(String line) => setState(() {
        _log.insert(0, '${DateTime.now().toIso8601String().substring(11, 23)}  $line');
        if (_log.length > 200) _log.removeLast();
      });

  Future<void> _join(Future<JoinOutcome> Function() join) async {
    if (Platform.isAndroid) await [Permission.nearbyWifiDevices, Permission.locationWhenInUse].request();
    _add('join: ${(await join()).name}');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Vroo net check')),
        body: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(children: [
            TextField(controller: _ssid, decoration: const InputDecoration(labelText: 'Box Wi-Fi name')),
            TextField(controller: _password, decoration: const InputDecoration(labelText: 'Password (empty for open)')),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(onPressed: () => _join(_net.joinSetupNetwork), child: const Text('Join setup Wi-Fi')),
              FilledButton(
                onPressed: () => _join(() => _net.joinBox(
                    ssid: _ssid.text, password: _password.text.isEmpty ? null : _password.text)),
                child: const Text('Join box'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await _net.sendToBox(encodeBoxConfig(const BoxConfig()), port: boxControlPort);
                  _add('register sent');
                },
                child: const Text('Register'),
              ),
              OutlinedButton(
                onPressed: () async => _add('internet: ${await probeInternet(_net)}'),
                child: const Text('Probe internet'),
              ),
            ]),
            const Divider(),
            Expanded(
              child: ListView(children: [
                for (final line in _log) Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ]),
            ),
          ]),
        ),
      );
}
