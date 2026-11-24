# Plan E: Mobile Data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Riders talk over mobile data with no box. Each phone sends its packets to a small self-hosted relay server, which passes them to the group's other phones.
- Riders with a box use the box and mobile data together, and the first copy wins.
- A "Box only" mode keeps a rider off mobile data.
- A phone with both a box and data bridges box-only riders to the internet ones.
- The relay server ships as one binary and a container image, with a deployment guide.

**Architecture:**
- **`vroo_protocol`** gains the rules the relay server needs, as pure Dart:
  - the address table, the rate limiter and the talker cap, shared with the boxes (Plan C)
  - `ReplayGuard`, moved here from Plan C's Task 1, because packets crossing a relay can be replayed as easily as radio ones (D33)
- **`server/` (`vroo_relay`)** is a Dart UDP relay (architecture §4.9):
  - one port, where every datagram is groupTag ‖ packet
  - it forwards to every other address of that group heard in the last 30 s
  - it never decrypts
- **The app's `BoxLink` becomes `GroupLink`, with two paths:**
  - the box, unchanged
  - the relay, through `vroo_net.sendToInternet`, which already rides mobile data while the box's Wi-Fi is up
  - It sends each packet on every path the path policy has on, keeps the first copy that arrives, and remembers each rider's last path.
- **The path policy** (architecture §4.3, minus Bluetooth, which waits for Plan D) and the internet bridge (§6.4) live in `GroupLink`.
- **Riding without a box** becomes possible.

**Tech Stack:**
- Dart 3.13 with `dart:io` UDP, for the relay server. It cross-compiles to Linux with `dart compile exe --target-os linux`.
- Docker, for the container image.
- No new packages.

**Spec:**
- [docs/spec.md](../../spec.md): G4, G9, G10, §5 ("A rider who falls out of box range but has signal stays in the conversation"), §6.4 (the path table), §7.3 (CO1, CO4–CO8, CO10), §7.5 ("quiet changes"), PS1, and PS4.
- [docs/architecture.md](../../architecture.md): §4.3, §4.9, §5.2, §5.4 and §6.4.
- Decisions D4, D11, D12, D20, D26 and D33.

**Where this sits:** next, by D33, ahead of Plan C (box mesh) and Plan D (Bluetooth). Not in this plan:

- Bluetooth and its "slow data" switching (Plan D), and the local bridge between Bluetooth and the box
- the boxes' radio (Plan C)
- tappable https invite links and a TCP fallback (M3)
- a public relay: each group or company hosts its own (D26)

## Global Constraints

- **Plans A and B still apply.** That covers:
  - protocol v1, the box and the invite
  - the ride-log format and the 👤 checklists
  - no personal data in the repository
  - closed source (D31): the header comment, permissive dependencies only, `publish_to: none`. *Since 2026-11-25, D34: open source, so new files carry the SPDX line instead (GPL-3.0-or-later; AGPL-3.0-or-later in `server/`).*
  - the founder commits: each task ends with a "Hand over" step, and the executor never commits
- **Device steps (👤)** wait for the founder's sessions. The executor finishes every device-free step first.
- **Never reinstall an app while a ride is under way in a founder session** (2026-11-18 lesson). Install builds at a break, and say so first.
- **The relay server:**
  - UDP port 47100 by default (`--port`), IPv4.
  - A datagram is accepted when it's 39–512 bytes and its body parses as a protocol v1 header (`decodeHeader`).
  - Addresses are keyed by (IP, port), so a phone behind carrier NAT is reached at the address it last sent from. An address not heard for 30 s is forgotten.
  - Each datagram goes to every other address in the group, never back to its sender.
  - Talker cap per group, the same rule as the boxes: N = 4, a rider is active while their VOICE or FILL was forwarded in the last 1000 ms, and BEAT and ECHO are never capped.
  - Rate limits:
    - per address, a token bucket of 200 a second with a burst of 400
    - per group, 2000 a second with a burst of 4000
    - over a limit, the datagram is dropped
  - No payload is read or stored. Every 10 s it logs one line of counters: `groups addresses rx tx drop_size drop_rate drop_cap`.
