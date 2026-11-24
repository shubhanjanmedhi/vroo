// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/diag/clock.dart';
import 'package:vroo/diag/ride_log.dart';

void main() {
  test('log line format', () async {
    final clock = FakeClock(ms: 0, wall: DateTime.utc(2026, 10, 27, 10));
    final buf = StringBuffer();
    final log = RideLog(buf, clock);
    clock.ms = 12340;
    log.write('box', {'state': 'up', 'name': 'Ravi K', 'note': 'a,b'});
    expect(buf.toString(), '2026-10-27T10:00:00.000Z,12.3,box,state=up name=Ravi%20K note=a%2Cb\n');
  });
  test('a value cannot break the line', () {
    final buf = StringBuffer();
    RideLog(buf, FakeClock(ms: 0, wall: DateTime.utc(2026, 10, 27, 10))).write('peer', {'name': 'a\nb%c'});
    expect(buf.toString(), endsWith(',peer,name=a%0Ab%25c\n'));
  });
}
