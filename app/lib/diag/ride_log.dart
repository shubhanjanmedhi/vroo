// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'clock.dart';

/// The diagnostics log for one ride (architecture §8). Each line is
/// `<UTC time>,<seconds since the log started>,<kind>,<key=value ...>`. In values, `%`, space, comma, CR and LF
/// are percent-encoded, so a value can't split a line and `Uri.decodeComponent` gives it back exactly.
class RideLog {
  RideLog(this._sink, this._clock) : _startMs = _clock.nowMs();

  final StringSink _sink;
  final Clock _clock;
  final int _startMs;

  void write(String kind, Map<String, Object?> fields) {
    final seconds = ((_clock.nowMs() - _startMs) / 1000).toStringAsFixed(1);
    final values = fields.entries.map((e) => '${e.key}=${_escape('${e.value}')}').join(' ');
    _sink.write('${_clock.wallNow().toUtc().toIso8601String()},$seconds,$kind,$values\n');
  }

  /// Flushes and closes the sink when it's a file.
  Future<void> close() async {
    final sink = _sink;
    if (sink is IOSink) {
      await sink.flush();
      await sink.close();
    }
  }

  static String _escape(String v) => v
      .replaceAll('%', '%25')
      .replaceAll(' ', '%20')
      .replaceAll(',', '%2C')
      .replaceAll('\r', '%0D')
      .replaceAll('\n', '%0A');
}
