// SPDX-License-Identifier: GPL-3.0-or-later
import '../net/box_connection.dart';

/// What the rider should do about the link to their box, or null when nothing's needed.
String? boxHint(BoxConnectionState state,
        {required bool boxUp, required String ssid, required String password, required bool iOS}) =>
    switch (state) {
      BoxConnectionState.idle => null,
      BoxConnectionState.joined when boxUp => null,
      BoxConnectionState.joined => 'On $ssid, waiting for the box. If this lasts, check its light is on'
          '${iOS ? ', and that Settings → Privacy & Security → Local Network allows Vroo' : ''}.',
      BoxConnectionState.joining => iOS ? 'Waiting for $ssid…' : 'Joining $ssid… If Android asks, tap Connect.',
      BoxConnectionState.needsManualJoin => 'Open Settings → Wi-Fi, tap $ssid (password $password), then come back.',
      BoxConnectionState.denied => "This phone couldn't join $ssid. Check the box is on and nearby, and that Vroo "
          'may use Wi-Fi, then tap Stop and start again.',
    };