- **The phone's data path:**
  - It's on while a relay address is set, the internet probe last succeeded, and (there's no box, or the mode is **Box + data**).
  - The box path is on whenever a box is set up. Sends are fire and forget.
  - Both paths carry the same envelope (groupTag ‖ packet), so dedupe and `ReplayGuard` keep the first copy.
- **Modes (G10, CO5):** `Box + data` (the default) and `Box only`. A rider without a box always uses data.
- **Heartbeat flags follow the real state** (the todo M2 item):
  - `hasBox`: the box answered in the last 3 s
  - `hasInternet`: the data path is on
- **Internet bridge (§6.4):**
  - A phone bridges when its data path and its box are both up, and no rider heard over the box in the last 4000 ms has both `hasInternet` and `hasBox` with a lower rider ID.
  - It uploads the box-heard packets of riders whose heartbeat says no internet.
  - It sends into its box, with ttl 16, the relay-heard packets of riders not heard over the box for 4000 ms.
  - The election reruns every heartbeat.
- **Replay protection:** exactly Plan C's Task 1 rules:
  - a 1024 window per (src, session)
  - VOICE and ECHO only within 40 s of an accepted BEAT of the session
  - a BEAT's sentAt (now the wall clock, ms since the Unix epoch, low 32 bits) within ±10 minutes
  - sessions forgotten after 10 minutes
- **The relay setting:**
  - `host` or `host:port`, port 47100 if left out.
  - The host is resolved after the internet probe first succeeds, and again if it fails to resolve.
  - It's kept with the rider's other settings in `RiderStore`.
- **Spoken messages (spec 7.5):**
  - Changes of path are quiet.
  - "Your box is disconnected" plays only for a rider with a box.
  - "You've lost the group" counts every path.
- **Log kinds added:** `path` (data on or off, the mode, the relay resolved) and `bridge` (on or off).
- **Hosting (D26):**
  - The repository's guide describes a small Linux VM with a public IPv4 address and UDP 47100 open, about $5 a month, without naming providers.
  - Running a relay on the internet is the founder's decision (Task 8).

## Review Focus

1. **Patchy mobile data:** a rider's data drops and returns mid-ride. The data path turns off when the probe fails, the box (if any) carries on meanwhile, and the data path comes back by itself within 10 s of the internet returning (CO8). There's no gap and no double play. Test: Task 4, "the data path follows the internet probe, off and back on".
2. **Carrier NAT moves a phone's public address mid-ride.** The relay reaches the phone at its new address from its next heartbeat. The old address is forgotten within 30 s, and nothing plays twice. Test: Task 3, "a phone whose address changes is reached at the new one".
3. **Junk at the relay:** garbage, oversized datagrams, another group's packets, a flood from one address. It never crashes, never crosses groups, drops and counts the excess, and other addresses keep working. Tests: Task 3's size, group and rate tests.
4. **Two phones both bridge for a moment, or the bridge rides away.** Dedupe drops the extra copies, and another phone takes over within one heartbeat. Tests: Task 6, "the lowest-ID phone with box and data bridges, and a second steps down" and "when the bridge leaves, the next takes over".
5. **The mode or relay address changes during a ride.** It takes effect within a second, without restarting the ride. Test: Task 5, "switching to Box only stops sending to the relay within a second".

---

## File structure

```
packages/vroo_protocol/
  lib/src/replay_guard.dart          ReplayGuard, ReplayVerdict                         (Task 1)
  lib/src/relay_rules.dart           RelayTable, RateLimiter, TalkerCap, relay constants (Task 2)
server/                              vroo_relay: pubspec, bin/vroo_relay.dart, lib/relay_server.dart, Dockerfile,
                                     README.md (deployment), test/relay_server_test.dart  (Task 3)
app/lib/net/group_link.dart          was box_link.dart: two paths, peers' last path, real flags (Tasks 1, 4, 6)
app/lib/net/relay_address.dart       RelayAddress, parseRelayAddress                     (Task 4)
app/lib/ride/ride_engine.dart        optional box, the relay, the mode                   (Task 5)
app/lib/ui/ride_screen.dart, home_screen.dart, app/lib/rider_store.dart                  (Task 5)
app/test/fake_relay.dart             phones joined to a fake relay, alone or with a FakeBox (Task 4)
```

