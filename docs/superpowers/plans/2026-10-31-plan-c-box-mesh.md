# Plan C: Box Mesh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Riders on different bikes talk with no mobile signal: each phone talks to its own box, and the boxes pass the group's voice to each other over ESP-NOW long range, relaying down a line of bikes. Around that: a simulator that sizes the mesh for 100 riders, a web page that loads the box software, field-test diagnostics, and field tests FT1 to FT5.

**Architecture:**
- **`vroo_protocol` is the reference for every new box rule:** the box beacon, the extended box config and status, the relay rule, the talker cap and the scaled timers. The firmware's C mirrors them and is held to them by test vectors and shared scenarios. `vroo_protocol` also gains `ReplayGuard`, which lets phones refuse replayed packets now that strangers can hear the boxes.
- **`vroo_wire` (C, no ESP-IDF) holds all of the box's decisions:** for each frame from a phone or from the air, it says whether to hand it to the phones, broadcast it, or drop it, and with which ttl. Host tests cover it.
- **The firmware becomes thin glue:**
  - The hotspot stays ordinary 802.11b/g/n for the phones.
  - The station interface adds Espressif's long-range (LR) mode and sends ESP-NOW broadcasts on the hotspot's channel.
  - One task handles the sockets and a queue of received ESP-NOW frames, woken by an eventfd.
- **`sim/` is a Dart command-line simulator.** It runs `vroo_protocol`'s rules for 5 to 200 boxes over a model of one shared Wi-Fi channel. That includes each box's Wi-Fi traffic to its own phones, which shares the channel too.
- **The app shows the mesh:** box neighbours and signal, a diagnostics switch with the box's radio speed, GPS distance between riders, and "pretend extra talkers".

**Tech Stack:**
- ESP-IDF v5.5.6 (C99): `esp_now`, `esp_wifi` in AP+STA mode, `esp_vfs_eventfd`.
- Dart 3.13 for `vroo_protocol` and `sim/`, with no new dependencies.
- Flutter 3.47. New package: `geolocator` 14.x (MIT), for diagnostics GPS only.
- ESP Web Tools 10.4.0 (Apache-2.0), loaded by the flashing page from unpkg.

**Spec:**
- [docs/spec.md](../../spec.md): §6.2, §6.4, GR4, VO7, CO2, CO8, BX1–BX8, PS1, PS3, DG1–DG3, §8, and §10 (U1, U2, U3, U8, U11).
- [docs/architecture.md](../../architecture.md): §4.8, §4.10, §5.2–5.4 and §8.
- [docs/hardware.md](../../hardware.md), and test-plan FT1 to FT5.
- Decisions D15–D18, D21 and D31.

**Order changed (D33, 2026-11-18):** Plan E (mobile data) runs first. It does this plan's Task 1 (replay protection) and defines `TalkerCap`, which Task 2 then uses instead of defining it. By then `BoxLink` is called `GroupLink`.

**Where this sits:** M1, Plan C ([docs/todo.md](../../todo.md)), on top of Plan A's box link and Plan B's voice. Not in this plan:

