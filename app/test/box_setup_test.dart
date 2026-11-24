// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/net/box_setup.dart';
import 'package:vroo_net/vroo_net.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

BoxStatus status({required bool setupMode}) => BoxStatus(
    boxId: 0x00A1B2C3, fwVersion: 1, uptimeS: 1, setupMode: setupMode, phones: 1,
    rxFromPhones: 0, txToPhones: 0, dropDup: 0, dropTag: 0);

void main() {
  late GroupKeys keys;
  setUpAll(() async => keys = await GroupKeys.derive(Uint8List.fromList(List.generate(32, (i) => i))));

  test('configure sets a fresh password and returns the box', () => fakeAsync((fa) {
        final net = FakeVrooNet();
        SavedBox? box;
        BoxSetup(net: net, random: Random(3)).configure(groupTag: keys.tag, channel: 11).then((b) => box = b);
        fa.flushMicrotasks();
        final (port, data) = net.sentToBox.single;
        expect(port, boxControlPort);
        final cfg = decodeBoxConfig(data)!;
        expect(cfg.wifiPassword, matches(RegExp(r'^[a-hjkmnp-z2-9]{4}(-[a-hjkmnp-z2-9]{4}){3}$')));
        expect([cfg.groupTag, cfg.channel], [keys.tag, 11]);
        net.emit(BoxDatagram(boxControlPort, encodeBoxStatus(status(setupMode: true))));
        fa.flushMicrotasks();
        expect([box!.ssid, box!.password], ['Vroo-A1B2C3', cfg.wifiPassword]);
      }));
  test('configure gives up after 5 s without an answer', () => fakeAsync((fa) {
        final net = FakeVrooNet();
        var done = false;
        SavedBox? box;
        BoxSetup(net: net, random: Random(3)).configure().then((b) {
          box = b;
          done = true;
        });
        fa.elapse(const Duration(seconds: 6));
        expect(done, isTrue);
        expect(box, isNull);
      }));
  test('assignGroup sends only tag and channel', () => fakeAsync((fa) {
        final net = FakeVrooNet();
        BoxSetup(net: net, random: Random(3)).assignGroup(keys.tag, 11);
        fa.flushMicrotasks();
        final cfg = decodeBoxConfig(net.sentToBox.single.$2)!;
        expect([cfg.groupTag, cfg.channel, cfg.wifiPassword], [keys.tag, 11, null]);
      }));
  test('ping registers with the box and waits for its normal-mode status', () => fakeAsync((fa) {
        final net = FakeVrooNet();
        bool? ok;
        BoxSetup(net: net, random: Random(3)).ping().then((v) => ok = v);
        fa.flushMicrotasks();
        final (port, data) = net.sentToBox.single;
        expect(port, boxControlPort);
        expect(data, encodeBoxConfig(const BoxConfig())); // an empty BOX_CONFIG changes nothing
        net.emit(BoxDatagram(boxControlPort, encodeBoxStatus(status(setupMode: true)))); // not the configured box yet
        fa.flushMicrotasks();
        expect(ok, isNull);
        net.emit(BoxDatagram(boxControlPort, encodeBoxStatus(status(setupMode: false))));
        fa.flushMicrotasks();
        expect(ok, isTrue);
      }));
}