---

### Task 1: Replay protection on phones

This is Plan C's Task 1, moved here by D33, with its tests and steps as written there. Do it from [the Plan C document](2026-10-31-plan-c-box-mesh.md#task-1-replay-protection-on-phones), on `BoxLink`; Task 4 renames the class.

**Files, interfaces and steps:** as in Plan C's Task 1. When this task is done, mark Plan C's Task 1 "done in Plan E" in the Plan C document.

- [ ] **Step 1: Do Plan C Task 1's Steps 1–10.**

Run: `cd packages/vroo_protocol && dart test`, then `cd app && flutter test && flutter analyze`.
Expected: all pass, and "No issues found!"

- [ ] **Step 2: Hand over.** Suggested message: `feat(protocol): replay protection on phones; heartbeats carry the wall clock`.

---

### Task 2: The relay's rules in `vroo_protocol`

**Files:**
- Create: `packages/vroo_protocol/lib/src/relay_rules.dart`, `packages/vroo_protocol/test/relay_rules_test.dart`
- Modify: `packages/vroo_protocol/lib/vroo_protocol.dart` (export), `docs/architecture.md` §4.9

**Interfaces:**
- Consumes: `groupTagSize`, `headerSize`, `aeadTagSize`, `decodeHeader`, `PacketType`.
- Produces:
  ```dart
  const relayPort = 47100, maxRelayDatagram = 512, relayForgetMs = 30000;

  /// Which addresses of each group the relay forwards to. Addresses are opaque keys (the server uses "ip:port").
  class RelayTable {
    RelayTable({this.forgetMs = relayForgetMs});
    /// Records that [address] sent for [groupTag] (hex) at [nowMs], and returns where to forward it: every other
    /// address of that group heard within forgetMs.
    List<String> heard(String groupTag, String address, int nowMs);
    int get groups;   int get addresses;   // live, for the log
  }

  /// A token bucket: [perSecond] tokens a second, holding at most [burst].
  class RateLimiter { RateLimiter({required this.perSecond, required this.burst}); bool take(int nowMs); }

  /// At most [n] riders' voice at once (the boxes and the relay alike, architecture §4.8 and §4.9).
  class TalkerCap { TalkerCap({this.n = 4, this.activeMs = 1000}); bool admit(int src, int nowMs); int active(int nowMs); }

  /// The header of a relay datagram, or null unless it's 39–512 bytes with a protocol v1 header.
  ({String groupTag, PacketHeader header})? parseRelayDatagram(Uint8List d);
  ```
- Plan C's Task 2 then uses this `TalkerCap` instead of defining one. Edit its Interfaces block to say so when this task is done.

- [ ] **Step 1: Write the failing tests** in `relay_rules_test.dart`:

```dart
test('the relay forwards to every other address of the group', () {
  final t = RelayTable();
  expect(t.heard('aa', 'A', 0), isEmpty);
  expect(t.heard('aa', 'B', 10), ['A']);
  expect(t.heard('aa', 'A', 20), ['B']);
  expect(t.heard('bb', 'C', 30), isEmpty); // another group
});
test('an address not heard for 30 s is forgotten', () {
  final t = RelayTable()..heard('aa', 'A', 0);
  expect(t.heard('aa', 'B', 30000), ['A']);
  expect(t.heard('aa', 'B', 30001), isEmpty);
});
test('a bucket of 200 a second allows a burst of 400, then 200 a second', () {
  final r = RateLimiter(perSecond: 200, burst: 400);
  expect(List.generate(401, (_) => r.take(0)).where((ok) => ok).length, 400);
  expect(List.generate(201, (_) => r.take(1000)).where((ok) => ok).length, 200);
});
test('the cap admits four talkers and refuses a fifth', () {
  final cap = TalkerCap();
  for (final src in [1, 2, 3, 4]) { expect(cap.admit(src, 0), isTrue); }
  expect(cap.admit(5, 500), isFalse);
  expect(cap.admit(1, 999), isTrue);
  expect(cap.admit(5, 1000), isFalse);
  expect(cap.admit(5, 1001), isTrue);
});
test('a relay datagram needs 39 to 512 bytes and a v1 header', () {
  final ok = unhex('$tagHex$sealed');   // the shared test vector (test/fixtures.dart)
  expect(parseRelayDatagram(ok)!.groupTag, tagHex);
  expect(parseRelayDatagram(ok.sublist(0, 38)), isNull);
  expect(parseRelayDatagram(Uint8List(513)..setRange(0, ok.length, ok)), isNull);
  expect(parseRelayDatagram(Uint8List.fromList(ok)..[8] = 2), isNull);   // version 2
});
```

