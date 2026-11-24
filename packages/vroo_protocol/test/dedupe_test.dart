// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:test/test.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

void main() {
  test('a second copy within 10 s is a duplicate', () {
    final d = Dedupe();
    expect(d.firstTime(1, 2, 3, 0), isTrue);
    expect(d.firstTime(1, 2, 3, 9999), isFalse);
  });
  test('a new session is not a duplicate', () {
    final d = Dedupe()..firstTime(1, 2, 3, 0);
    expect(d.firstTime(1, 3, 3, 0), isTrue);
  });
  test('entries expire after the window', () {
    final d = Dedupe()..firstTime(1, 2, 3, 0);
    expect(d.firstTime(1, 2, 3, 10001), isTrue);
  });
  test('old entries are purged', () {
    final d = Dedupe();
    for (var i = 0; i < 1000; i++) {
      d.firstTime(1, 1, i, 0);
    }
    d.firstTime(9, 9, 9, 20000);
    expect(d.size, lessThan(10));
  });
}
