// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:vroo_audio/vroo_audio.dart';
import 'package:vroo_net/vroo_net.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import '../box/box_store.dart';
import '../group/group_store.dart';
import '../net/box_setup.dart';
import '../net/group_link.dart';
import '../net/relay_address.dart';
import '../rider_store.dart';
import 'box_setup_screen.dart';
import 'group_screen.dart';
import 'ride_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.net, required this.audio});

  final VrooNet net;
  final VrooAudio audio;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _name = TextEditingController(), _relay = TextEditingController();
  SavedBox? _box;
  Invite? _group;
  BoxMode _mode = BoxMode.boxAndData;

  @override
  void initState() {
    super.initState();
    final store = RiderStore();
    store.name().then((n) => _name.text = n);
    store.relayServer().then((r) => setState(() => _relay.text = r));
    store.boxMode().then((m) => setState(() => _mode = m));
    _reload();
  }

  Future<void> _reload() async {
    final box = await BoxStore().load(), group = await GroupStore().load();
    if (!mounted) return;
    setState(() {
      _box = box;
      _group = group;
    });
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    await _reload();
  }

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _useExistingBox() async {
    final ssid = TextEditingController(text: 'Vroo-'), password = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use a box someone set up'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ssid, decoration: const InputDecoration(labelText: 'Box name, like Vroo-A1B2C3')),
          TextField(controller: password, decoration: const InputDecoration(labelText: 'Its Wi-Fi password')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    final name = ssid.text.trim().toUpperCase().replaceFirst('VROO-', 'Vroo-');
    final id = RegExp(r'^Vroo-([0-9A-F]{6})$').firstMatch(name)?.group(1);
    if (id == null || !isBoxPassword(password.text)) {
      _say('That needs a box name like Vroo-A1B2C3 and its Wi-Fi password: 8 to 63 letters, numbers or symbols, '
          'with no accents or emoji.');
      return;
    }
    await BoxStore().save(SavedBox(boxId: int.parse(id, radix: 16), ssid: name, password: password.text));
    await _reload();
  }

  Future<void> _startRide() async {
    final box = _box, group = _group, name = _name.text.trim();
    if (name.isEmpty || group == null) {
      _say('Type your name, and start or join a group first.');
      return;
    }
    if (box == null && parseRelayAddress(_relay.text) == null) {
      _say('Set up a box, or type a relay server for mobile data, so the group can hear you.'); // no path at all
      return;
    }
    final riderId = await RiderStore().id();
    await _open(RideScreen(
        net: widget.net, audio: widget.audio, box: box, group: group, riderId: riderId, riderName: name));
  }

  @override
  Widget build(BuildContext context) {
    final box = _box, group = _group;
    return Scaffold(
      appBar: AppBar(title: const Text('Vroo'), actions: [
        IconButton(
          tooltip: 'Licences',
          icon: const Icon(Icons.info_outline),
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'Vroo',
            // The GPL's "appropriate legal notices" for an interactive program (D34).
            applicationLegalese: 'Copyright © 2026 Shubhanjan Medhi. Vroo is free software under the GNU GPL, '
                'version 3 or later, with no warranty.',
          ),
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Your name'),
          onChanged: RiderStore().saveName,
        ),
        _Section('My box', box == null ? 'No box yet.' : 'Box ${box.ssid}', [
          FilledButton(onPressed: () => _open(BoxSetupScreen(net: widget.net, group: group)), child: const Text('Set up a box')),
          OutlinedButton(onPressed: _useExistingBox, child: const Text('Use a box someone set up')),
          if (box != null)
            TextButton(
              onPressed: () async {
                await BoxStore().clear();
                await _reload();
              },
              child: const Text('Forget box'),
            ),
        ]),
        if (box != null)
          _Section('Mode', 'Use the box together with mobile data, or the box alone.', [
            SegmentedButton<BoxMode>(
              segments: const [
                ButtonSegment(value: BoxMode.boxAndData, label: Text('Box + data')),
                ButtonSegment(value: BoxMode.boxOnly, label: Text('Box only')),
              ],
              selected: {_mode},
              onSelectionChanged: (picked) {
                setState(() => _mode = picked.first);
                RiderStore().saveBoxMode(picked.first);
              },
            ),
          ]),
        _Section('Group', group == null ? 'No group yet.' : 'Group ${group.name}', [
          FilledButton(onPressed: () => _open(GroupScreen(net: widget.net, mode: GroupMode.start)), child: const Text('Start group')),
          OutlinedButton(onPressed: () => _open(GroupScreen(net: widget.net, mode: GroupMode.join)), child: const Text('Join group')),
          if (group != null)
            TextButton(
              onPressed: () => _open(GroupScreen(net: widget.net, mode: GroupMode.show, group: group)),
              child: const Text('Show its QR code'),
            ),
        ]),
        const SizedBox(height: 24),
        TextField(
          controller: _relay,
          decoration: InputDecoration(
            labelText: 'Relay server (for mobile data)',
            hintText: 'Like 203.0.113.5 or relay.example.org:47100',
            errorText: _relay.text.trim().isEmpty || parseRelayAddress(_relay.text) != null
                ? null
                : 'That needs a server name or address, and a port from 1 to 65535 if not 47100.',
          ),
          onChanged: (text) {
            setState(() {}); // shows or clears the hint
            RiderStore().saveRelayServer(text);
          },
        ),
        const SizedBox(height: 24),
        FilledButton.icon(onPressed: _startRide, icon: const Icon(Icons.play_arrow), label: const Text('Start ride')),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.status, this.actions);

  final String title, status;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(status)),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ]),
      );
}