- [ ] **Step 2: Run them.** `cd packages/vroo_protocol && dart test test/relay_rules_test.dart`. Expected: FAIL, `RelayTable` isn't defined.

- [ ] **Step 3: Implement `relay_rules.dart`**, and export it. In `RelayTable`, expired addresses are purged lazily, at most once a second.

- [ ] **Step 4: Run them.** `cd packages/vroo_protocol && dart test`. Expected: all pass.

- [ ] **Step 5: Update the docs.** In architecture §4.9: the port 47100, 39–512 bytes, keys by IP and port, the two rate limits, and the 10 s counter line.

- [ ] **Step 6: Hand over.** Suggested message: `feat(protocol): relay rules: address table, rate limits, talker cap`.

---

### Task 3: The relay server

**Files:**
- Create:
  - `server/pubspec.yaml`: `vroo_relay`, `publish_to: none`, sdk ^3.13.7, `vroo_protocol` by path; dev `lints` and `test`
  - `server/analysis_options.yaml`, `server/.gitignore`
  - `server/bin/vroo_relay.dart`, `server/lib/relay_server.dart`, `server/test/relay_server_test.dart`
  - `server/Dockerfile`, `server/README.md`
- Modify: `docs/development.md` (server rows), and `docs/architecture.md` §3 (`server/` is no longer future work)

**Interfaces:**
- Consumes: Task 2's `RelayTable`, `RateLimiter`, `TalkerCap`, `parseRelayDatagram` and `relayPort`.
- Produces:
  ```dart
  class RelayServer {
    static Future<RelayServer> bind({int port = relayPort, InternetAddress? address, int Function()? nowMs});
        // anyIPv4 and the real clock by default; tests pass port 0 and a clock they drive
    int get port;                     // the bound port (tests bind 0)
    Map<String, int> get counters;    // rx, tx, drop_size, drop_rate, drop_cap
    String statusLine();              // groups=… addresses=… rx=… tx=… drop_size=… drop_rate=… drop_cap=…
    Future<void> close();
  }
  ```
- `bin/vroo_relay.dart [--port 47100]` prints `statusLine()` every 10 s and stops cleanly on SIGINT or SIGTERM.
- The image is a multi-stage build: `dart:3.13.7` compiles the AOT binary, and the final stage is `scratch` with `/runtime/` copied from the build stage, `EXPOSE 47100/udp`.

- [ ] **Step 1: Write the failing tests.** They use real UDP on 127.0.0.1, a server bound to port 0, and client sockets:
  - **`a datagram reaches the group's other phone, and not another group's`:** A, B (group aa) and C (group bb) each send once. Then A's datagram arrives at B, not at C, and not back at A.
  - **`a phone whose address changes is reached at the new one`:** A sends from socket A1, then from a new socket A2. B's next datagram arrives at A2. The relay forgets A1 30 s later. Drive the clock: the server takes an injectable `int Function() nowMs`.
  - **`junk, oversized and old-version datagrams are dropped and counted`:** 10 bytes, 600 bytes, and a version-2 header add 3 to `drop_size`, and nothing is forwarded.
  - **`a flood from one address is limited, and others still get through`:** 1000 datagrams from A in one clock instant forward at most 400 (the burst), counting the rest in `drop_rate`. A datagram from B still forwards.
  - **`a fifth talker's voice is dropped, but heartbeats get through`:** VOICE from srcs 1–5 (headers patched from the shared vector), then a BEAT from src 6.
  - **`the status line has every counter`**.

- [ ] **Step 2: Run them.** `cd server && dart pub get && dart test`. Expected: FAIL, `RelayServer` isn't defined.

