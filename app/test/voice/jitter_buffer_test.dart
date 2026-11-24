// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vroo/voice/jitter_buffer.dart';

/// Each test frame's Opus data is just its frame number, so playouts read as P0 (play 0), R4 (rebuild from 4),
/// C (conceal) and - (quiet).
void putAll(JitterBuffer b, Iterable<int> frameNos) {
  for (final n in frameNos) {
    b.put(n, Uint8List.fromList([n]));
  }
}

String nextOf(JitterBuffer b) => switch (b.next()) {
      PlayFrame(:final opus) => 'P${opus[0]}',
      RecoverFrame(:final nextOpus) => 'R${nextOpus[0]}',
      ConcealFrame() => 'C',
      null => '-',
    };

List<String> take(JitterBuffer b, int n) => [for (var k = 0; k < n; k++) nextOf(b)];

void main() {
  test('waits for 60 ms before playing', () {
    final b = JitterBuffer();
    putAll(b, [0, 1]);
    expect(nextOf(b), '-');
    putAll(b, [2]);
    expect(nextOf(b), 'P0');
  });

  test('plays frames in order when they arrive out of order', () {
    final b = JitterBuffer();
    putAll(b, [2, 0, 1, 3]);
    expect(take(b, 4), ['P0', 'P1', 'P2', 'P3']);
  });

  test("rebuilds one lost frame from the next frame's FEC", () {
    final b = JitterBuffer();
    putAll(b, [0, 1, 2, 4, 5]);
    expect(take(b, 6), ['P0', 'P1', 'P2', 'R4', 'P4', 'P5']);
  });

  test('conceals a burst loss', () {
    final b = JitterBuffer();
    putAll(b, [0, 1, 2, 5, 6]);
    expect(take(b, 7), ['P0', 'P1', 'P2', 'C', 'R5', 'P5', 'P6']);
  });

  test('goes quiet after the talker stops', () {
    final b = JitterBuffer();
    putAll(b, [0, 1, 2]);
    expect(take(b, 7), ['P0', 'P1', 'P2', 'C', 'C', '-', '-']);
    expect(b.depth, 0);
  });

  test('a late frame is dropped', () {
    final b = JitterBuffer();
    putAll(b, [0, 1, 2]);
    take(b, 3);
    putAll(b, [1]);
    expect(b.late, 1);
    expect(take(b, 4), isNot(contains('P1')));
  });

  test('a frame from before the talker went quiet is still late', () {
    final b = JitterBuffer();
    putAll(b, [0, 1, 2]);
    take(b, 6); // plays 0..2, conceals 3 and 4, goes quiet
    putAll(b, [4, 5, 6, 7]);
    expect(b.late, 1);
    expect(take(b, 3), ['P5', 'P6', 'P7']);
  });

  test('never holds more than 300 ms', () {
    final b = JitterBuffer();
    var deepest = 0;
    for (var n = 0; n < 20; n++) {
      putAll(b, [n]);
      if (b.depth > deepest) deepest = b.depth;
    }
    expect(nextOf(b), 'P13');
    expect(b.skipped, 13);
    expect(deepest, lessThanOrEqualTo(15));
  });

  test('skips ahead by frame number, so scattered frames cannot hold the delay up', () {
    final b = JitterBuffer();
    putAll(b, [0, 1, 2]);
    take(b, 1); // playing, frame 1 due
    putAll(b, [30]); // a burst far ahead, with nothing in between
    expect(take(b, 1), ['C']); // 28 is due: concealed, then 29 rebuilt from 30
    expect(take(b, 2), ['R30', 'P30']);
  });

  test('counts what it did', () {
    final b = JitterBuffer();
    putAll(b, [0, 1, 2, 5, 6]);
    take(b, 7);
    expect([b.played, b.recovered, b.concealed], [5, 1, 1]);
  });

  test('a duplicate frame is ignored', () {
    final b = JitterBuffer();
    putAll(b, [0, 0, 1, 2]);
    expect(b.depth, 3);
  });

  test('counts real losses, not the tail after a talker stops', () {
    final b = JitterBuffer();
    putAll(b, [0, 1, 2, 4, 5]);
    expect(take(b, 8), ['P0', 'P1', 'P2', 'R4', 'P4', 'P5', 'C', 'C']);
    expect([b.lost, b.concealed], [1, 2]); // frame 3 was lost; the two conceals are the tail
  });
}
