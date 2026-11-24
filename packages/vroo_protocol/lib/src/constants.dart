// SPDX-License-Identifier: GPL-3.0-or-later

/// Protocol v1 numbers shared by the app, the relay server and (as C constants) the box firmware.
const int protocolVersion = 1;
const int headerSize = 15, aeadTagSize = 16, groupTagSize = 8, secretSize = 32;
const int originTtl = 16, dedupeWindowMs = 10000;
const String boxIp = '192.168.4.1';
const int boxDataPort = 47000, boxControlPort = 47001;

abstract final class PacketType {
  static const hello = 1, voice = 2, beat = 3, echo = 4, fill = 5;
}

abstract final class BoxMsgType {
  static const config = 0x10, status = 0x11;
}
