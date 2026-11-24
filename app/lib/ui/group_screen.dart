// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:vroo_net/vroo_net.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import '../box/box_store.dart';
import '../group/group_store.dart';
import '../net/box_setup.dart';

enum GroupMode { start, join, show }

/// Start a group (a new secret, shown as a QR code), join one by scanning its QR code, or show the current one.
/// A saved group goes to this phone's box too.
class GroupScreen extends StatefulWidget {
  const GroupScreen({super.key, required this.net, required this.mode, this.group});

  final VrooNet net;
  final GroupMode mode;
  final Invite? group;

  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> {
  final _name = TextEditingController(text: 'Sunday ride');
  late Invite? _group = widget.group;
  String? _boxNote;

  Future<void> _save(Invite invite) async {
    await GroupStore().save(invite);
    setState(() => _group = invite);
    await _sendToBox(invite);
  }

  Future<void> _sendToBox(Invite invite) async {
    final box = await BoxStore().load();
    if (box == null) return;
    setState(() => _boxNote = 'Sending the group to ${box.ssid}…');
    final keys = await GroupKeys.derive(invite.secret);
    final ok = await BoxSetup(net: widget.net, random: Random.secure()).assignGroup(keys.tag, keys.channel);
    if (mounted) {
      setState(() => _boxNote = ok
          ? '${box.ssid} now carries this group.'
          : "Couldn't reach ${box.ssid}. Be on its Wi-Fi and tap Send to my box.");
    }
  }

  void _scanned(Code code) {
    if (_group != null) return; // one is saved already; the camera keeps reporting
    final invite = decodeInvite(code.text ?? '');
    if (invite == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text("That isn't a ride QR code.")));
      return;
    }
    _save(invite);
  }

  @override
  Widget build(BuildContext context) {
    final group = _group;
    return Scaffold(
      appBar: AppBar(title: Text(widget.mode == GroupMode.join ? 'Join group' : 'Group')),
      body: group != null
          ? _shown(group)
          : widget.mode == GroupMode.join
              ? ReaderWidget(onScan: _scanned)
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    TextField(controller: _name, decoration: const InputDecoration(labelText: 'Group name')),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () {
                        final rnd = Random.secure();
                        _save(Invite(Uint8List.fromList(List.generate(secretSize, (_) => rnd.nextInt(256))), _name.text.trim()));
                      },
                      child: const Text('Start group'),
                    ),
                  ]),
                ),
    );
  }

  Widget _shown(Invite group) => ListView(padding: const EdgeInsets.all(16), children: [
        Text('Group ${group.name}', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        const Text('Riders join by scanning this code with Join group.', textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Center(child: QrImageView(data: encodeInvite(group), size: 260, backgroundColor: Colors.white)),
        if (_boxNote != null) ...[
          const SizedBox(height: 16),
          Text(_boxNote!, textAlign: TextAlign.center),
        ],
        const SizedBox(height: 8),
        TextButton(onPressed: () => _sendToBox(group), child: const Text('Send to my box')),
      ]);
}
