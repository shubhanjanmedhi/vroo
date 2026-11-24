// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vroo_net/vroo_net.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import '../box/box_store.dart';
import '../net/box_setup.dart';

/// Android asks before an app may join a Wi-Fi network: "nearby Wi-Fi devices" on 13+, location before that.
Future<void> askWifiPermission() async {
  if (Platform.isAndroid) await [Permission.nearbyWifiDevices, Permission.locationWhenInUse].request();
}

/// Sets up a new box, step by step: its setup Wi-Fi, a fresh password (and the group, if there is one),
/// then its normal Wi-Fi, until it answers.
class BoxSetupScreen extends StatefulWidget {
  const BoxSetupScreen({super.key, required this.net, this.group});

  final VrooNet net;
  final Invite? group;

  @override
  State<BoxSetupScreen> createState() => _BoxSetupScreenState();
}

class _BoxSetupScreenState extends State<BoxSetupScreen> {
  late final _setup = BoxSetup(net: widget.net, random: Random.secure());
  SavedBox? _box;
  bool _busy = false;
  String _text = 'Plug the box in. Its light blinks once a second.';
  String? _next = 'Next';
  Future<void> Function()? _onNext;

  @override
  void initState() {
    super.initState();
    _onNext = _joinSetup;
  }

  void _show(String text, [String? next, Future<void> Function()? onNext]) {
    if (!mounted) return;
    setState(() {
      _text = text;
      _next = next;
      _onNext = onNext;
    });
  }

  Future<void> _joinSetup() async {
    _show('Joining the box…');
    await askWifiPermission();
    switch (await widget.net.joinSetupNetwork()) {
      case JoinOutcome.joined:
        await _configure();
      case JoinOutcome.needsManualJoin:
        _show('Open Settings → Wi-Fi and tap the network starting with Vroo-setup-, then come back.', "I'm on it", _configure);
      case JoinOutcome.denied:
        _show('Wi-Fi permission is needed to reach the box. Allow it and try again.', 'Try again', _joinSetup);
      case JoinOutcome.failed:
        _show("This phone couldn't join the box's setup Wi-Fi. Check its light is blinking once a second.", 'Try again', _joinSetup);
    }
  }

  Future<void> _configure() async {
    _show('Setting up the box…');
    final group = widget.group, keys = group == null ? null : await GroupKeys.derive(group.secret);
    final box = await _setup.configure(groupTag: keys?.tag, channel: keys?.channel);
    if (box == null) {
      _show("The box didn't answer. Check its light is blinking once a second and that this phone is on its "
          'Vroo-setup- Wi-Fi.', 'Try again', _configure);
      return;
    }
    await BoxStore().save(box);
    _box = box;
    _show('Box ${box.ssid} is ready. Its Wi-Fi password is ${box.password}', 'Next', _joinBox);
  }

  Future<void> _joinBox() async {
    final box = _box!;
    _show('Joining ${box.ssid}…');
    switch (await widget.net.joinBox(ssid: box.ssid, password: box.password)) {
      case JoinOutcome.joined:
        await _waitForBox();
      case JoinOutcome.needsManualJoin:
        _show('Open Settings → Wi-Fi, tap ${box.ssid}, paste the password, then come back.', "I'm on it", _waitForBox);
      case JoinOutcome.denied:
        _show('Wi-Fi permission is needed to reach the box. Allow it and try again.', 'Try again', _joinBox);
      case JoinOutcome.failed:
        _show("This phone couldn't join ${box.ssid}. Give the box a few seconds to restart.", 'Try again', _joinBox);
    }
  }

  Future<void> _waitForBox() async {
    _show('Looking for the box…');
    if (await _setup.ping()) {
      _show('Done: ${_box!.ssid} is set up.', 'Back', () async => Navigator.of(context).pop());
    } else {
      _show("The box didn't answer. Check this phone is on ${_box!.ssid}.", 'Try again', _waitForBox);
    }
  }

  Future<void> _run(Future<void> Function() step) async {
    setState(() => _busy = true);
    try {
      await step();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final box = _box, next = _next, onNext = _onNext;
    return Scaffold(
      appBar: AppBar(title: const Text('Set up a box')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_text, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 24),
          if (box != null)
            OutlinedButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: box.password)),
              icon: const Icon(Icons.copy),
              label: const Text('Copy password'),
            ),
          const SizedBox(height: 8),
          if (_busy) const Center(child: CircularProgressIndicator()),
          if (!_busy && next != null && onNext != null) FilledButton(onPressed: () => _run(onNext), child: Text(next)),
        ]),
      ),
    );
  }
}
