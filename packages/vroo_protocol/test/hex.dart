// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

/// Lower-case hex of [bytes], for comparing against hand-written vectors.
String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Parses a hex string such as `0e8d…` into bytes.
Uint8List unhex(String s) =>
    Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
