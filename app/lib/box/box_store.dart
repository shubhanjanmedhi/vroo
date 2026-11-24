// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../net/box_setup.dart';

/// The box this phone uses, kept on the phone.
class BoxStore {
  static const _key = 'box';

  Future<SavedBox?> load() async {
    final json = (await SharedPreferences.getInstance()).getString(_key);
    if (json == null) return null;
    final m = jsonDecode(json) as Map<String, Object?>;
    return SavedBox(boxId: m['boxId']! as int, ssid: m['ssid']! as String, password: m['password']! as String);
  }

  Future<void> save(SavedBox b) async => (await SharedPreferences.getInstance())
      .setString(_key, jsonEncode({'boxId': b.boxId, 'ssid': b.ssid, 'password': b.password}));

  Future<void> clear() async => (await SharedPreferences.getInstance()).remove(_key);
}
