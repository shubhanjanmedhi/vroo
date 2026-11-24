// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'constants.dart';

/// groupTag ‖ packet: how a packet travels on every path except Bluetooth (architecture §5.2).
Uint8List wrapEnvelope(Uint8List groupTag, Uint8List packet) => Uint8List.fromList([...groupTag, ...packet]);

/// The tag and packet in [datagram], or null if it's too short to hold a sealed packet.
({Uint8List groupTag, Uint8List packet})? unwrapEnvelope(Uint8List datagram) =>
    datagram.length < groupTagSize + headerSize + aeadTagSize
        ? null
        : (groupTag: datagram.sublist(0, groupTagSize), packet: datagram.sublist(groupTagSize));