- [ ] **Step 3: Implement the server.** A datagram goes through `parseRelayDatagram`, then the address limit, then the group limit, then the cap for VOICE and FILL, then `RelayTable.heard`, then a send to each target.

- [ ] **Step 4: Run them.** `cd server && dart test && dart analyze`. Expected: all pass, and no issues.

- [ ] **Step 5: Build both forms.**
  - `cd server && dart compile exe bin/vroo_relay.dart -o build/vroo_relay && dart compile exe --target-os linux --target-arch x64 bin/vroo_relay.dart -o build/vroo_relay-linux-x64`. Expected: two binaries.
  - If Docker is running: `docker build -t vroo-relay server && docker run --rm -d -p 47100:47100/udp --name vroo-relay vroo-relay`, then `docker logs vroo-relay` within 15 s. Expected: a status line.
  - If Docker isn't running, record that in the ledger and move on. The binary is enough for Task 7.

- [ ] **Step 6: Write `server/README.md`**, for whoever runs a relay: a founder, a club or a company.
  - **What it is:** it forwards a group's encrypted packets and can't read them.
  - **What it needs:** a small Linux VM with a public IPv4 address and UDP 47100 open, about $5 a month.
  - **Running it**, either way:
    - copy `vroo_relay-linux-x64` and run it under systemd (a unit file is given in full)
    - or run the container
  - **Checking it:** the 10 s status line.
  - **Pointing the app at it:** the Relay server setting.

- [ ] **Step 7: Hand over.** Suggested message: `feat(server): UDP relay server, binary and container image`.

---

### Task 4: `GroupLink`: the internet path

**Files:**
- Rename: `app/lib/net/box_link.dart` to `app/lib/net/group_link.dart`, with `BoxLink` to `GroupLink` and `BoxLinkState` to `GroupLinkState`. Update every import and test, and rename `app/test/box_link_test.dart` to `group_link_test.dart`.
- Create: `app/lib/net/relay_address.dart`, `app/test/fake_relay.dart`, `app/test/relay_address_test.dart`
- Modify: `app/lib/net/peer.dart`; `docs/architecture.md` §4.3 (the Router is `GroupLink`) and §5.3 (the `hasBox` flag)

**Interfaces:**
- Consumes: Task 1's `ReplayGuard`; `vroo_net`'s `sendToInternet` and `InternetDatagram`; `probeInternet`.
- Produces:
  ```dart
  class RelayAddress { const RelayAddress(this.host, this.port); final String host; final int port; }
  RelayAddress? parseRelayAddress(String text);   // "relay.example.org", "203.0.113.5:47100"; null if malformed
  enum RidePath { box, internet }
  // PeerInfo gains: RidePath? lastPath; bool hasBox = false, hasInternet = false; int? lastBoxMs, lastInternetMs;
  class GroupLink {
    GroupLink({…as BoxLink…, required this.boxSetUp, RelayAddress? relay, BoxMode mode = BoxMode.boxAndData});
    final bool boxSetUp;                             // a box is set up (the heartbeat's hasBox is whether it answers)
    RelayAddress? relay;  BoxMode mode;              // settable mid-ride (Task 5)
    bool get dataPathOn;                             // the Global Constraints' rule
  }
  // GroupLinkState gains: bool dataPathOn; bool bridge (Task 6; false here)
  enum BoxMode { boxAndData, boxOnly }               // in group_link.dart
  ```
- `FakeRelay` (test helper):
  - `join()` gives a `FakeVrooNet` whose sends to the relay's address arrive at every other joined net as `InternetDatagram`s from that address.
  - `attach(FakeVrooNet)` adds an existing `FakeBox` net, so a phone can be on both.
  - Its nets answer DNS probes.

- [ ] **Step 1: Rename.** `BoxLink` becomes `GroupLink` everywhere.

Run: `cd app && flutter test && flutter analyze`.
Expected: all pass, and no issues. A pure rename, so no behaviour changes.

