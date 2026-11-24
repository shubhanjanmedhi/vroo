// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vroo/box/box_store.dart';
import 'package:vroo/group/group_store.dart';
import 'package:vroo/net/box_setup.dart';
import 'package:vroo/rider_store.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

void main() {
  final secret = Uint8List.fromList(List.generate(32, (i) => i));

  test('stores keep the group and the box', () async {
    SharedPreferences.setMockInitialValues({});
    await GroupStore().save(Invite(secret, 'Sunday ride'));
    expect((await GroupStore().load())!.name, 'Sunday ride');
    await BoxStore().save(const SavedBox(boxId: 0x00A1B2C3, ssid: 'Vroo-A1B2C3', password: 'abcd-efgh-jkmn-pqrs'));
    expect((await BoxStore().load())!.ssid, 'Vroo-A1B2C3');
  });
  test('the rider ID is made once and kept', () async {
    SharedPreferences.setMockInitialValues({});
    final id = await RiderStore().id();
    expect(id, inInclusiveRange(0, 0xFFFFFFFF));
    expect(await RiderStore().id(), id);
    await RiderStore().saveName('Ravi');
    expect(await RiderStore().name(), 'Ravi');
  });
}
