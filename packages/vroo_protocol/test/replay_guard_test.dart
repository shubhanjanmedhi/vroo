// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:test/test.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

PacketHeader _h(int type, int seq) => PacketHeader(version: 1, type: type, ttl: 16, src: 1, session: 2, seq: seq);
PacketHeader beat(int seq) => _h(PacketType.beat, seq);
PacketHeader voice(int seq) => _h(PacketType.voice, seq);
PacketHeader echo(int seq) => _h(PacketType.echo, seq);
PacketHeader fill(int seq) => _h(PacketType.fill, seq);

const wall = 1760000000000;

void main() {
  test('a new packet is accepted once, and a copy is a duplicate', () {
    final g = ReplayGuard();
    expect(g.check(beat(0), nowMs: 0, wallMs: wall, beatSentAtMs: wall), ReplayVerdict.accepted);
    expect(g.check(beat(0), nowMs: 1, wallMs: wall, beatSentAtMs: wall), ReplayVerdict.duplicate);
  });

  test('a packet 1024 or more behind the newest is too old', () {
    final g = ReplayGuard()..check(beat(5000), nowMs: 0, wallMs: wall, beatSentAtMs: wall);
    expect(g.check(fill(3976), nowMs: 1, wallMs: wall), ReplayVerdict.tooOld);
    expect(g.check(fill(3977), nowMs: 1, wallMs: wall), ReplayVerdict.accepted);
  });

  test('voice from a session with no heartbeat yet is refused', () {
    final g = ReplayGuard();
    expect(g.check(voice(1), nowMs: 0, wallMs: wall), ReplayVerdict.noRecentBeat);
    g.check(beat(2), nowMs: 10, wallMs: wall, beatSentAtMs: wall);
    expect(g.check(voice(3), nowMs: 20, wallMs: wall), ReplayVerdict.accepted);
  });

  test("voice stops counting 40 s after the session's last heartbeat", () {
    final g = ReplayGuard()..check(beat(0), nowMs: 0, wallMs: wall, beatSentAtMs: wall);
    expect(g.check(voice(1), nowMs: 40000, wallMs: wall), ReplayVerdict.accepted);
    expect(g.check(voice(2), nowMs: 40001, wallMs: wall), ReplayVerdict.noRecentBeat);
  });

  test('a heartbeat whose clock is more than 10 minutes off is stale', () {
    final g = ReplayGuard();
    expect(g.check(beat(0), nowMs: 0, wallMs: wall, beatSentAtMs: wall - 600001), ReplayVerdict.staleBeat);
    expect(g.check(beat(1), nowMs: 0, wallMs: wall, beatSentAtMs: wall + 600001), ReplayVerdict.staleBeat);
    expect(g.check(beat(2), nowMs: 0, wallMs: wall, beatSentAtMs: wall - 600000), ReplayVerdict.accepted);
  });

  test('the clock check works across the u32 wrap', () {
    final g = ReplayGuard();
    expect(g.check(beat(0), nowMs: 0, wallMs: (1 << 32) + 5, beatSentAtMs: 0xFFFFFFFB), ReplayVerdict.accepted);
  });

  test('echoes follow the voice rule, and fill needs only the window', () {
    final g = ReplayGuard();
    expect(g.check(echo(1), nowMs: 0, wallMs: wall), ReplayVerdict.noRecentBeat);
    expect(g.check(fill(2), nowMs: 0, wallMs: wall), ReplayVerdict.accepted);
  });

  test('a session replayed after it was forgotten fails the clock check', () {
    final g = ReplayGuard()..check(beat(0), nowMs: 0, wallMs: wall, beatSentAtMs: wall);
    expect(g.check(beat(0), nowMs: 600001, wallMs: wall + 600001, beatSentAtMs: wall), ReplayVerdict.staleBeat);
  });
}