- [ ] **Step 2: Write the failing tests.**
  - **relay_address_test:**
    - `a host alone gets port 47100`
    - `a host and a port`
    - `malformed addresses are refused` (empty, `:47100`, `host:0`, `host:70000`, `host:port`)
  - **group_link_test**, phones on a `FakeRelay`, no box:
    - `two phones with no box hear each other through the relay`: each lists the other, voice arrives, and `lastPath == RidePath.internet`.
    - `a packet that arrives by both paths plays once`: phones on a FakeBox and the FakeRelay.
    - `each rider's last path is kept`: box only, then the relay only.
    - `the data path follows the internet probe, off and back on`: probes fail, so nothing more goes to the relay. When probes succeed again, sends resume within 5 s.
    - `heartbeat flags follow the real state`:
      - `hasBox` is set only while the box answers
      - `hasInternet` is set only while the data path is on
    - `without a relay address the data path stays off`.

- [ ] **Step 3: Run them.** `cd app && flutter test`. Expected: the new tests FAIL.

- [ ] **Step 4: Implement the internet path in `GroupLink`.**
  - `_send` puts the envelope on every path that's on.
  - Datagrams from the resolved relay address and port are packets on the internet path.
  - Resolve the host with `InternetAddress.lookup` after a successful probe, preferring IPv4, and log `path,relay=<ip>:<port>` once.

- [ ] **Step 5: Run them.** `cd app && flutter test && flutter analyze`. Expected: all pass, and no issues.

- [ ] **Step 6: Hand over.** Suggested message: `feat(app): GroupLink sends on the box and over mobile data through the relay`.

---

### Task 5: The path policy, the two modes, and riding without a box

**Files:**
- Modify:
  - `app/lib/ride/ride_engine.dart`: `SavedBox? box`, `RelayAddress? relay` and `BoxMode mode`, set mid-ride; no `BoxConnection` without a box
  - `app/lib/ui/ride_screen.dart`: no box line without a box; a paths line; each rider's path
  - `app/lib/ui/home_screen.dart`: Start ride needs only a name and a group; a Relay server field; a Mode choice shown when a box is set up
  - `app/lib/rider_store.dart`: `relayServer`/`saveRelayServer`, and `boxMode`/`saveBoxMode`
  - `docs/spec.md` §6.4: "the switch" now covers box and data, with Bluetooth in Plan D
- Test: `app/test/ride/ride_engine_test.dart`, `app/test/ride_screen_test.dart`, `app/test/ride/ride_harness.dart` (phones on a box, on the relay, or both)

**Interfaces:**
- Consumes: Task 4.
- Produces:
  - `RideEngine({…, SavedBox? box, RelayAddress? relay, BoxMode mode = BoxMode.boxAndData})`, with setters `relay` and `mode`.
  - `RideScreen` and `RideView` take `SavedBox? box`.
  - **Ride screen:**
    - a line `Paths: box ✓ · data ✓`, with ✗ for a path that's off, and `data off (Box only)` in that mode
    - rider rows whose subtitle starts with `box ·` or `internet ·`
  - **Home screen:**
    - a "Relay server" text field, saved as typed and checked with `parseRelayAddress`, with a hint when it's malformed
    - "Mode" radio buttons, **Box + data** and **Box only**
  - **Alerts:** RideEngine passes `boxUp: box == null || state.boxUp`, so a rider with no box never hears the box warning.

- [ ] **Step 1: Write the failing tests.**
  - **ride_engine_test:**
    - `riders with no box talk over the relay`
    - `a rider with no box never hears "Your box is disconnected"`
    - `in Box only mode nothing goes to the relay`
    - `switching to Box only stops sending to the relay within a second`
    - `a rider on the box and one on the relay hear each other when the box rider has data`: Box + data, without a bridge
  - **ride_screen_test:**
    - `the paths line shows box and data`
    - `Box only says so`
    - `a rider heard over the internet says internet`
    - `with no box there is no box line`

- [ ] **Step 2: Run them.** `cd app && flutter test`. Expected: the new tests FAIL.

- [ ] **Step 3: Implement.** Changing the mode or the relay mid-ride sets them on `GroupLink`, logs `path,mode=…` or `path,relay=…`, and needs no restart.

- [ ] **Step 4: Run them.** `cd app && flutter test && flutter analyze`. Expected: all pass, and no issues.

- [ ] **Step 5: Hand over.** Suggested message: `feat(app): box and data paths, Box only mode, riding without a box`.

