// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'net/group_link.dart';

/// This install's rider: a random u32 rider ID made once (architecture §5.2), the name the rider typed, and their
/// settings.
class RiderStore {
  static const _idKey = 'rider_id', _nameKey = 'rider_name', _micKey = 'mic_sensitivity_db';
  static const _relayKey = 'relay_server', _modeKey = 'box_mode';

  Future<int> id() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_idKey);
    if (saved != null) return saved;
    final id = Random.secure().nextInt(1 << 32);
    await prefs.setInt(_idKey, id);
    return id;
  }

  Future<String> name() async => (await SharedPreferences.getInstance()).getString(_nameKey) ?? '';

  Future<void> saveName(String name) async => (await SharedPreferences.getInstance()).setString(_nameKey, name);

  /// The voice gate's threshold above the noise, in dB (VO1): 12 unless the rider moved the slider.
  Future<double> micSensitivityDb() async => (await SharedPreferences.getInstance()).getDouble(_micKey) ?? 12;

  Future<void> saveMicSensitivityDb(double db) async => (await SharedPreferences.getInstance()).setDouble(_micKey, db);

  /// The relay server as the rider typed it (D26); empty for none.
  Future<String> relayServer() async => (await SharedPreferences.getInstance()).getString(_relayKey) ?? '';

  Future<void> saveRelayServer(String text) async =>
      (await SharedPreferences.getInstance()).setString(_relayKey, text.trim());

  /// Box + data unless the rider picked Box only (spec G10).
  Future<BoxMode> boxMode() async =>
      BoxMode.values.asNameMap()[(await SharedPreferences.getInstance()).getString(_modeKey)] ?? BoxMode.boxAndData;

  Future<void> saveBoxMode(BoxMode mode) async => (await SharedPreferences.getInstance()).setString(_modeKey, mode.name);
}
