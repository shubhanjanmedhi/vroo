// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'constants.dart';

/// A group invite, as carried by the QR code: the secret and the group's display name (spec 6.3).
class Invite {
  const Invite(this.secret, this.name);

  final Uint8List secret;
  final String name;
}

/// `vroo://join?v=1&s=<base64url secret, unpadded>&n=<name>` (architecture §5.1).
String encodeInvite(Invite i) =>
    'vroo://join?v=$protocolVersion&s=${base64Url.encode(i.secret).replaceAll('=', '')}'
    '&n=${Uri.encodeComponent(i.name)}';

/// The invite in [text], or null unless it's a v1 Vroo invite carrying a 32-byte secret. QR codes and links come from
/// anyone, so nothing in them makes it throw.
Invite? decodeInvite(String text) {
  try {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'vroo' || uri.host != 'join') return null;
    final q = uri.queryParameters; // throws on a percent-escape that isn't UTF-8
    final s = q['s'];
    if (q['v'] != '$protocolVersion' || s == null) return null;
    final secret = base64Url.decode(base64Url.normalize(s));
    return secret.length == secretSize ? Invite(secret, q['n'] ?? '') : null;
  } on FormatException {
    return null;
  }
}