---

### Task 6: The internet bridge

**Files:**
- Modify: `app/lib/net/group_link.dart`, `app/test/group_link_test.dart`, `app/lib/ui/ride_screen.dart` (one line), `docs/architecture.md` §6.4 (as built)

**Interfaces:**
- Consumes: Task 4's `PeerInfo` fields, and Task 5's modes.
- Produces: `GroupLinkState.bridge`; the log `bridge,state=on|off`; and the ride screen line "This phone links the box riders to the internet", shown while bridging.

- [ ] **Step 1: Write the failing tests.** The setup: three phones.
  - **Phone 1** is on the box only, in **Box only** mode.
  - **Phone 2** is on the box and the relay, with **Box + data**.
  - **Phone 3** is on the relay only.

  The tests:
  - **`a box-only rider and an internet-only rider hear each other through the bridge`:** phone 2 bridges, phone 1's voice reaches phone 3, and phone 3's voice reaches phone 1.
  - **`the lowest-ID phone with box and data bridges, and a second steps down`:** add phone 4 (box and relay, lower ID). Phone 4 bridges, and phone 2 stops within one heartbeat. Each frame still plays once on phones 1 and 3.
  - **`when the bridge leaves, the next takes over`:** phone 4 stops. Phone 2 bridges again within 5 s.
  - **`a bridge uploads only riders without data`:** phones 2, 3 and 4, with phone 1 gone. By §6.4, phone 4 still bridges, but every packet it sends to the relay is its own: riders with data upload their own.
  - **`a bridged packet goes into the box with ttl 16`:** check the envelope the bridge sends to the box.

- [ ] **Step 2: Run them.** `cd app && flutter test test/group_link_test.dart`. Expected: the new tests FAIL.

- [ ] **Step 3: Implement the election and forwarding** in `GroupLink`, as the Global Constraints say. The election runs in `_tick`. Forwarding happens when a packet is first heard: after `ReplayGuard`, and before it's handled.

- [ ] **Step 4: Run them.** `cd app && flutter test && flutter analyze`. Expected: all pass, and no issues.

- [ ] **Step 5: Hand over.** Suggested message: `feat(app): internet bridge for box-only riders`.

---

### Task 7: Desk bench: mobile data through a relay on the Mac, and the rest of Plan B's bench

**Files:**
- Modify: `docs/test-plan.md` §5, `docs/todo.md`, `docs/development.md` (the bench relay commands)
- Plan B's ledger: Tasks 6, 7 and 11, closed or left open with their reasons

**Interfaces:**
- Consumes: everything above, on both desk phones and the desk box.

- [ ] **Step 1: 👤 Before the session.** On the Android, open Settings → Apps → Vroo → Battery and turn on **Allow background activity**. Check Vroo isn't in Sleeping or Deep sleeping apps (Plan B bench, 2026-11-18).

- [ ] **Step 2: 🖥 Start the relay on the Mac.**
  - Start it in Terminal.app, not the editor's shell: `osascript -e 'tell application "Terminal" to do script "<repo>/server/build/vroo_relay --port 47100"'`. On this Mac the editor's Local Network permission is stuck on denied, so its replies to the phones would fail with "No route to host", as the box probe did in Plan A.
  - Note the Mac's home Wi-Fi address with `ipconfig getifaddr en0`. Don't write it into the repository.
  - macOS may ask to allow incoming connections: 👤 tap Allow.
  - Install the release builds on both phones **before** the founder starts any ride.