- the internet path, the relay server and the path policy (M2), and Bluetooth (Plan D)
- packet packing on the boxes (architecture §4.8's airtime fallback): only if FT2 or the simulator calls for it
- scaling the phones' heartbeat interval with group size: the simulator checks the formula, and the app keeps 1 s (groups of up to 10) until M2
- box software updates from the app (v2)

## Global Constraints

- **Plans A and B still apply:**
  - platforms, thin native code, protocol v1, the box, the invite and the ride-log format
  - no paid Apple account, the founder's 👤 checklists, and no personal data in the repository
  - open source with paid licences (D34, which replaced D31's closed source on 2026-11-25): the SPDX line `// SPDX-License-Identifier: GPL-3.0-or-later` on every new file (`AGPL-3.0-or-later` in `server/`), permissive dependencies only, no proprietary SDKs, and `publish_to: none`
  - the founder commits: each task ends with a "Hand over" step listing the changed files and a suggested commit message, and the executor never commits
- **Device steps** (👤) can wait for one of the founder's sessions. The executor does every device-free step of every task first, and runs the device steps in the order the founder's sessions allow.
- **ESP-NOW:**
  - Broadcast to `FF:FF:FF:FF:FF:FF` from the station interface (`WIFI_IF_STA`), on the hotspot's channel (peer channel 0).
  - Unencrypted at the ESP-NOW layer, because packets are sealed already.
  - Frames up to 250 bytes (ESP-NOW v1).
  - Mode AP+STA in normal mode. The station never connects, and setup mode stays AP only, with no ESP-NOW.
- **Protocols:** the station is `11B|11G|11N|LR` and the hotspot stays `11B|11G|11N`. An LR hotspot sends its beacon in LR mode, so phones can't see it (ESP-IDF Wi-Fi guide, "LR Compatibility").
- **Radio speed (a knob):**
  - `0` long range 250 kbps (`WIFI_PHY_MODE_LR`, `WIFI_PHY_RATE_LORA_250K`)
  - `1` long range 500 kbps (`WIFI_PHY_RATE_LORA_500K`)
  - `2` 1 Mbps (`WIFI_PHY_MODE_11B`, `WIFI_PHY_RATE_1M_L`)
  - It's set with `esp_now_set_peer_rate_config` on the broadcast peer. Receivers hear every speed, because the station has LR and 11b on.
  - **Default 1 (500 kbps) until FT1 and FT2.** *Claude's call:* four talkers at 250 kbps would need about 98% of the channel before any relaying. That's about 4.9 ms per 83-byte voice frame including contention, times 200 frames a second.
- **Transmit power:** a knob in quarter-dBm, 8–80 (2–20 dBm). Unset means the Wi-Fi driver's default.
- **Talker cap on the box:**
  - N = 4 (a knob, 1–8).
  - A rider is active while a VOICE or FILL packet of theirs was admitted in the last 1000 ms.
  - A VOICE or FILL packet from anyone else, while N are active, is dropped entirely: not handed to phones and not relayed. It's counted as `drop_cap`.
  - BEAT and ECHO are never capped.
- **ttl:**
  - Phones send 16.
  - The box lowers a phone's packet to its configured ttl (a knob, 1–16, default 16) before sending it on.
  - It relays with ttl − 1, and only while the ttl it heard is above 1.
- **Relay rule (architecture §4.8):** a box relays a new packet heard from box B only if it has a live neighbour, other than B, that B's last beacon didn't list. If B's beacon hasn't been heard, it relays. Packets from its own phones always go out on the air.
- **Timers:**
  - `scaledInterval(count) = clamp(count × 100 ms, 1000 ms, 10000 ms)`, for the box beacon (count = live neighbours), and in the simulator for heartbeats (count = riders).
  - Beacons get ±10% random jitter (*Claude's call*, so neighbours don't stay in step).
  - A neighbour expires 3 × the interval its own beacon states, plus 500 ms.
- **ESP-NOW frames:**
  - Every frame is an envelope: groupTag (8) ‖ body.
  - Body byte 0 is version 1. Body byte 1 is either a packet type (1–5: a sealed packet) or `0x12` (a box beacon).
  - Any other frame, or one with another group's tag, is ignored.
- **Box messages** (unencrypted; integers big-endian):

  | Message | Bytes |
  |---|---|
  | BOX_CONFIG `0x10`, phone → box, control port | version 1, type, mask, then each field whose mask bit is set, in bit order: bit0 groupTag (8), bit1 channel (u8: 1, 6, 11), bit2 password (u8 length 8–63, printable ASCII), **bit3 radio (u8 0–2), bit4 tx power (u8 8–80), bit5 talker cap (u8 1–8), bit6 ttl (u8 1–16)**. Out-of-range values reject the whole message. Bit 7 is ignored |
  | BOX_STATUS `0x11`, box → phones, control port, every second | Bytes 0–29 as in Plan A; firmware 2 appends: 30 rx_from_boxes u32 · 34 tx_to_boxes u32 · 38 relayed u32 · 42 drop_cap u32 · 46 drop_air u32 · 50 radio u8 · 51 tx power u8 · 52 talker cap u8 · 53 ttl u8 · 54 stack free min u16 (bytes) · 56 heap free min u32 (bytes) · 60 neighbours u8 · 61 listed k u8 (0–16) · 62 k × (box ID u32, RSSI i8), strongest first |
  | BOX_BEACON `0x12`, box → boxes, ESP-NOW only, inside the envelope | version 1, type, box ID u32, firmware version u16, interval u8 (tenths of a second, 10–100), neighbours u8, listed k u8 (0–16), k × (box ID u32, RSSI i8), strongest first. At most 99 bytes with the envelope |

  `tx_to_boxes` counts envelopes the box broadcast: its phones' packets plus relays. Beacons aren't counted. `drop_air` counts sends that ESP-NOW refused.
- **Firmware version 2.** A firmware-1 box keeps sending 30-byte statuses, and the app shows those without mesh fields.
- **Replay protection, on phones, after decryption (`ReplayGuard`):**
  - A sequence window of 1024 per (src, session).
  - A session's VOICE and ECHO count only within 40 s of an accepted BEAT from that session (4 × the 10 s longest heartbeat interval). FILL needs only the window.
  - A BEAT counts only if its sentAt is within ±10 minutes of this phone's wall clock.
  - sentAt becomes the sender's wall clock: milliseconds since the Unix epoch, low 32 bits.
  - Sessions are forgotten 10 minutes after their last accepted packet.
- **Box board for new boxes:** a classic ESP32 module with an antenna connector (ESP32-WROOM-32U or -32UE on a USB development board), so one firmware build (target `esp32`) covers the desk board too. Use an approved 2.4 GHz antenna (hardware.md).
- **New dependencies:**
  - `geolocator` ^14.1.2 (MIT) in the app.
  - ESP Web Tools 10.4.0 (Apache-2.0), loaded from `https://unpkg.com/esp-web-tools@10.4.0/dist/web/install-button.js?module`.
  - Nothing else without a decisions.md note.
- **Log lines added:** `box` lines with the mesh fields, `peer_lost`, and `stats` lines for pretend talkers (`peer=fill-…`). Box IDs appear in ride logs only, never in the repository (they're part of a hardware address).

## Review Focus

1. **Another group's boxes nearby, on the same channel.** Their packets and beacons are never delivered or relayed, never counted as neighbours, and never take talker-cap slots. Test: Task 3, "another group's beacon or packet changes nothing".
2. **Packets come back through other boxes, or two boxes relay the same packet.** Each box relays a packet at most once, each phone plays each frame once, and airtime doesn't snowball. Tests: Task 3, "a packet heard back from another box is dropped as a duplicate"; Task 6, "a ring of boxes relays each frame at most once per box".
3. **Bikes spread out and regroup.** A neighbour box vanishes (out of range, or its power is cut) and comes back. It leaves the neighbour list within 3 beacon intervals plus 0.5 s, relaying follows, and the phone's box line shows it. Tests: Task 3, "a neighbour that stops beaconing expires"; the Task 10 bench power cut.
4. **More traffic than the radio carries:** five or more talkers, pretend talkers, or the slow radio. The box drops and counts (`drop_cap`, `drop_air`) instead of stalling, the phones on the box keep working, and stack and heap stay bounded. Tests: Task 3, "the fifth talker is dropped, but heartbeats from more riders get through"; Task 6, "a busy real channel loses some frames but never relays twice"; Task 10 bench step 6, four pretend talkers at 250 kbps, where `drop_air` may rise but the box and its phones keep working, and the status shows the stack and heap.
5. **Strangers on the open radio:**
  - malformed beacons (counts that overrun the frame, more than 16 listed) and oversized frames
  - packets replayed after the 10 s dedupe window
  - a rider whose phone clock is far off

  The box never reads past a frame. Phones refuse replays, and log the stale clock. Tests: Task 3, "a beacon whose counts overrun the frame is ignored"; Task 1's `ReplayGuard` tests and "a packet replayed after the dedupe window is not played".

---

## File structure

```
packages/vroo_protocol/
  lib/src/replay_guard.dart          ReplayGuard, ReplayVerdict                         (Task 1)
  lib/src/box_messages.dart          + BoxRadio, BoxConfig fields, BoxMesh, BoxNeighbour, BoxBeacon (Task 2)
  lib/src/mesh_rules.dart            shouldRelay, scaledIntervalMs, neighbourExpiryMs (Task 2; TalkerCap is Plan E's)
  tool/gen_c_vectors.dart            + beacon, mesh status and radio config vectors       (Task 2)
  tool/box_probe.dart                prints the mesh fields                              (Task 2)
firmware/
  components/vroo_wire/              + vw_mesh_*: decisions for frames from phones and from the air (Task 3)
  host_test/test_vroo_wire.c         + mesh scenarios                                    (Task 3)
  main/mesh.c, mesh.h                ESP-NOW I/O: start, apply, send, take, eventfd      (Task 4)
  main/bridge.c                      glue: sockets + air frames → vw_mesh, beacons, status (Task 4)
  main/wifi_ap.c, config.c, led.c    AP+STA, the new NVS keys, two new light patterns    (Task 4)
  flasher/index.html, manifest.json, build.sh                                            (Task 5)
sim/                                  Dart CLI: airtime, channel, box model, scenarios, report (Task 6)
app/lib/
  net/box_link.dart                  ReplayGuard, wall-clock sentAt, configureBox, ttl, fixes, FILL (Tasks 1, 7–9)
  net/fill.dart                      FillStats, the pretend-talker streams                (Task 9)
  diag/geo.dart, diag/locations.dart distanceM; Fix, Locations, GeolocatorLocations     (Task 8)
  ride/ride_engine.dart, ui/ride_screen.dart, ui/home_screen.dart, rider_store.dart       (Tasks 7–9)
packages/vroo_audio/                 start(location:) for the Android service type        (Task 8)
```

---

### Task 1: Replay protection on phones

**Done in Plan E (Task 1, 2026-11-18).** Nothing left to do here.

**Files:**
- Create: `packages/vroo_protocol/lib/src/replay_guard.dart`, `packages/vroo_protocol/test/replay_guard_test.dart`
- Modify:
  - `packages/vroo_protocol/lib/vroo_protocol.dart` (export)
  - `app/lib/net/box_link.dart`
  - `app/test/box_link_test.dart`, plus test helpers that send VOICE with no BEAT first
  - `docs/architecture.md`: §5.2 (replay protection; box dedupe poisoning under "Limits, by design") and §5.3 (sentAt)

**Interfaces:**
- Consumes: `PacketHeader`, `PacketType` (protocol v1).
- Produces:
  ```dart
  enum ReplayVerdict { accepted, duplicate, tooOld, staleBeat, noRecentBeat }

  /// Replay protection for packets that have already been authenticated (architecture §5.2).
  class ReplayGuard {
    ReplayGuard({this.window = 1024, this.liveMs = 40000, this.skewMs = 600000, this.forgetMs = 600000});
    /// [nowMs] is the monotonic clock; [wallMs] is this phone's wall clock in ms since the epoch;
    /// [beatSentAtMs] is the BEAT's sentAt, required for type BEAT.
    ReplayVerdict check(PacketHeader h, {required int nowMs, required int wallMs, int? beatSentAtMs});
  }
  ```
- In BoxLink:
  - `ReplayGuard` replaces `Dedupe`.
  - A BEAT's `sentAtMs` is `clock.wallNow().millisecondsSinceEpoch`.
  - The echo round trip is `(wallMs − echo.sentAtMs) & 0xFFFFFFFF`.

- [ ] **Step 1: Write the failing guard tests** in `replay_guard_test.dart`. In them, `beat(seq)`, `voice(seq)`, `echo(seq)` and `fill(seq)` build headers for src 1 and session 2, and `wall` is 1 760 000 000 000:

```dart
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
```

The checks run in this order:

1. For a BEAT, the clock: `(wallMs − sentAt)` modulo 2³², read as a signed 32-bit number, must be within ±`skewMs`.
2. The window: the newest seq and the 1023 below it count. Older is `tooOld`, and a repeat is `duplicate`.
3. For VOICE and ECHO, the recent-beat rule.

A refused packet doesn't change the window, so a copy that arrives after the session's beat still counts.

- [ ] **Step 2: Run them.** `cd packages/vroo_protocol && dart test test/replay_guard_test.dart`. Expected: FAIL, `ReplayGuard` isn't defined.

- [ ] **Step 3: Implement `ReplayGuard`** in `replay_guard.dart`, and export it.
  - State per (src, session): the highest seq accepted, a 1024-bit window below it, the time of the last accepted packet, and the time of the last accepted BEAT.
  - Sessions idle for `forgetMs` are purged at most once a second.

- [ ] **Step 4: Run the protocol tests.** `cd packages/vroo_protocol && dart test`. Expected: all pass.

- [ ] **Step 5: Write the failing BoxLink tests** in `app/test/box_link_test.dart`:
  - `a packet replayed after the dedupe window is not played`: FakeBox sends a BEAT and then a VOICE from rider 7. Eleven seconds later (fake time, with heartbeats from rider 7 still arriving) it sends the same VOICE bytes again. Expect `voices` to have emitted one frame.
  - `voice from a rider whose clock is 11 minutes off is not played, and the drop is logged`: the rider's BEAT has sentAt = wall − 660 000, and its VOICE follows. Expect no voice, no peer, and a log line `drop,reason=stale`.
  - `voice from a session with no heartbeat is not played`: a VOICE with no BEAT. Expect no voice, and a log line `drop,reason=nobeat`.
  - `the heartbeat carries the wall clock, and the round trip is measured on it`: FakeClock wall = 2026-10-31T10:00:00Z. Decode the BEAT this phone sent: its sentAt is that wall clock's milliseconds, low 32 bits. An ECHO comes back with that sentAt after the wall clock moves 40 ms. Expect `peers[7].rttMs == 40`.

- [ ] **Step 6: Run them.** `cd app && flutter test test/box_link_test.dart`. Expected: the four new tests FAIL.

- [ ] **Step 7: Change BoxLink.**
  - Use `ReplayGuard` in place of `Dedupe`, after `open`.
  - Log `drop` with reason `stale` or `nobeat`, rate-limited the same way as the existing drops. Duplicates and too-old packets aren't logged.
  - sentAt and the echo round trip go on the wall clock.
  - Existing tests that inject VOICE without a BEAT get a BEAT first in their setup. That's the new rule, not a workaround. Note each such helper change in the ledger.

- [ ] **Step 8: Run everything.** `cd app && flutter test && flutter analyze`. Expected: all tests pass, and "No issues found!"

- [ ] **Step 9: Update the docs.**
  - **architecture §5.2:** add a "Replay protection" paragraph with the rules from the Global Constraints. Under "Limits, by design", add: "**Boxes can be fooled by forged headers.** A stranger who copies a rider's src, session and next seq can make boxes drop the real packet as a duplicate, because boxes can't check seals. Phones check seals before deduping, so they can't be fooled this way."
  - **architecture §5.3:** BEAT sentAt is "the sender's wall clock, ms since the Unix epoch, low 32 bits".

- [ ] **Step 10: Hand over.** Suggested message: `feat(protocol): replay protection on phones; heartbeats carry the wall clock`.

---

### Task 2: Box mesh messages and rules in `vroo_protocol`

**Files:**
- Modify:
  - `packages/vroo_protocol/lib/src/box_messages.dart`, `lib/src/constants.dart`
  - `test/box_messages_test.dart`
  - `tool/gen_c_vectors.dart`, `tool/box_probe.dart`
  - `firmware/host_test/vectors.h` (regenerated)
  - `docs/architecture.md`: §4.8, §5.2 (the box message table) and §5.4
- Create: `lib/src/mesh_rules.dart`, `test/mesh_rules_test.dart`

**Interfaces:**
- Consumes: `encodeBoxConfig`/`decodeBoxConfig` and `encodeBoxStatus`/`decodeBoxStatus` (Plan A), `groupTagSize`, `originTtl`, and `TalkerCap` from Plan E (`lib/src/relay_rules.dart`, already tested there).
- Produces:
  ```dart
  abstract final class BoxMsgType { static const config = 0x10, status = 0x11, beacon = 0x12; }
  enum BoxRadio { lr250, lr500, fast1m }        // wire values 0, 1, 2 = index
  const defaultBoxRadio = BoxRadio.lr500;
  class BoxConfig { … final BoxRadio? radio; final int? txPowerQdbm; final int? talkerCap; final int? ttl; }
  class BoxNeighbour { const BoxNeighbour(this.boxId, this.rssi); final int boxId, rssi; }
  class BoxMesh {
    final int rxFromBoxes, txToBoxes, relayed, dropCap, dropAir;
    final BoxRadio radio; final int txPowerQdbm, talkerCap, ttl, stackFreeMin, heapFreeMin, neighbourCount;
    final List<BoxNeighbour> neighbours;   // strongest first, at most 16
  }
  class BoxStatus { … final BoxMesh? mesh; }  // null from a firmware-1 box, or if the extension is malformed
  class BoxBeacon {
    final int boxId, fwVersion, intervalMs, neighbourCount;   // intervalMs: a multiple of 100, 1000–10000
    final List<BoxNeighbour> listed;                          // at most 16
  }
  Uint8List encodeBoxBeacon(Uint8List groupTag, BoxBeacon b);                 // groupTag ‖ beacon
  ({Uint8List groupTag, BoxBeacon beacon})? decodeBoxBeacon(Uint8List frame); // null unless a well-formed beacon
  bool shouldRelay({required int ttl, required Set<int> mine, required int? from, required Set<int>? theirs});
  int scaledIntervalMs(int count);              // clamp(count * 100, 1000, 10000)
  int neighbourExpiryMs(int statedIntervalMs);  // 3 * statedIntervalMs + 500
  ```

- [ ] **Step 1: Write the failing rule tests** in `mesh_rules_test.dart`:

```dart
test('a bunched group: nobody relays', () =>
    expect(shouldRelay(ttl: 16, mine: {2, 3}, from: 1, theirs: {2, 3}), isFalse));
test('down a line: the middle box relays', () =>
    expect(shouldRelay(ttl: 16, mine: {1, 3}, from: 1, theirs: {2}), isTrue));
test('a sender whose beacon has not been heard is relayed for', () =>
    expect(shouldRelay(ttl: 16, mine: {1}, from: null, theirs: null), isTrue));
test('ttl 1 is never relayed', () =>
    expect(shouldRelay(ttl: 1, mine: {1, 3}, from: 1, theirs: {2}), isFalse));
test('the sender itself does not count as a new neighbour', () =>
    expect(shouldRelay(ttl: 16, mine: {1}, from: 1, theirs: {}), isFalse));
test('timers scale with the count', () {
  expect([0, 10, 11, 25, 100, 500].map(scaledIntervalMs), [1000, 1000, 1100, 2500, 10000, 10000]);
  expect(neighbourExpiryMs(1000), 3500);
});
```

- [ ] **Step 2: Write the failing message tests** in `box_messages_test.dart`:
  - `a radio config is the mask then the four fields`:
    - `encodeBoxConfig(BoxConfig(radio: BoxRadio.lr250, txPowerQdbm: 60, talkerCap: 3, ttl: 2))` is `[1, 0x10, 0x78, 0, 60, 3, 2]`
    - it decodes back to the same values
  - `out-of-range radio values are refused`: decoding null for radio 3, tx power 7 and 81, cap 0 and 9, and ttl 0 and 17.
  - `a firmware-1 status has no mesh`: Plan A's 30-byte vector decodes with `mesh == null`.
  - `a firmware-2 status carries the mesh and its neighbours`: a round trip of a status with fwVersion 2 and two neighbours (−61, −75); the encoded length is 72.
  - `a status whose neighbour list overruns the bytes keeps the base fields`: cut the last byte; `mesh` is null and `boxId` is still read.
  - `a beacon travels inside the envelope`: `encodeBoxBeacon(tag, BoxBeacon(boxId: 0xA1B2C3, fwVersion: 2, intervalMs: 1100, neighbourCount: 11, listed: [BoxNeighbour(0x0D0E0F, -70)]))`
    - starts with the tag, then `1, 0x12`
    - frame byte 16 (the beacon's interval byte) is 11, in tenths of a second
    - its length is 8 + 11 + 5
    - it decodes back to the same values
  - `malformed beacons are refused`: listed k = 17; k overrunning the frame; a frame under 19 bytes; and type byte 2 (a packet) all decode as null.

- [ ] **Step 3: Run them.** `cd packages/vroo_protocol && dart test`. Expected: the new tests FAIL to compile or fail.

- [ ] **Step 4: Implement the messages and rules** as the Interfaces and the Global Constraints' table say.
  - Decoders ignore bit 7 of the config mask, and bytes after a complete status or beacon.
  - `tool/box_probe.dart`'s status printout gains the mesh fields, so a Mac can read a box's mesh status during desk checks.

- [ ] **Step 5: Generate the C vectors.** Add these to `tool/gen_c_vectors.dart`:
  - `VEC_BOX_CONFIG_RADIO`: the radio config above
  - `VEC_BOX_STATUS_MESH`: box 0x00A1B2C3, fw 2, uptime 3600, 2 phones, counters 100/90/3/1, rx_from_boxes 500, tx_to_boxes 120, relayed 20, drop_cap 2, drop_air 1, radio lr500, tx power 80, cap 4, ttl 16, stack 1200, heap 90 000, neighbours 2, listed (0x0D0E0F, −61) and (0x0A0B0C, −75)
  - `VEC_BEACON`: tag ‖ box 0xA1B2C3, fw 2, interval 1000, neighbours 1, listed (0x0D0E0F, −70). That's what a real box with one neighbour sends, so Task 3 can produce it byte for byte
  - `VEC_BEACON_EMPTY`: tag ‖ box 0xA1B2C3, fw 2, interval 1000, no neighbours

  Run: `cd packages/vroo_protocol && dart run tool/gen_c_vectors.dart ../../firmware/host_test/vectors.h`. Expected: vectors.h gains the four arrays.

- [ ] **Step 6: Run the protocol tests and the existing host tests.**
  - `cd packages/vroo_protocol && dart test`. Expected: all pass.
  - `cmake -S firmware/host_test -B firmware/host_test/build && cmake --build firmware/host_test/build && firmware/host_test/build/test_vroo_wire`. Expected: "vroo_wire: all tests passed". The new arrays stay unused until Task 3; constants in a header don't trigger unused-variable warnings.

- [ ] **Step 7: Update the docs.**
  - **architecture §5.2:** replace "The builder fixes their layouts…" with the box message table from the Global Constraints.
  - **architecture §4.8:**
    - beacons travel inside the envelope as type 0x12
    - LR is on the station interface only, and why
    - the radio speed default and its reason
    - capped voice is dropped entirely
    - the ttl clamp
    - the dedupe table is about 40 KB (2,048 slots × 20 bytes), not 25 KB (Plan A review)
  - **architecture §5.4:** beacon jitter ±10%, and neighbour expiry.

- [ ] **Step 8: Hand over.** Suggested message: `feat(protocol): box beacon, mesh status and radio config; relay rule, talker cap and timers`.

---

### Task 3: `vroo_wire`: the box's mesh decisions in C

**Files:**
- Modify: `firmware/components/vroo_wire/include/vroo_wire.h`, `vroo_wire.c`, `firmware/host_test/test_vroo_wire.c`
- Create: `firmware/components/vroo_wire/vw_mesh.c`. Add it to both CMakeLists: the component's and `host_test`'s.

**Interfaces:**
- Consumes: Task 2's layouts and vectors, and Plan A's `vw_unwrap`, `vw_parse_header` and `vw_dedupe_*`.
- Produces:
  ```c
  #define VW_BOX_BEACON 0x12
  #define VW_FW_VERSION 2
  #define VW_ESPNOW_MAX 250
  #define VW_MAX_NEIGHBOURS 64
  #define VW_BEACON_LISTED 16
  #define VW_BOX_STATUS_MAX (62 + 5 * VW_BEACON_LISTED)
  enum { VW_RADIO_LR250 = 0, VW_RADIO_LR500 = 1, VW_RADIO_1M = 2 };
  #define VW_DEFAULT_RADIO VW_RADIO_LR500   // mirrors Dart's defaultBoxRadio; config.c uses it

  // vw_box_config_t gains: bool has_radio, has_tx_power, has_cap, has_ttl; uint8_t radio, tx_power, cap, ttl;
  // vw_box_status_t gains: rx_from_boxes, tx_to_boxes, relayed, drop_cap, drop_air (u32); radio, tx_power, cap,
  //                        ttl (u8); stack_free_min (u16); heap_free_min (u32)

  typedef enum { VW_SEND, VW_DROP_TAG, VW_DROP_DUP, VW_DROP_CAP, VW_BEACON_SEEN } vw_result_t;
  typedef struct {
      vw_result_t result;
      bool to_phones;   // hand the frame to this box's phones (for a phone's frame: all but the sender)
      bool to_air;      // broadcast it over ESP-NOW
      uint8_t ttl;      // write this into body byte 2 (envelope byte 10) before sending
  } vw_action_t;

  typedef struct vw_mesh vw_mesh_t;   // defined in the header: all state, no allocation (about 47 KB)
  void vw_mesh_init(vw_mesh_t *m, uint32_t box_id, const vw_box_config_t *cfg);
  void vw_mesh_configure(vw_mesh_t *m, const vw_box_config_t *cfg);  // tag, cap, ttl; a new tag clears neighbours and talkers
  vw_action_t vw_mesh_from_phone(vw_mesh_t *m, const uint8_t *dgram, size_t len, uint32_t now_ms);
  vw_action_t vw_mesh_from_air(vw_mesh_t *m, const uint8_t *frame, size_t len, const uint8_t mac[6],
                               int8_t rssi, uint32_t now_ms);
  size_t vw_mesh_beacon(vw_mesh_t *m, uint8_t *out, size_t cap, uint32_t now_ms);  // 0 without a tag
  uint32_t vw_mesh_beacon_interval_ms(const vw_mesh_t *m, uint32_t now_ms);        // before jitter
  uint32_t vw_scaled_interval_ms(uint32_t count);
  uint8_t vw_mesh_neighbours(const vw_mesh_t *m, uint32_t now_ms);                   // live ones
  // Writes BOX_STATUS: 30 bytes when m is NULL (setup mode), else 62 + 5k with the k strongest live neighbours.
  size_t vw_encode_box_status(const vw_box_status_t *s, const vw_mesh_t *m, uint32_t now_ms, uint8_t *out, size_t cap);
  ```
- Counting:
  - `vw_mesh_from_*` count `rx_from_phones`, `rx_from_boxes`, `drop_dup`, `drop_tag` and `drop_cap`.
  - The firmware counts `tx_to_phones`, `tx_to_boxes`, `relayed` and `drop_air` when it actually sends.
  - All of them live in `m->counts`, a `vw_box_status_t`.
  - `vw_encode_box_status` takes every number from `s` (the bridge copies `m->counts` into it, as Plan A does) and only the neighbour list from `m`.

- [ ] **Step 1: Write the failing host tests** in `test_vroo_wire.c`. Each block is headed by a comment naming the matching Dart test where there is one. Packets are built from `VEC_ENVELOPE` with src, seq, type or ttl patched; the seal isn't checked by boxes.
  - **`from a phone: a new packet goes to the other phones and the air`:** VEC_ENVELOPE (a BEAT, ttl 16) gives result SEND, to_phones, to_air, ttl 16. With config ttl 3, it gives ttl 3.
  - **`from a phone: a copy is a duplicate, and another group's tag is dropped`:** DROP_DUP, then DROP_TAG.
  - **`the fifth talker is dropped, but heartbeats from more riders get through`:** VOICE from srcs 1–4 is admitted; src 5 gives DROP_CAP; a BEAT from src 5 gives SEND; at +1001 ms, src 5's VOICE gives SEND.
  - **`a beacon makes a neighbour`:** in a mesh whose own box ID is 0x00123456, VEC_BEACON from MAC m1 with RSSI −60 gives BEACON_SEEN, and 1 live neighbour.
  - **`a bunched group: nobody relays`:** neighbours A and B, both listing each other. A packet from A gives to_phones and not to_air.
  - **`down a line: the middle box relays`:** neighbours A and C; A lists only this box. A packet from A with ttl 16 gives to_air with ttl 15.
  - **`a sender whose beacon has not been heard is relayed for`:** an unknown MAC gives to_air.
  - **`ttl 1 is never relayed`:** to_phones only.
  - **`a packet heard back from another box is dropped as a duplicate`:** a phone's packet, then the same bytes from the air with ttl 15, gives DROP_DUP.
  - **`another group's beacon or packet changes nothing`:** a beacon and a packet with a different tag give DROP_TAG, leaving neighbours 0 and talkers 0.
  - **`a neighbour that stops beaconing expires`:** a beacon stating 1000 ms is live at +3500 and gone at +3501.
  - **`a beacon whose counts overrun the frame is ignored`:** k = 17, k = 3 in a 1-neighbour frame, and a 12-byte frame each give DROP_TAG, leaving neighbours 0.
  - **`the beacon lists the 16 strongest and states its interval`:**
    - With 20 neighbours (RSSI −40 … −59), the beacon is 99 bytes, lists −40 first and −55 last, and states neighbours 20 and interval 20 (tenths).
    - A mesh with box ID 0xA1B2C3, whose one neighbour (box 0x0D0E0F) was heard at −70, sends exactly VEC_BEACON.
  - **`a new group tag clears neighbours and talkers`**.
  - **`config with radio fields decodes, and out-of-range values are refused`:** VEC_BOX_CONFIG_RADIO, and the Dart test's bad values.
  - **`status with the mesh matches the Dart bytes`:** VEC_BOX_STATUS_MESH. Also `m == NULL` gives the 30-byte VEC_BOX_STATUS.

- [ ] **Step 2: Run them.** `cmake --build firmware/host_test/build && firmware/host_test/build/test_vroo_wire`. Expected: the build fails, because `vw_mesh_*` aren't defined.

- [ ] **Step 3: Implement `vw_mesh.c` and the header changes.** The rules are Task 2's. Two choices are left open by the signatures:
  - **Neighbour table:** a linear array of 64 entries, keyed by MAC. A full table replaces the entry heard longest ago. Each entry keeps its box ID, last RSSI, when it was heard, its expiry, and its listed box IDs.
  - **Frames from the air:** check length ≥ 10, the tag, and version 1, then branch on body byte 1. `0x12` is a beacon (length ≥ 19 + 5k, k ≤ 16). Types 1–5 are packets (length ≥ 39, `vw_parse_header`). Anything else is DROP_TAG. Frames over `VW_ESPNOW_MAX` from phones are DROP_TAG.

- [ ] **Step 4: Run them.** Same command. Expected: "vroo_wire: all tests passed", with no warnings under `-Wall -Wextra -Wpedantic -Werror`.

- [ ] **Step 5: Hand over.** Suggested message: `feat(box): mesh decisions in vroo_wire: relay rule, talker cap, beacons, neighbours`.

---

### Task 4: Box firmware: ESP-NOW long range

**Files:**
- Create: `firmware/main/mesh.c`, `firmware/main/mesh.h`
- Modify:
  - `firmware/main/`: `bridge.c`, `bridge.h`, `wifi_ap.c`, `wifi_ap.h`, `config.c`, `config.h`, `led.c`, `led.h`, `main.c`, `CMakeLists.txt` (add `mesh.c`, and `vfs` to PRIV_REQUIRES)
  - `docs/hardware.md`: a status-light table in §1
  - `docs/development.md`: a "Box desk check" row

**Interfaces:**
- Consumes: Task 3's `vw_mesh_*` and the extended `vw_box_config_t` and `vw_box_status_t`.
- Produces (`mesh.h`):
  ```c
  typedef struct { uint8_t mac[6]; int8_t rssi; uint8_t len; uint8_t data[VW_ESPNOW_MAX]; } mesh_frame_t;
  void mesh_start(const vw_box_config_t *cfg); // ESP-NOW on WIFI_IF_STA, broadcast peer, radio speed and power
  void mesh_apply(const vw_box_config_t *cfg); // live radio and power changes
  bool mesh_send(const uint8_t *frame, size_t len);  // false when ESP-NOW refuses it
  int mesh_fd(void);                           // readable while frames wait (an eventfd)
  bool mesh_take(mesh_frame_t *out);           // the next waiting frame, from a 32-deep queue
  ```
- Light patterns (`led.h`):
  - `LED_SETUP`: blink once a second
  - `LED_NO_PHONE`: one 100 ms flash every 2 s
  - `LED_NO_PHONE_BOXES`: two 100 ms flashes every 2 s
  - `LED_PHONE`: solid
  - `LED_PHONE_BOXES`: solid, with a 100 ms off-blink every 2 s
- NVS keys:
  - `radio`, `cap` and `ttl` (u8), defaulting to 1, 4 and 16
  - `txp` (u8), absent unless set

- [ ] **Step 1: Wire it together.**
  - **`wifi_ap_start`:**
    - In normal mode, set `WIFI_MODE_APSTA`.
    - After `esp_wifi_start`, set the AP's protocol to `11B|11G|11N` and the station's to `11B|11G|11N|LR`.
    - Setup mode stays AP only.
  - **`mesh_start`** follows the ESP-IDF ESP-NOW example:
    - `esp_now_init` and a receive callback.
    - The callback copies a frame of 1–250 bytes and its RSSI into the queue, without blocking, then writes 1 to the eventfd. A full queue drops the frame.
    - Add the broadcast peer (`ifidx = WIFI_IF_STA`, channel 0, no encryption), then set the rate and power.
  - **The bridge task:**
    - Owns a static `vw_mesh_t`, and selects on the two sockets plus `mesh_fd()`.
    - For a phone datagram, `vw_mesh_from_phone`. For each air frame, `vw_mesh_from_air`.
    - It acts on `vw_action_t`, patching the ttl byte first, and counts each send; a false `mesh_send` counts `drop_air`.
    - It sends a beacon when its jittered interval is up.
    - Each second it sends the status, with `uxTaskGetStackHighWaterMark` and `esp_get_minimum_free_heap_size`, and sets the light from phones and live neighbours.
  - **`on_control`:**
    - An empty BOX_CONFIG (mask 0) saves nothing (Plan A review).
    - Radio and power changes apply live through `mesh_apply`. Tag, cap and ttl changes apply live through `vw_mesh_configure`.
    - The restart rule for the channel and password is unchanged.
  - **Logs:**
    - `mesh on ch=<n> radio=<name>` at start
    - `beacon nb=<n>` at most every 10 s
    - `air refused` at most once a second
  - `FW_VERSION` comes from `VW_FW_VERSION`.

- [ ] **Step 2: Build.**
  - `cd firmware && . ~/esp/esp-idf/export.sh && idf.py build`. Expected: "Project build complete", and no warnings from `main/` or `vroo_wire`.
  - Then run the host tests again. Expected: they pass.

- [ ] **Step 3: 🖥 + 👤 Desk check with the one box.** 👤 Plug the desk box into the Mac.
  - Run: `idf.py -p /dev/cu.usbserial-0001 -b 115200 flash monitor` for about 30 s. Flashing at 115200 is what works through the Mac's hub.
  - Then, on the box's Wi-Fi from Terminal: `cd packages/vroo_protocol && dart run tool/box_probe.dart bridge --tag <the group tag>`.
  - 👤 Start a ride on the iPhone.

  Expected:
  - The log shows `mesh on ch=<group channel> radio=lr500`.
  - The probe prints fw 2, radio lr500, cap 4, ttl 16, neighbours 0, and a stack-free figure above 512 bytes.
  - tx_to_boxes counts up while the iPhone sends, about 1 a second (its heartbeat).
  - drop_air stays 0.
  - The light shows the phone.
  - The iPhone's ride screen still shows the box up.

  Record a dated line in test-plan §5. The settings were kept: flashing over USB doesn't erase NVS.

- [ ] **Step 4: Update the docs.**
  - **hardware.md §1:** the status-light table, in plain words.
  - **development.md:** the desk-check commands.

- [ ] **Step 5: Hand over.** Suggested message: `feat(box): ESP-NOW long range between boxes, beacons, mesh status and lights`.

---

### Task 5: The flashing page

**Files:**
- Create: `firmware/flasher/index.html`, `firmware/flasher/manifest.json`, `firmware/flasher/build.sh`
- Modify:
  - `.gitignore`: `firmware/flasher/*.bin`
  - `docs/hardware.md` §5
  - `docs/development.md`

**Interfaces:**
- Consumes: Task 4's firmware build.
- Produces:
  - `firmware/flasher/build.sh` builds the firmware, runs `idf.py merge-bin -o vroo_box.bin`, and copies `firmware/build/vroo_box.bin` next to the page.
  - The page is served with `python3 -m http.server 8000 --directory firmware/flasher` and opened at `http://localhost:8000` in Chrome or Edge. Web Serial needs a secure context, and localhost counts as one. Nothing gets published (D31).

- [ ] **Step 1: Write the page.**
  - **`manifest.json`:** `{"name": "Vroo box", "version": "2", "new_install_prompt_erase": true, "builds": [{"chipFamily": "ESP32", "parts": [{"path": "vroo_box.bin", "offset": 0}]}]}`.
  - **`index.html`:**
    - the header comment, and the title "Vroo box"
    - the ESP Web Tools 10.4.0 module script, and `<esp-web-install-button manifest="manifest.json">`
    - three plain steps, as in hardware.md §5: plug in with a data cable; click Install and pick the port; when it's done, the box opens its setup Wi-Fi
    - a note: tick "Erase" for a new box; leave it unticked to update a box and keep its settings
  - **`build.sh`:** `set -euo pipefail`, then the commands above.

- [ ] **Step 2: Check it.**
  - Run: `bash firmware/flasher/build.sh && python3 -m json.tool firmware/flasher/manifest.json >/dev/null && ls -l firmware/flasher/vroo_box.bin`. Expected: no error, and a file of roughly 0.8–1.2 MB.
  - `git status --short firmware/flasher` lists only the three source files.

- [ ] **Step 3: 👤 Device check (founder, with the desk box).** Serve the page, open it in Chrome, click Install, pick the box's port, and leave Erase unticked.

  Expected:
  - The install finishes.
  - The box comes back on its own Wi-Fi with its settings.
  - The iPhone's ride shows the box up.

  Record a dated line in test-plan §5. The erase path gets tried on a new board in Task 10.

- [ ] **Step 4: Update the docs.**
  - **hardware.md §5:** how to start the page on the founder's Mac.
  - **development.md:** a "Flashing page" row.

- [ ] **Step 5: Hand over.** Suggested message: `feat(box): flashing page with ESP Web Tools`.

---

### Task 6: The mesh simulator

**Files:**
- Create:
  - `sim/pubspec.yaml`: `vroo_sim`, `publish_to: none`, the sdk ^3.13.7, depending on `vroo_protocol` by path; dev `lints` and `test`
  - `sim/analysis_options.yaml`, `sim/.gitignore`
  - `sim/bin/vroo_sim.dart`, `sim/lib/vroo_sim.dart`
  - `sim/lib/src/airtime.dart`, `channel.dart`, `sim_box.dart`, `scenario.dart`, `report.dart`
  - `sim/test/airtime_test.dart`, `sim/test/scenario_test.dart`
- Modify:
  - `docs/architecture.md` §4.10: box-to-phone Wi-Fi is in the model
  - `docs/development.md`: the sim rows
  - `docs/test-plan.md` §5: results
  - `docs/decisions.md`, `docs/todo.md`: as the results call for

**Interfaces:**
- Consumes: `shouldRelay`, `TalkerCap`, `Dedupe`, `scaledIntervalMs`, `neighbourExpiryMs`, `BoxRadio` and `originTtl` from `vroo_protocol`.
- Produces:
  ```dart
  int airtimeUs(int payloadBytes, BoxRadio radio);  // one ESP-NOW frame including contention
  const apFrameUs = 200;                            // one phone↔box Wi-Fi frame, including ACK and contention
  enum Layout { bunched, convoy }
  class Scenario {
    Scenario({required this.boxes, this.layout = Layout.bunched, this.hearRange = 2, this.radio = BoxRadio.lr500,
              this.talkers = 4, this.seconds = 20, this.seed = 1, this.baseLoss = 0.02,
              this.warmupMs = 3000, this.idealChannel = false});
    // Talkers are boxes 0 … talkers − 1 (box 0 is the front of a convoy). They start after warmupMs, once beacons
    // have filled the neighbour tables, and only frames sent after it are measured. idealChannel: no collisions
    // and no loss, with airtime still counted; it's for tests of the rules, not for the sweep.
  }
  class Report {
    final double voiceDelivery, worstDelivery, relaysPerFrame, busiestChannelUse;
    final Map<int, ({int p50, int p95})> delayMsByHops;
    final Map<String, double> airtimeShare;   // voice, relay, beat, echo, beacon, phone
    final int capDrops;
    String markdownRow();
  }
  Report runScenario(Scenario s);
  ```
- The model is fixed here so the tests can be exact:
  - **ESP-NOW frame:** payload + 43 bytes (MAC header, vendor action header, FCS).
  - **Airtime in µs:** 360 (DIFS 50 plus a mean backoff of 310), plus the preamble, plus bits ÷ rate, rounded to the nearest µs. The preamble is 500 µs for LR (an assumption: Espressif doesn't publish it) and 192 µs for 1 Mbps.
  - **Traffic sizes:**
    - voice 83 bytes; each talker talks continuously (the worst case), a frame every 20 ms
    - BEAT 60 bytes, every `scaledIntervalMs(riders)`, from every rider (one per box)
    - ECHO 47 bytes, for the 1st and every 5th BEAT each phone hears from each rider
    - beacon 19 + 5·min(16, n) bytes, every `scaledIntervalMs(n)` ± 10%
    - phone↔box frames take `apFrameUs` each: one up for each packet a phone sends, and one down to each phone for each packet its box hands over
  - **Hearing:**
    - bunched: everyone hears everyone
    - convoy: box i hears boxes within ±`hearRange` places
    - Carrier sense uses the same reach.
  - **CSMA:** wait until the sender senses an idle channel, then 50 µs plus a random 0–620 µs. If it's busy then, wait again. Starts within 20 µs of each other don't sense each other.
  - **Loss:** a receiver loses a frame that overlaps any other transmission it can hear, and otherwise with probability `baseLoss`.
  - **Delivery:** a voice frame counts for a listening box when its phone gets it within 300 ms of sending.

- [ ] **Step 1: Write the failing tests.**

```dart
test('airtime of a voice frame at each speed', () {
  expect(airtimeUs(83, BoxRadio.lr250), 4892);
  expect(airtimeUs(83, BoxRadio.lr500), 2876);
  expect(airtimeUs(83, BoxRadio.fast1m), 1560);
});
test('bunched boxes carry each frame without relays', () {
  final r = runScenario(Scenario(boxes: 5, talkers: 1, seconds: 2, idealChannel: true));
  expect(r.relaysPerFrame, 0);
  expect(r.voiceDelivery, 1.0);
});
test('a chain relays each frame once per middle box', () {
  final r = runScenario(
      Scenario(boxes: 6, layout: Layout.convoy, hearRange: 1, talkers: 1, seconds: 2, idealChannel: true));
  expect(r.relaysPerFrame, 4.0);
  expect(r.voiceDelivery, 1.0);
  expect(r.delayMsByHops.keys, containsAll([1, 2, 3, 4, 5]));
});
test('a ring of boxes relays each frame at most once per box', () {
  final r = runScenario(
      Scenario(boxes: 8, layout: Layout.convoy, hearRange: 2, talkers: 1, seconds: 2, idealChannel: true));
  expect(r.relaysPerFrame, inInclusiveRange(1, 7));
  expect(r.voiceDelivery, 1.0);
});
test('with six talkers each box carries at most four', () {
  final r = runScenario(Scenario(boxes: 6, talkers: 6, seconds: 2, idealChannel: true));
  expect(r.capDrops, greaterThan(0));
});
test('a busy real channel loses some frames but never relays twice', () {
  final r = runScenario(Scenario(boxes: 8, layout: Layout.convoy, hearRange: 2, talkers: 4, seconds: 4));
  expect(r.voiceDelivery, lessThan(1.0));
  expect(r.relaysPerFrame, lessThanOrEqualTo(7));
});
test('the same seed gives the same report', () =>
    expect(runScenario(Scenario(boxes: 20)).markdownRow(), runScenario(Scenario(boxes: 20)).markdownRow()));
```

In the "ring", each box hears two places either side, so many boxes are relay candidates. Dedupe still lets each relay at most once.

- [ ] **Step 2: Run them.** `cd sim && dart pub get && dart test`. Expected: FAIL, `airtimeUs` isn't defined.

- [ ] **Step 3: Implement the simulator.**
  - It's an event queue in µs, ordered by (time, sequence number) so runs are deterministic, with `Random(seed)`.
  - `SimBox` applies the same order as `vw_mesh_from_*`: tag, then dedupe, then the cap, then deliver, then `shouldRelay`, from neighbour sets built from its beacons.
  - CLI:
    - `dart run bin/vroo_sim.dart --boxes 100 --layout convoy --radio lr500 --talkers 4` prints one report.
    - `dart run bin/vroo_sim.dart sweep` prints a markdown table for boxes {5, 10, 50, 100, 200} × layout {bunched, convoy} × radio {lr250, lr500, fast1m} × talkers {1, 4}, 20 s each.

- [ ] **Step 4: Run the tests.** `cd sim && dart test && dart analyze`. Expected: all pass, and no issues.

- [ ] **Step 5: Run the sweep and write it up.**
  - Run: `cd sim && dart run bin/vroo_sim.dart sweep`, and save the output in the executor's scratchpad, not the repository.
  - Add a dated "Simulation (Plan C)" entry to test-plan §5: the table, and a short reading of it.
  - Then rule on each of these, with decisions.md entries for any knob that changes:
    1. **The default radio speed:** the slowest speed (the longest reach) whose 5-box bunched run with 4 talkers delivers ≥ 95% with the busiest channel use ≤ 70%.
       - If that isn't 500 kbps, change `VW_DEFAULT_RADIO` and `defaultBoxRadio`, each with a test.
       - If no speed passes, record that four talkers don't fit, and propose a lower N for FT2 to confirm.
    2. **Phones' Wi-Fi share:** if it's above 30% of the channel in any 50-box run, add the todo M2 item "Bundle box-to-phone packets every 20 ms".
    3. **Echoes:** if ECHO is the biggest non-voice share at 100 boxes, add the todo M2 item "Scale echoes with group size".
    4. **Long convoys:** if 200-box convoy delivery at 8+ hops is under 95%, record that limit beside D21.
  - Mark U11 "answered by simulation" in spec §10, with a pointer to the entry.

- [ ] **Step 6: Update the docs.** architecture §4.10 (the phone↔box frames and the assumptions), and development.md (`cd sim && dart test`, and the two run commands).

- [ ] **Step 7: Hand over.** Suggested message: `feat(sim): mesh simulator, and its first results`.

---

### Task 7: The box mesh in the app, and the diagnostics switch

**Files:**
- Modify:
  - `app/lib/rider_store.dart`: `diagnostics`, default false
  - `app/lib/ui/home_screen.dart`: the switch
  - `app/lib/net/box_link.dart`: `configureBox`, and each rider's last ttl
  - `app/lib/net/peer.dart`: `lastTtl`
  - `app/lib/ride/ride_engine.dart`: the box line every 5 s, `setBoxRadio`, `diagnostics`
  - `app/lib/ui/ride_screen.dart`: the box line, and the Field test section
- Test: `app/test/ride_screen_test.dart`, `app/test/ride/ride_engine_test.dart`, `app/test/box_link_test.dart`

**Interfaces:**
- Consumes: Task 2's `BoxMesh`, `BoxNeighbour`, `BoxRadio` and `BoxConfig.radio`.
- Produces:
  ```dart
  // RiderStore
  Future<bool> diagnostics();  Future<void> saveDiagnostics(bool on);
  // BoxLink
  Future<void> configureBox(BoxConfig c);   // to the box's control port
  // PeerInfo
  int? lastTtl;                             // ttl of the rider's last packet
  // RideEngine
  final bool diagnostics;                   // constructor parameter, default false
  Future<void> setBoxRadio(BoxRadio r);
  // RideView gains: required bool diagnostics, required ValueChanged<BoxRadio> onBoxRadio
  ```
- Ride screen text:
  - **Box line title:**
    - `Box Vroo-A1B2C3: up · 2 boxes, best -61 dBm`
    - `· 1 box, best …` for one, `· no other boxes` for none, and nothing extra from a firmware-1 box
  - **Subtitle:** Plan A's text, then ` · relayed R · cap C · air A`.
  - **Field test section** (diagnostics only): a "Box radio" segmented button, with the box's current speed selected:
    - **Furthest:** long range 250k
    - **Far:** long range 500k
    - **Fast:** 1 Mbps
- **Log, every 5 s, with the stats:**
  - `box,nb=<n> best=<dBm> radio=<name> rx_air=… tx_air=… relayed=… cap=… air=… stack=… heap=… nbs=<id>:<rssi>;…`
  - The per-rider stats gain `ttl=<lastTtl>`.

- [ ] **Step 1: Write the failing tests.**
  - **ride_screen_test:**
    - `the box line shows its neighbours and best signal`
    - `a box with no neighbours says so`
    - `the field test section shows only with diagnostics on`
    - `tapping Fast picks the 1 Mbps radio` (`onBoxRadio` gets `BoxRadio.fast1m`)
  - **ride_engine_test:**
    - `choosing a box radio sends a BOX_CONFIG to the control port`: FakeVrooNet records `encodeBoxConfig(BoxConfig(radio: BoxRadio.fast1m))` on port 47001.
    - `the 5 s stats include the box line`: a status with two neighbours gives a `box` line with `nb=2 best=-61`.
  - **box_link_test:**
    - `each rider's last ttl is kept`: a packet with ttl 15 gives `peers[7].lastTtl == 15`.

- [ ] **Step 2: Run them.** `cd app && flutter test`. Expected: the new tests FAIL.

- [ ] **Step 3: Implement.**
  - **Home screen:** a `SwitchListTile` "Diagnostics", subtitle "Field tests: extra controls, and sharing your location with your group".
  - **RideScreen:** reads the switch at start and passes it to RideEngine and RideView.

- [ ] **Step 4: Run them.** `cd app && flutter test && flutter analyze`. Expected: all pass, and no issues.

- [ ] **Step 5: Hand over.** Suggested message: `feat(app): box neighbours and mesh counters, box radio setting, diagnostics switch`.

---

### Task 8: GPS distance in diagnostics

**Files:**
- Create: `app/lib/diag/geo.dart`, `app/lib/diag/locations.dart`, `app/test/diag/geo_test.dart`
- Modify:
  - **app:**
    - `pubspec.yaml`: `geolocator: ^14.1.2`
    - `lib/net/box_link.dart`: `fix`, `diagnostics`, the peers' fixes, and `peer_lost`/`peer_back` lines with the distance
    - `lib/net/peer.dart`: `lat`, `lon`, `accuracyM`
    - `lib/ride/ride_engine.dart`: start `Locations` with diagnostics on, put `dist` in the stats, start audio with `location`
    - `lib/ui/ride_screen.dart`: the distance on rider rows
    - `lib/ui/home_screen.dart`: ask for location when diagnostics turns on
    - `ios/Runner/Info.plist`: `NSLocationWhenInUseUsageDescription`, and `location` in `UIBackgroundModes`
    - `android/app/src/main/AndroidManifest.xml`: `ACCESS_FINE_LOCATION` and `ACCESS_COARSE_LOCATION` if they're missing
  - **vroo_audio:**
    - the Dart API, the fake, the channel and their tests
    - `android/.../RideService.kt` and `VrooAudioPlugin.kt`: the `location` extra
    - `android/src/main/AndroidManifest.xml`: `foregroundServiceType="microphone|connectedDevice|location"`, and `FOREGROUND_SERVICE_LOCATION`
  - **docs:**
    - architecture §4.5 (`start(notificationText, location)`) and §7 (location in M1 test builds)
    - decisions: a new entry, *Claude's call*: `geolocator` (MIT) for diagnostics GPS. M1 builds carry the `location` background mode and the Android location service type, used only with diagnostics on. Two flavors wait for M3

**Interfaces:**
- Consumes: Task 7's `diagnostics`; `Beat.lat`, `Beat.lon`, `Beat.accuracyM` and `BeatFlags.diagnostics` (protocol v1).
- Produces:
  ```dart
  class Fix { const Fix(this.lat, this.lon, this.accuracyM); final double lat, lon; final int accuracyM; }
  abstract interface class Locations { Stream<Fix> get fixes; Future<void> stop(); }
  class GeolocatorLocations implements Locations { … }  // best accuracy, every 1 s; background on both platforms
  class FakeLocations implements Locations { void emit(Fix f); … }   // in test/
  double distanceM(double lat1, double lon1, double lat2, double lon2); // haversine, R = 6 371 000 m
  // vroo_audio
  Future<StartResult> start({required String notificationText, bool location = false});
  // BoxLink
  bool diagnostics = false;  Fix? fix;
  // PeerInfo
  double? lat, lon;  int? accuracyM;
  // RideEngine gains Locations? locations (null when diagnostics is off or location is refused)
  ```
- iOS settings: `AppleSettings(accuracy: LocationAccuracy.best, activityType: ActivityType.automotiveNavigation, pauseLocationUpdatesAutomatically: false, allowBackgroundLocationUpdates: true, showBackgroundLocationIndicator: true)`.
- Android: `AndroidSettings(accuracy: LocationAccuracy.best, intervalDuration: Duration(seconds: 1))`. Our ride service carries the location type, so no extra notification is needed.

- [ ] **Step 1: Write the failing tests.**
  - **geo_test:**
    - `one degree of latitude is about 111.2 km` (`distanceM(0, 0, 1, 0)` within 1 m of 111 195)
    - `two points 100 m apart` (`distanceM(12.9716, 77.5946, 12.97250, 77.5946)` within 0.5 m of 100.1)
  - **box_link_test:**
    - `with diagnostics on, heartbeats carry the fix`: the decoded beat has the diagnostics flag and the fix's lat and lon, to f32 precision.
    - `with diagnostics off, heartbeats carry no location`.
    - `a rider's location from their heartbeat is kept`.
    - `a lost rider is logged with the distance`: two fixes 100 m apart, then the rider is silent for 4 s, gives a `peer_lost` line with `dist=100`.
  - **ride_screen_test:**
    - `a rider's distance shows when both fixes are known` (the row subtitle contains `· 100 m ·`)
  - **vroo_audio channel_vroo_audio_test:**
    - `start passes location to the platform` (the method call's arguments contain `location: true`)
  - **ride_engine_test:**
    - `with diagnostics on, the audio service starts with location`
    - `the stats give each rider's distance`

- [ ] **Step 2: Run them.** `cd app && flutter test`, then `cd packages/vroo_audio && flutter test`. Expected: the new tests FAIL.

- [ ] **Step 3: Implement.**
  - Android: the service adds `FOREGROUND_SERVICE_TYPE_LOCATION` only when the extra is true, and the app passes true only after location is granted.
  - `peer_lost` is logged once each time a rider goes silent for 4 s, from BoxLink's 1 s tick.
  - The distance is rounded to the metre, and left out when either fix is missing.

- [ ] **Step 4: Run all suites.**
  - `cd app && flutter test && flutter analyze`
  - `cd packages/vroo_audio && flutter test`
  - The Kotlin suite, as development.md says.

  Expected: all pass, and no issues.

- [ ] **Step 5: Builds.** `cd app && flutter build apk --debug && flutter build ios --debug --no-codesign`. Expected: both build.

- [ ] **Step 6: Hand over.** Suggested message: `feat(diag): GPS distance between riders in diagnostics`.

---

### Task 9: Pretend extra talkers

**Files:**
- Create: `app/lib/net/fill.dart`
- Modify:
  - `app/lib/net/box_link.dart`: `pretendTalkers`, and counting FILL heard
  - `app/lib/ride/ride_engine.dart`: `fill` stats every 5 s, and `pretendTalkers`
  - `app/lib/ui/ride_screen.dart`: the control
- Test: `app/test/box_link_test.dart`, `app/test/ride/ride_engine_test.dart`, `app/test/ride_screen_test.dart`

**Interfaces:**
- Consumes: Task 1 (FILL needs only the sequence window), and Task 7's Field test section.
- Produces:
  ```dart
  class FillStats { int received = 0, lost = 0; void add(int frameNo); }  // lost: gaps in frameNo
  // BoxLink
  int get pretendTalkers;  set pretendTalkers(int k);  // 0–4
  Map<int, FillStats> get fillHeard;                   // by pretend rider ID, from other phones
  // RideEngine: set pretendTalkers(int k)
  // RideView gains: required int pretendTalkers, required ValueChanged<int> onPretendTalkers
  ```
- **FILL streams:**
  - k streams, each with its own random rider ID and session, and its own seq from 0.
  - Each sends a FILL every 20 ms: frameNo u32, then 40 random bytes. That's VOICE-sized, so the box caps it like a talker.
  - Sealed with the group key, ttl 16.
  - The control resets to 0 at every ride start, so a real ride is never loaded by accident.
- **Log:** `stats,peer=fill-<id hex> rx=… lost=…`.
- **Screen:** "Pretend talkers", with − and + and the count. It shows only with diagnostics on.

- [ ] **Step 1: Write the failing tests.**
  - **box_link_test:**
    - `two pretend talkers send two FILL streams of 50 a second, each its own rider`: after 1 s of fake time, there are 100 FILL packets sent, from 2 rider IDs other than myId, each with a 44-byte payload.
    - `setting pretend talkers to 0 stops them`.
    - `fill from others is counted with its losses, and never played`: frames 0, 1 and 3 give received 3 and lost 1, with no HeardVoice.
    - `fill needs no heartbeat`.
  - **ride_engine_test:**
    - `fill stats are logged every 5 s`
  - **ride_screen_test:**
    - `the pretend-talkers control shows with diagnostics on, and + raises it`

- [ ] **Step 2: Run them.** `cd app && flutter test`. Expected: the new tests FAIL.

- [ ] **Step 3: Implement.** A single `Timer.periodic(20 ms)` sends one FILL per stream. FILL whose rider ID is one of this phone's own streams is ignored on receipt.

- [ ] **Step 4: Run them.** `cd app && flutter test && flutter analyze`. Expected: all pass, and no issues.

- [ ] **Step 5: Hand over.** Suggested message: `feat(diag): pretend extra talkers (FILL)`.

---

### Task 10: Two-box bench

**Files:**
- Modify:
  - `docs/test-plan.md` §2 (the new boards, without hardware addresses) and §5
  - `docs/hardware.md` §2 (the board bought)
  - `docs/todo.md`
  - `docs/decisions.md`, if a knob changes

**Interfaces:**
- Consumes: Tasks 1–9 on both phones, and two or three boxes.

- [ ] **Step 1: 👤 Get the boards.** Buy two classic ESP32 boards with an antenna connector (ESP32-WROOM-32U or -32UE on a USB development board), and two 2.4 GHz antennas that fit (u.FL, or u.FL to RP-SMA with a dipole). A third set is needed for FT3.

- [ ] **Step 2: 🖥 Install the test builds on both phones.**
  - `cd app && flutter run --release -d <iphone id>`, then `flutter run --release -d <android id>`.
  - On the iPhone, release mode avoids the editor's Local Network problem (Plan B).

- [ ] **Step 3: 👤 Bench checklist.** Read it aloud while doing it.
  1. **Flash.** Serve the flashing page. Flash each new board with Erase ticked, and the desk box without.
  2. **Set up box B with the Android:** **Add my box**, then pick the group. The iPhone keeps the desk box (box A).
  3. **Start the ride.** On both phones, turn on Diagnostics, then **Start ride**. Put the boxes at opposite ends of the room.
  4. **Talk both ways.** Count to ten on the Android, then answer from the iPhone. Then both talk at once.
  5. **Try each speed.** In Field test, pick **Furthest** on both phones and talk. Then **Far**, then **Fast**.
  6. **Load the radio.** On **Furthest**, set pretend talkers to 4 on the Android for 30 s while the iPhone rider talks. Then set it to 3.
  7. **Cut box B's power for 15 s,** then plug it back in.
  8. **Optional, with a third board:** add it to the room, powered. No phone is needed.
  9. **Share the logs.** Tap **Stop**, then **Share log** on both, and send them to the Mac.

  Expected:
  - **Step 3:** each box line shows `1 box, best …` within 3 s, and each phone lists the other rider.
  - **Step 4:** each hears the other clearly. This is now through two boxes over ESP-NOW. relayed stays 0 on both.
  - **Step 5:** voice works at every speed, and the box line shows the speed picked.
  - **Step 6:** at 4 pretend talkers, the iPhone rider isn't heard and the Android box's cap count rises; at 3, the iPhone rider is heard. The fill stats show the loss for each speed.
  - **Step 7:** within about 5 s, box A shows no other boxes and the iPhone says "[name] dropped off". When power returns, box B comes back and box A lists it again. The Android may need the Connect tap to rejoin its box (a known Plan A follow-up), and then the iPhone says "[name] is back".
  - **Step 8:** all boxes list 2 neighbours, and relayed stays 0 (a bunched group).

- [ ] **Step 4: Write it up.**
  - A dated "Plan C bench" entry in test-plan §5: each expected line with pass or fail; the fill loss and round trip at each speed (from the logs); the founder's words on quality.
  - Rule on anything that failed. Fixes get failing tests first.

- [ ] **Step 5: Hand over.** Suggested message: `docs: Plan C bench results`.

---

### Task 11: Field tests FT1 to FT5, and write-up

**Files:**
- Modify:
  - `docs/test-plan.md` §2 (device matrix) and §5
  - `docs/spec.md` §10: U1, U2, U3 and U8, each with a dated answer
  - `docs/hardware.md` §4: the antenna position
  - `docs/decisions.md`: radio speed, antenna position and N, with the numbers behind each
  - `docs/todo.md`

**Interfaces:**
- Consumes: everything above, on 2 or 3 bikes with boxes mounted as hardware.md §4 says.

- [ ] **Step 1: 👤 Before riding.**
  - Fill in the device matrix: phones, OS versions and intercoms. Box positions go in words.
  - Turn on Diagnostics on every phone.
  - Check that each box line shows the others at the meeting point.

- [ ] **Step 2: 👤 FT1, range per hop** (2 bikes, a quiet straight road, low speed, within traffic law).
  - For each antenna position (tail, handlebar, windscreen) and each speed (**Furthest**, **Far**, **Fast**, set at a stop on both phones):
    - ride apart slowly until "[name] dropped off"
    - then close in until "[name] is back"
  - Share the logs after each position.

- [ ] **Step 3: 👤 FT2, capacity** (parked, 3 boxes). For each speed, step pretend talkers 0 → 4 on one phone, 30 s each, while the other riders talk.

- [ ] **Step 4: 👤 FT3, a relay chain** (3 bikes in a line). Space them so the end boxes can't hear each other directly: each end box's line shows 1 box. Talk from each end for 2 minutes.

- [ ] **Step 5: 👤 FT4 and FT5** (a 30-minute ride with all screens locked, and regroups at lights).
  - During it, call each rider: answer with the intercom button, then with auto-answer where the intercom has it, then decline one, then make an outgoing call.
  - Share every log afterwards.

- [ ] **Step 6: Work out the numbers from the logs.** Use an ad-hoc script in the scratchpad.

  | Test | Numbers |
  |---|---|
  | FT1 | GPS distance and RSSI at each `peer_lost` and `peer_back`, by position and speed |
  | FT2 | fill loss and round trip per pretend-talker step and speed, and the boxes' cap and air drops |
  | FT3 | end-to-end round trip and loss across the chain, with the middle box's relayed count and the far phone's `ttl=15` |
  | FT4 | box link up % and internet up %, rejoin times, and any app deaths |
  | FT5 | each call's ringtone, silence both ways, resume time, and whether the box kept relaying |

- [ ] **Step 7: Write it up.**
  - A dated "Plan C field tests" entry in test-plan §5, with pass or fail against each test's proposed pass line.
  - U1, U2, U3 and U8 answered in spec §10.
  - **decisions.md:** the default radio speed and N from FT1 and FT2. Change the firmware default, with a host test, if FT1 and FT2 overrule 500 kbps. Also the antenna position.
  - **todo M1:**
    - tick `vroo_protocol` (relay, bridge and cap rules: bridge rules stay for M2, so split the line), the mesh simulator, box firmware v0, the flashing page, replay protection, and the "pretend extra talkers" and GPS parts of diagnostics
    - add what the field tests found
  - Box design go or no-go input: write a short paragraph for the founder, in plain words. The decision itself waits for Plan D (todo M1's last item).

- [ ] **Step 8: Hand over.** Suggested message: `docs: Plan C field test results`.

**Plan C is done when:**
- every suite passes: `dart test` (vroo_protocol, vroo_opus, sim), `flutter test` (vroo_audio, vroo_net, the app), the firmware host tests, both Kotlin suites, and `idf.py build`
- the Task 4 and 5 desk checks, the Task 10 bench and the Task 11 field tests are written up, whether they passed or failed
