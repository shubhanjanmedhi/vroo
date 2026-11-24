// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

/// The group this phone rides with, kept on the phone as its invite link.
class GroupStore {
  static const _key = 'group_invite';

  Future<Invite?> load() async {
    final link = (await SharedPreferences.getInstance()).getString(_key);
    return link == null ? null : decodeInvite(link);
  }

  Future<void> save(Invite i) async => (await SharedPreferences.getInstance()).setString(_key, encodeInvite(i));

  Future<void> clear() async => (await SharedPreferences.getInstance()).remove(_key);
}
