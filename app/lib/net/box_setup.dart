// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:vroo_net/vroo_net.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

const _answerTimeout = Duration(seconds: 5);

/// A box this phone can join: its hotspot name and password.
class SavedBox {
  const SavedBox({required this.boxId, required this.ssid, required this.password});

  final int boxId;
  final String ssid;
  final String password;
}

/// Talks BOX_CONFIG to the box on its control port and waits for its BOX_STATUS answer.
class BoxSetup {
  BoxSetup({required this.net, required this.random});

  final VrooNet net;

  /// Makes the hotspot password: pass `Random.secure()` outside tests.
  final Random random;

  /// On the setup Wi-Fi: gives the box a fresh password, and the group's tag and channel if there's a group.
  /// Null if no setup-mode status comes back within 5 s.
  Future<SavedBox?> configure({Uint8List? groupTag, int? channel}) async {
    final password = newBoxPassword(random);
    final status = await _send(BoxConfig(groupTag: groupTag, channel: channel, wifiPassword: password), setupMode: true);
    return status == null ? null : SavedBox(boxId: status.boxId, ssid: boxSsid(status.boxId), password: password);
  }

  /// On the box's normal Wi-Fi: moves the box to a group. True when it answers within 5 s.
  Future<bool> assignGroup(Uint8List groupTag, int channel) async =>
      await _send(BoxConfig(groupTag: groupTag, channel: channel), setupMode: false) != null;

  /// On the box's normal Wi-Fi: makes the box hear this phone (an empty BOX_CONFIG changes nothing).
  /// True when its status comes back within 5 s.
  Future<bool> ping() async => await _send(const BoxConfig(), setupMode: false) != null;

  Future<BoxStatus?> _send(BoxConfig config, {required bool setupMode}) async {
    final answer = Completer<BoxStatus?>();
    final sub = net.events.listen((e) {
      if (e is! BoxDatagram || e.fromPort != boxControlPort || answer.isCompleted) return;
      final status = decodeBoxStatus(e.data);
      if (status != null && status.setupMode == setupMode) answer.complete(status);
    });
    try {
      await net.sendToBox(encodeBoxConfig(config), port: boxControlPort);
      return await answer.future.timeout(_answerTimeout, onTimeout: () => null);
    } finally {
      unawaited(sub.cancel());
    }
  }
}
