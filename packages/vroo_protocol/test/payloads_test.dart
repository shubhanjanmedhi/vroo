// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vroo_protocol/vroo_protocol.dart';

import 'hex.dart';

void main() {
  test('beat payload layout', () {
    const b = Beat(platform: 1, flags: BeatFlags.hasInternet | BeatFlags.hasBox, battery: 77, sentAtMs: 123456, btNeighbors: [], name: 'Ravi');
    expect(hex(encodeBeat(b)), '010c4d0001e240000452617669');
    expect(decodeBeat(encodeBeat(b)), b);
  });
  test('long names are cut to 32 bytes on a character boundary', () {
    final b = Beat(platform: 0, flags: 0, battery: 255, sentAtMs: 0, btNeighbors: const [], name: 'é' * 20);
    expect(utf8.encode(decodeBeat(encodeBeat(b))!.name).length, 32);
  });
  test('diagnostics fields travel only with the diagnostics flag', () {
    final withGps = decodeBeat(encodeBeat(const Beat(platform: 0, flags: BeatFlags.diagnostics, battery: 50, sentAtMs: 1, btNeighbors: [7], name: 'A', lat: 12.5, lon: 77.25, accuracyM: 9)))!;
    expect([withGps.lat, withGps.lon, withGps.accuracyM, withGps.btNeighbors], [12.5, 77.25, 9, [7]]);
    final without = decodeBeat(encodeBeat(const Beat(platform: 0, flags: 0, battery: 50, sentAtMs: 1, btNeighbors: [], name: 'A', lat: 12.5, lon: 77.25, accuracyM: 9)))!;
    expect(without.lat, isNull);
  });
  test('a diagnostics beat before the first GPS fix carries no position', () {
    final b = decodeBeat(encodeBeat(const Beat(platform: 0, flags: BeatFlags.diagnostics, battery: 50, sentAtMs: 1, btNeighbors: [], name: 'A')))!;
    expect([b.lat, b.lon, b.accuracyM], [null, null, null]);
  });
  test('truncated payloads are rejected', () {
    expect(decodeBeat(unhex('010c4d')), isNull);
    expect(decodeBeat(unhex('010c4d0001e24001')), isNull); // one neighbour promised, none sent
    expect(decodeBeat(unhex('010c4d0001e2400004526176')), isNull); // name cut short
    final gps = encodeBeat(const Beat(platform: 0, flags: BeatFlags.diagnostics, battery: 50, sentAtMs: 1, btNeighbors: [], name: 'A', lat: 1, lon: 2, accuracyM: 3));
    expect(decodeBeat(gps.sublist(0, gps.length - 1)), isNull); // GPS fields cut short
    expect(decodeEcho(unhex('0102')), isNull);
    expect(decodeHello(unhex('00')), isNull);
    expect(decodeVoice(unhex('000000')), isNull);
  });
  test('echo, hello and voice layouts', () {
    expect(hex(encodeEcho(const Echo(target: 0x01020304, sentAtMs: 123456))), '010203040001e240');
    expect(hex(encodeHello(const Hello(platform: 0, name: 'Ravi'))), '000452617669');
    expect(hex(encodeVoice(VoiceFrame(frameNo: 5, opus: Uint8List.fromList([0xAA, 0xBB])))), '00000005aabb');
  });
}