- [ ] **Step 3: 👤 The checklist.** Read it aloud.
  1. **No box:** both phones on the home Wi-Fi. In each, set Relay server to the Mac's address, then **Start ride**. Talk both ways.
  2. **Lock both phones for 10 minutes,** and talk every 2 minutes.
  3. **Android:** swipe Vroo away, lock it, and talk.
  4. **iPhone:** close Vroo, reopen it, and **Start ride**.
  5. **Call the iPhone.** Answer with the earphones and hang up after 20 s.
  6. **Siri** on the iPhone during the ride.
  7. **A navigation prompt** on the Android during the ride.
  8. **🖥 Stop the relay for 10 s** (Ctrl-C in its Terminal window), then start it again.
  9. **The Android's clock:** turn off automatic date and time, set the clock 15 minutes ahead, wait 15 s, then turn automatic time back on.
  10. **Stop both, then Share log** from both.

  Expected:
  - **Step 1:** each lists the other with `internet ·`; voice is clear both ways; `Paths: box ✗ · data ✓`; the relay's status line shows 2 addresses.
  - **Step 2:** voice keeps working while locked, and the Android notification stays.
  - **Step 3:** the ride keeps going.
  - **Step 4:** they hear each other again within a few seconds.
  - **Step 5:** the ringtone is normal; the group is silent both ways during the call; the Android hears "iPhone is on a call"; the group is back within 2 s of hanging up.
  - **Step 6:** the iPhone shows "paused", then comes back by itself.
  - **Step 7:** the prompt plays over the group without cutting it off.
  - **Step 8:** both hear each other again within 10 s of the relay coming back. If the iPhone stays deaf, its internet connection stopped receiving after an error without being replaced (final review, recommendation 2): fix it with a failing test first.
  - **Step 9:** within a few seconds both screens show the clock line ("… are 15 min apart"), and both say "The phone clocks are too far apart to hear each other" once. With automatic time back on, they hear each other again within a few seconds.

- [ ] **Step 4: Write it up.**
  - A dated "Plan E desk bench" entry in test-plan §5. Steps 2–7 also close Plan B's bench: record them under it, and close Plan B's Tasks 6, 7 and 11 in its ledger. Then run Plan B's Finish, with its rulings and deferred minors listed for the founder.
  - From the logs: the round trip and loss through the relay.
  - Fixes found here get failing tests first.

- [ ] **Step 5: Hand over.** Suggested message: `docs: Plan E desk bench`.

---

### Task 8: A relay on the internet, and the first mobile-data test

**Files:**
- Modify: `docs/test-plan.md` §5, `docs/todo.md` (the open decision "A relay server for the founder's group"), and `docs/decisions.md` (a dated note on D26: where the founder's relay runs, without account details)

**Interfaces:**
- Consumes: Task 3's binary and guide.

- [ ] **Step 1: 👤 The founder decides on hosting.** The choices are a small VM (about $5 a month) or a free tier that allows UDP. The executor explains the options in chat (naming providers is fine there, not in the repository) and waits for the founder. Nothing is rented or deployed without the founder's go-ahead. Accounts and payment stay with the founder.

- [ ] **Step 2: 🖥 + 👤 Deploy by `server/README.md`.** The founder runs the commands the executor gives, or gives the executor access in the way the founder chooses. The relay's address goes into the founder's phones only, never the repository.

- [ ] **Step 3: 👤 A real mobile-data test.**
  - The iPhone on mobile data only (Wi-Fi off). The Android on the home Wi-Fi (it has no SIM). Both point at the relay.
  - Talk both ways, then lock both for 5 minutes.
  - Then walk the iPhone out of the Wi-Fi area and back.
  - Then the iPhone on the desk box, in **Box + data**, with Relay server set to a **name** that points at the relay (the executor suggests one in chat). Talk both ways.

  Expected:
  - Voice both ways, with a round trip under 300 ms on mobile data.
  - Losing and regaining the signal brings voice back by itself within 10 s (CO8).
  - On the box, the iPhone shows `Paths: box ✓ · data ✓` and hears the Android through the relay: its name was looked up over mobile data, not through the box (final review, I2).

- [ ] **Step 4: Write it up.**
  - test-plan §5, with the round trip and loss.
  - **todo:**
    - tick "Relay server in Dart…" and the internet bridge (M2's "Internet bridge and local bridge" is split: the local bridge stays for Plan D)
    - tick the heartbeat "has box" flag item
  - spec §10: U3's mobile-data half, if the iPhone used both box and data.

- [ ] **Step 5: Hand over.** Suggested message: `docs: first mobile-data test through the internet relay`.

**Plan E is done when:**
- every suite passes: `dart test` (vroo_protocol, vroo_opus, server), `flutter test` (vroo_audio, vroo_net, the app), the firmware host tests, and both Kotlin suites
- Tasks 7 and 8 are written up, pass or fail
