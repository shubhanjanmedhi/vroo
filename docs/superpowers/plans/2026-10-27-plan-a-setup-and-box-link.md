# Plan A: Setup and Box Link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An iPhone and an Android phone, each running the Flutter test app, exchange encrypted heartbeats through one ESP32 box while still reaching the internet over mobile data.

**Architecture:**
- `vroo_protocol` is a pure-Dart package that defines protocol v1: group keys, invite links, packets, sealing, dedupe and box messages. It's tested against vectors from an independent crypto library.
- The box firmware (ESP-IDF, C) runs a WPA2 hotspot and a UDP bridge. The bridge forwards same-group envelopes between the phones on one box. A host-tested `vroo_wire` component holds the parsing and dedupe.
- `vroo_net` is a thin Flutter plugin that joins the box's Wi-Fi and gives the app a box socket and an internet socket. It uses native code only where routing needs it.
- The test app wires these together with a heartbeat loop, a ride log and four screens.

**Tech Stack:**
- Flutter (current stable at setup) and Dart, with the `cryptography`, `qr_flutter`, `flutter_zxing`, `shared_preferences`, `share_plus`, `path_provider`, `permission_handler` and `fake_async` packages.
- Kotlin for Android and Swift for iOS (`Network.framework`, `NetworkExtension`).
- ESP-IDF v5.x in C.
- Python `cryptography`, as the test oracle only.

**Spec:** [docs/spec.md](../../spec.md) and [docs/architecture.md](../../architecture.md). Executors read both. The box is in [docs/hardware.md](../../hardware.md), and the decisions are in docs/decisions.md.

**Where this sits:** M0 and the first slice of M1 ([docs/todo.md](../../todo.md)). The later M1 plans are:

- **Plan B, voice:** `vroo_audio`, Opus, VoicePipeline and talk slots. Voice between the two phones through one box.
- **Plan C, box mesh:** ESP-NOW between boxes, beacons, relay rule, talker cap, simulator, diagnostics, and field tests FT1–FT5.
- **Plan D, Bluetooth fallback:** checking `ble_plus`, and field test FT10.

Not in this plan: voice, box-to-box radio, Bluetooth, the relay server and path policy.

## Global Constraints

- **Platforms:** iPhone on iOS 17 or later. Android 10 or later (minSdk 29).
- **Native code:** one Flutter codebase. Thin native modules only wrap OS APIs that Dart can't reach. Drivers move bytes and frames and make no decisions.
- **Box firmware:** ESP-IDF v5.x, C. The box never holds the group key and reads only the plain routing header and the groupTag.
- **Group secret:** 32 random bytes. Derived values use HKDF-SHA256 with an empty salt:
  - `info="vroo/v1/key"` gives 32 bytes, used for ChaCha20-Poly1305.
  - `"vroo/v1/tag"` gives 8 bytes.
  - `"vroo/v1/ble-ios"` and `"vroo/v1/ble-android"` give 16 bytes each, with the RFC 4122 version 4 and variant bits set.
  - `channel` is 1, 6 or 11, from groupTag[0] % 3.
- **Packet layout:** a 15-byte header: version 1 (u8), type (u8), ttl (u8), src (u32), session (u32), seq (u32). It's followed by the encrypted payload and a 16-byte Poly1305 tag. All integers are big-endian. Types: 1 HELLO, 2 VOICE, 3 BEAT, 4 ECHO, 5 FILL.
- **Encryption:** ChaCha20-Poly1305 with nonce = src ‖ session ‖ seq and AAD = header bytes 0–1 and 3–14. ttl is excluded from the AAD because relays change it.
- **Envelope:** every UDP and ESP-NOW datagram is groupTag (8 bytes) ‖ packet.
- **Dedupe:** the key is (src, session, seq), with a 10 s window.
- **Traffic:** ttl is 16 on packets this phone originates. The heartbeat goes every 1 s (groups of up to 10).
- **The box:**
  - IP 192.168.4.1. WPA2. Up to 4 phones.
  - SSID `Vroo-<box id>`, and `Vroo-setup-<id>` in setup mode.
  - Ports, chosen in this plan: data on 47000, control on 47001.
  - Box message types: 0x10 BOX_CONFIG, 0x11 BOX_STATUS (0x12 BOX_BEACON is reserved for Plan C).
- **Invite:** `vroo://join?v=1&s=<base64url(groupSecret)>&n=<group name>`.
- **Log line:** `ISO-time,seconds,kind,key=value…` (architecture §8).
- **No paid Apple account (D22):** free Personal Team signing and cable installs. Joining the box Wi-Fi by hand in Settings is the expected iOS path.
- **The founder is non-technical.** Every step that needs hands on a device is marked 👤 and written as a plain checklist for them.
- **Dependencies:** no new ones beyond those named in this plan without recording why in decisions.md.
- **Open source forever (D24, D27).** *Superseded 2026-10-28 by D31: Vroo is closed source, and file headers read `Proprietary and confidential. See LICENSE.`* The original rules were:
  - **Licences:** everything committed will be public. Code is under GPL-3.0-or-later, `server/` under AGPL-3.0-or-later, and docs under CC BY-SA 4.0.
  - **New source files** start with an SPDX line, for example `// SPDX-License-Identifier: GPL-3.0-or-later`.
  - **Dependencies** must be GPL-compatible, with no proprietary SDKs.
  - **Commits** are signed off with `git commit -s`.
- **No personal data in commits:** no Apple team IDs (they go in the ignored `Local.xcconfig`), box passwords, group secrets apart from the fixed test vectors, ride logs, or phone serial numbers.

## Review Focus

1. **A datagram from another group or a stranger** reaches the box or a phone. It's dropped (the box counts `dropTag`, the phone logs `drop reason=auth`), never forwarded or shown. Tests: Task 6 (wrong tag), Task 7 probe (wrong tag isn't forwarded), Task 11 (wrong key ignored and logged).
2. **The box loses power or restarts mid-session.** Both phones show the box as down within 3 s and recover by themselves when it's back, rejoining the Wi-Fi on Android. Tests: Task 11 watchdog and rejoin tests; Task 13 bench.
3. **Garbage or truncated datagrams arrive on the Wi-Fi.** Parsers return null or false and nothing throws. Tests: Tasks 3–6 truncation tests; Task 11 random-bytes test.
4. **The app restarts during a ride** and gets a new session. Other phones keep one entry for that rider (same src), and nonces never repeat. Tests: Task 4 new-session dedupe test; Task 11 restart test.
5. **The rider denies a permission, or joins the wrong Wi-Fi.** The screen says what to do; nothing hangs silently. Tests: Task 12 setup times out after 5 s with a message, and `JoinOutcome.denied` shows the instruction.

---

## File structure

```
.gitignore
packages/vroo_protocol/             pure Dart, no Flutter
  lib/vroo_protocol.dart           exports
  lib/src/constants.dart            versions, sizes, ports, type numbers
  lib/src/group.dart                GroupKeys.derive
  lib/src/invite.dart               Invite, encodeInvite, decodeInvite
  lib/src/packet.dart               PacketHeader, encode/decode header, aadOf, nonceOf
  lib/src/envelope.dart             wrapEnvelope, unwrapEnvelope
  lib/src/payloads.dart             Beat, BeatFlags, Echo, Hello, VoiceFrame codecs
  lib/src/crypto.dart               Sealer, Opened
  lib/src/dedupe.dart               Dedupe
  lib/src/box_messages.dart         BoxConfig, BoxStatus, SSIDs, box passwords
  test/…                            one test file per src file, plus hex.dart helper
  tool/oracle.py                    independent vectors (Python cryptography)
  tool/gen_c_vectors.dart           writes firmware/host_test/vectors.h
  tool/box_probe.dart               Mac-side bench test of the box
packages/vroo_net/                  Flutter plugin (android + ios)
  lib/vroo_net.dart                API, events, createVrooNet()
  lib/src/fake_vroo_net.dart       test double
  lib/src/probe.dart                DNS probe codec + probeInternet
  lib/src/channel_vroo_net.dart    platform implementation over the method/event channels
  android/src/main/kotlin/com/getvroo/vroo_net/VrooNetPlugin.kt
  ios/Classes/VrooNetPlugin.swift
  example/                          device "net check" screen
firmware/                           ESP-IDF project "vroo_box"
  components/vroo_wire/            pure C: unwrap, header, dedupe, box messages
  main/                             main.c config.c wifi_ap.c bridge.c led.c button.c Kconfig.projbuild
  host_test/                        CMake build of vroo_wire + tests on the Mac
app/                                Flutter app "vroo"
  lib/main.dart
  lib/diag/clock.dart, ride_log.dart
  lib/net/peer.dart, box_link.dart, box_connection.dart, box_setup.dart
  lib/group/group_store.dart        lib/box/box_store.dart
  lib/ui/home_screen.dart, box_setup_screen.dart, group_screen.dart, test_screen.dart
  test/…
```

---

### Task 1: Toolchains, repository and device prep (M0)

**Files:**
- Create: `.gitignore`, `packages/vroo_protocol/` (scaffold), `packages/vroo_net/` (scaffold), `app/` (scaffold), `firmware/` (scaffold)
- Modify: `docs/development.md` (record versions), `docs/test-plan.md` (desk device rows), `app/ios/Flutter/Debug.xcconfig` and `Release.xcconfig` (add `#include? "Local.xcconfig"`)
- Create (not committed): `app/ios/Flutter/Local.xcconfig`, holding `DEVELOPMENT_TEAM = <team id>`

**Interfaces:**
- Produces:
  - **Repository:** layout as above, on branch `m1-plan-a`.
  - **App IDs:** Android applicationId `com.getvroo.dev` and iOS bundle ID `com.getvroo.dev`. If Xcode says the ID is taken, append `.f1` and record it.
  - **Recorded:** the Flutter and ESP-IDF versions in the README, and the ESP32 chip type (`<chip>` below) in test-plan §2.

- [ ] **Step 1: Install Flutter and CocoaPods**

Run: `brew install --cask flutter && brew install cocoapods`

Then run: `flutter config --android-sdk /opt/homebrew/share/android-commandlinetools --jdk-dir /opt/homebrew/opt/openjdk@17` and `flutter doctor --android-licenses`, answering `y` to every prompt.

Run: `flutter doctor`
Expected: ✓ for Flutter, Android toolchain and Xcode. Missing Chrome and Android Studio are fine.

- [ ] **Step 2: Install ESP-IDF**

Use the newest v5.x release tag listed at https://github.com/espressif/esp-idf/releases. Run: `git clone -b <tag> --recursive https://github.com/espressif/esp-idf.git ~/esp/esp-idf && ~/esp/esp-idf/install.sh esp32,esp32s3,esp32c3`

Run: `. ~/esp/esp-idf/export.sh && idf.py --version`
Expected: `ESP-IDF v5.`…

- [ ] **Step 3: 👤 Founder: plug in the ESP32**

Checklist for the founder:
- Plug the ESP32 into the Mac with a USB cable that carries data. Charge-only cables don't work. If nothing shows up in Step 4, try another cable.
- Tell Claude any text printed on the board or on its metal shield.

- [ ] **Step 4: Identify the chip**

Run: `ls /dev/cu.usb*`. Then, with the port it shows, run: `esptool.py --port <port> chip_id`
Expected: a line `Chip is ESP32…` and a MAC address.

Then:
- Record the chip, the MAC and the port in test-plan §2 as "Desk ESP32".
- Look up whether that chip supports Wi-Fi long-range (LR) mode, in the ESP-IDF Wi-Fi guide for that target. Record the answer in the same row, since Plan C needs it.

- [ ] **Step 5: Create the repository**

Create `.gitignore` covering:
- `build/`, `.dart_tool/`, `.flutter-plugins*`, `**/ios/Pods/`
- `**/android/.gradle/`, `**/android/local.properties`
- `firmware/build/`, `firmware/sdkconfig`, `firmware/sdkconfig.old`, `firmware/managed_components/`, `firmware/host_test/build/`
- `.DS_Store`, `*.iml`
- `app/ios/Flutter/Local.xcconfig`, `ride_*.txt` (ride logs)

Run: `git init -b main && git add -A && git commit -m "docs: approved design docs" && git checkout -b m1-plan-a`
Expected: `Switched to a new branch 'm1-plan-a'`

- [ ] **Step 6: Scaffold the packages, app and firmware**

Run, from the repository root:
- `dart create -t package packages/vroo_protocol`
- `flutter create --template=plugin --platforms=android,ios --org com.getvroo --project-name vroo_net packages/vroo_net`
- `flutter create --org com.getvroo --project-name vroo --platforms=ios,android app`
- `mkdir firmware && cd firmware && idf.py create-project -p . vroo_box && idf.py set-target <chip>`, using the chip from Step 4.

Then set the platform floors and IDs:
- **Android app:** in `app/android/app/build.gradle.kts`, set `minSdk = 29` and `applicationId = "com.getvroo.dev"`.
- **iOS app:** in `app/ios/Podfile`, set `platform :ios, '17.0'`. In `app/ios/Runner.xcodeproj`, set the `IPHONEOS_DEPLOYMENT_TARGET = 17.0` and `PRODUCT_BUNDLE_IDENTIFIER = com.getvroo.dev` build settings.
- **vroo_net plugin:** Android `minSdk 29`, and iOS podspec `s.platform = :ios, '17.0'`.

- [ ] **Step 7: 👤 Founder: prepare both phones**

Checklist for the founder:
- **iPhone:** Settings → Privacy & Security → Developer Mode → On, then restart. On the Mac: Xcode → Settings → Accounts → + → Apple ID, and sign in with your normal Apple ID (it's free).
- **Android:** Settings → About phone → tap "Build number" 7 times. Then Settings → System → Developer options → USB debugging → On.
- **Both:** write down the phone model and its software version. That's Settings → General → About on iPhone, and Settings → About phone on Android. Tell Claude.

Record both phones in test-plan §2 as "Desk iPhone" and "Desk Android".

- [ ] **Step 8: Run the empty app on both phones**

👤 The founder plugs the iPhone into the Mac and taps "Trust" on the phone. Then:
- Open `app/ios/Runner.xcworkspace` in Xcode and set Signing & Capabilities → Team to the Personal Team.
- Move the team ID that Xcode wrote into `project.pbxproj` (`DEVELOPMENT_TEAM`) into `app/ios/Flutter/Local.xcconfig`. Then revert that line in `project.pbxproj`, so the team ID never reaches the public history.
- Run: `cd app && flutter devices`, then `flutter run -d <iphone id>`.
- 👤 On the iPhone: Settings → General → VPN & Device Management → trust the developer.

Expected: the Flutter counter demo appears on the iPhone.

👤 The founder plugs in the Android phone and allows USB debugging. Run: `flutter run -d <android id>`
Expected: the demo appears on the Android phone.

- [ ] **Step 9: Run a first program on the ESP32**

Make `firmware/main/vroo_box.c` log `vroo_box hello` from `app_main`. Then run: `cd firmware && idf.py -p <port> flash monitor`
Expected: `vroo_box hello` in the monitor. Exit with Ctrl+].

- [ ] **Step 10: Record versions and commit**

Record in the Toolchain table of `docs/development.md`: the output of `flutter --version` (first line), the output of `idf.py --version`, and the chip from Step 4.

```bash
git add -A
git commit -m "chore: scaffold app, packages and firmware; record toolchain versions"
```

---

### Task 2: vroo_protocol: constants, group keys and invite links

**Files:**
- Create: `packages/vroo_protocol/lib/src/constants.dart`, `lib/src/group.dart`, `lib/src/invite.dart`, `lib/vroo_protocol.dart`, `test/hex.dart`, `test/group_test.dart`, `test/invite_test.dart`, `tool/oracle.py`

**Interfaces:**
- Produces:
  - `constants.dart`:
    ```dart
    const int protocolVersion = 1;
    const int headerSize = 15, aeadTagSize = 16, groupTagSize = 8, secretSize = 32;
    const int originTtl = 16, dedupeWindowMs = 10000;
    const String boxIp = '192.168.4.1';
    const int boxDataPort = 47000, boxControlPort = 47001;
    abstract final class PacketType { static const hello = 1, voice = 2, beat = 3, echo = 4, fill = 5; }
    abstract final class BoxMsgType { static const config = 0x10, status = 0x11; }
    ```
  - `class GroupKeys { final Uint8List secret, key, tag; final int channel; final String bleIos, bleAndroid; static Future<GroupKeys> derive(Uint8List secret); }`. `derive` throws `ArgumentError` unless the secret is 32 bytes.
  - `class Invite { final Uint8List secret; final String name; }`, `String encodeInvite(Invite i)` and `Invite? decodeInvite(String text)`.
  - Test helpers: `String hex(List<int>)` and `Uint8List unhex(String)`.

- [ ] **Step 1: Write the failing tests**

```dart
// test/group_test.dart
final secret = Uint8List.fromList(List.generate(32, (i) => i));

test('derives the v1 group values', () async {
  final k = await GroupKeys.derive(secret);
  expect(hex(k.key), '5d5963441c8d63c15877eaf570cfa8636c65e94ab6b39abdb3fa0e26fb072d72');
  expect(hex(k.tag), 'a9968d2a1c900625');
  expect(k.channel, 6);
  expect(k.bleIos, '3A71E67C-5341-4D83-BC33-B18B4C5E1151');
  expect(k.bleAndroid, 'C048D642-ED40-4171-A32C-FB272D6C5C6B');
});

test('rejects a secret that is not 32 bytes', () {
  expect(GroupKeys.derive(Uint8List(31)), throwsArgumentError);
});
```

```dart
// test/invite_test.dart
const link = 'vroo://join?v=1&s=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&n=Sunday%20ride';

test('encodes the v1 invite link', () {
  expect(encodeInvite(Invite(secret, 'Sunday ride')), link);
});
test('decodes what it encodes', () {
  final i = decodeInvite(link)!;
  expect(i.secret, secret);
  expect(i.name, 'Sunday ride');
});
test('a missing name decodes as empty', () {
  expect(decodeInvite(link.split('&n=').first)!.name, '');
});
test('rejects foreign or broken links', () {
  expect(decodeInvite(link.replaceFirst('vroo://', 'https://')), isNull);
  expect(decodeInvite(link.replaceFirst('v=1', 'v=2')), isNull);
  expect(decodeInvite('vroo://join?v=1&s=AAEC&n=x'), isNull); // not 32 bytes
  expect(decodeInvite('not a link'), isNull);
});
```

These expected values came from `tool/oracle.py`, run with Python `cryptography` 45+. Commit the script so the vectors can be recomputed independently:

```python
# tool/oracle.py — independent protocol v1 vectors. Run: python3 -m venv v && v/bin/pip install cryptography && v/bin/python tool/oracle.py
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
import struct
secret = bytes(range(32))
def hk(info, n): return HKDF(algorithm=hashes.SHA256(), length=n, salt=None, info=info.encode()).derive(secret)
def uuid(b):
    b = bytearray(b); b[6] = (b[6] & 0x0F) | 0x40; b[8] = (b[8] & 0x3F) | 0x80; h = b.hex().upper()
    return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"
key, tag = hk("vroo/v1/key", 32), hk("vroo/v1/tag", 8)
print("key", key.hex(), "tag", tag.hex(), "channel", [1, 6, 11][tag[0] % 3])
print("bleIos", uuid(hk("vroo/v1/ble-ios", 16)), "bleAndroid", uuid(hk("vroo/v1/ble-android", 16)))
header = struct.pack(">BBBIII", 1, 3, 16, 0x01020304, 0x0A0B0C0D, 7)
payload = bytes([1, 0x0C, 77]) + struct.pack(">I", 123456) + bytes([0, 4]) + b"Ravi"
nonce, aad = struct.pack(">III", 0x01020304, 0x0A0B0C0D, 7), header[0:2] + header[3:15]
sealed = header + ChaCha20Poly1305(key).encrypt(nonce, payload, aad)
print("sealed", sealed.hex(), "envelope", (tag + sealed).hex())
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `cd packages/vroo_protocol && dart pub add cryptography && dart test`
Expected: FAIL. The compile errors name `GroupKeys`, `Invite` and `encodeInvite`.

- [ ] **Step 3: Implement `GroupKeys.derive`, `encodeInvite` and `decodeInvite`**

- **Key derivation:** `Hkdf(hmac: Hmac.sha256(), outputLength: n)` with `nonce: const []`, for the info strings and lengths in Global Constraints. UUID bytes: `b[6] = (b[6] & 0x0F) | 0x40` and `b[8] = (b[8] & 0x3F) | 0x80`, formatted as uppercase 8-4-4-4-12.
- **Encoding the invite:** `base64Url` with the `=` padding removed, and `Uri.encodeComponent` for the name.
- **Decoding the invite:** pad the base64 again before decoding. Require the scheme `vroo`, host `join`, `v=1`, and exactly 32 secret bytes.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `dart test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/vroo_protocol
git commit -m "feat(protocol): group key derivation and invite links (v1)"
```

---

### Task 3: vroo_protocol: packet header, envelope and payloads

**Files:**
- Create: `lib/src/packet.dart`, `lib/src/envelope.dart`, `lib/src/payloads.dart`, `test/packet_test.dart`, `test/envelope_test.dart`, `test/payloads_test.dart` (all under `packages/vroo_protocol/`)

**Interfaces:**
- Produces:
  - **Header:**
    ```dart
    class PacketHeader { final int version, type, ttl, src, session, seq; const PacketHeader({...}); }  // value ==
    Uint8List encodeHeader(PacketHeader h);          // 15 bytes
    PacketHeader? decodeHeader(Uint8List packet);     // null if < 15 bytes or version != 1
    Uint8List aadOf(Uint8List packetOrHeader);        // bytes 0–1 ‖ 3–14
    Uint8List nonceOf(PacketHeader h);                // src ‖ session ‖ seq
    ```
  - **Envelope:**
    ```dart
    Uint8List wrapEnvelope(Uint8List groupTag, Uint8List packet);
    ({Uint8List groupTag, Uint8List packet})? unwrapEnvelope(Uint8List datagram); // null if < 8 + 15 + 16
    ```
  - **Beat:**
    ```dart
    abstract final class BeatFlags { static const talking = 1, onCall = 2, hasInternet = 4, hasBox = 8, bluetoothOn = 16, diagnostics = 32; }
    class Beat { final int platform, flags, battery, sentAtMs; final List<int> btNeighbors; final String name; final double? lat, lon; final int? accuracyM; }  // value ==
    Uint8List encodeBeat(Beat b);  Beat? decodeBeat(Uint8List payload);
    ```
  - **Echo, Hello, VoiceFrame:**
    ```dart
    class Echo { final int target, sentAtMs; }            Uint8List encodeEcho(Echo e);   Echo? decodeEcho(Uint8List p);
    class Hello { final int platform; final String name; } Uint8List encodeHello(Hello h); Hello? decodeHello(Uint8List p);
    class VoiceFrame { final int frameNo; final Uint8List opus; } Uint8List encodeVoice(VoiceFrame v); VoiceFrame? decodeVoice(Uint8List p);
    ```
  - **Beat layout:** platform u8, flags u8, battery u8, sentAt u32, neighbour count u8 followed by that many u32, name (u8 length + up to 32 UTF-8 bytes, cut on a character boundary). Only when `flags & diagnostics` is set: lat f32, lon f32, accuracy u16.

- [ ] **Step 1: Write the failing tests**

```dart
const h = PacketHeader(version: 1, type: PacketType.beat, ttl: 16, src: 0x01020304, session: 0x0A0B0C0D, seq: 7);
const sealed = '010310010203040a0b0c0d000000070d0130763dd9b37750eade2038afcac4ca4ded54f5a07110b999e56896';

test('header is 15 big-endian bytes', () => expect(hex(encodeHeader(h)), '010310010203040a0b0c0d00000007'));
test('header round-trips', () => expect(decodeHeader(encodeHeader(h)), h));
test('short or wrong-version headers are rejected', () {
  expect(decodeHeader(Uint8List(14)), isNull);
  expect(decodeHeader(unhex('020310010203040a0b0c0d00000007')), isNull);
});
test('aad skips ttl', () => expect(hex(aadOf(encodeHeader(h))), '0103010203040a0b0c0d00000007'));
test('nonce is src, session, seq', () => expect(hex(nonceOf(h)), '010203040a0b0c0d00000007'));

test('envelope is tag then packet', () {
  expect(hex(wrapEnvelope(unhex('a9968d2a1c900625'), unhex(sealed))), 'a9968d2a1c900625$sealed');
  final u = unwrapEnvelope(unhex('a9968d2a1c900625$sealed'))!;
  expect(hex(u.groupTag), 'a9968d2a1c900625');
  expect(hex(u.packet), sealed);
  expect(unwrapEnvelope(Uint8List(38)), isNull);
});

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
test('truncated payloads are rejected', () {
  expect(decodeBeat(unhex('010c4d')), isNull);
  expect(decodeEcho(unhex('0102')), isNull);
  expect(decodeHello(unhex('00')), isNull);
  expect(decodeVoice(unhex('000000')), isNull);
});
test('echo, hello and voice layouts', () {
  expect(hex(encodeEcho(const Echo(target: 0x01020304, sentAtMs: 123456))), '010203040001e240');
  expect(hex(encodeHello(const Hello(platform: 0, name: 'Ravi'))), '000452617669');
  expect(hex(encodeVoice(VoiceFrame(frameNo: 5, opus: Uint8List.fromList([0xAA, 0xBB])))), '00000005aabb');
});
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `dart test`
Expected: FAIL. The compile errors name the missing types and functions.

- [ ] **Step 3: Implement the codecs** in `packet.dart`, `envelope.dart` and `payloads.dart`, using `ByteData` with `Endian.big`. To cut a name, drop whole code points until its UTF-8 form is 32 bytes or fewer.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `dart test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add packages/vroo_protocol
git commit -m "feat(protocol): packet header, envelope and payload codecs"
```

---

### Task 4: vroo_protocol: sealing and dedupe

**Files:**
- Create: `lib/src/crypto.dart`, `lib/src/dedupe.dart`, `test/crypto_test.dart`, `test/dedupe_test.dart`

**Interfaces:**
- Consumes: `GroupKeys` (Task 2), and `PacketHeader`, `encodeHeader`, `decodeHeader`, `aadOf` and `nonceOf` (Task 3).
- Produces:
  ```dart
  class Opened { final PacketHeader header; final Uint8List payload; }
  class Sealer {
    Sealer(GroupKeys keys);
    Future<Uint8List> seal(PacketHeader header, Uint8List payload);   // header ‖ ciphertext ‖ 16-byte tag
    Future<Opened?> open(Uint8List packet);                           // null on short packet, bad version or failed auth
  }
  class Dedupe {
    Dedupe({int windowMs = dedupeWindowMs});
    bool firstTime(int src, int session, int seq, int nowMs);
    int get size;                                                     // live entries
  }
  ```

- [ ] **Step 1: Write the failing tests**

```dart
late Sealer s;
setUp(() async => s = Sealer(await GroupKeys.derive(secret)));
final payload = unhex('010c4d0001e240000452617669');

test('seals the v1 vector', () async {
  expect(hex(await s.seal(h, payload)), sealed);   // `sealed` from Task 3
});
test('opens what it seals, even after a relay changed the ttl', () async {
  final p = await s.seal(h, payload)..[2] = 15;
  final o = (await s.open(p))!;
  expect(o.payload, payload);
  expect(o.header.ttl, 15);
});
test('wrong key, flipped bit or short packet opens to null', () async {
  final other = Sealer(await GroupKeys.derive(Uint8List(32)));
  final p = await s.seal(h, payload);
  expect(await other.open(p), isNull);
  expect(await s.open(Uint8List.fromList(p)..[20] ^= 1), isNull);
  expect(await s.open(p.sublist(0, 30)), isNull);
});

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
  for (var i = 0; i < 1000; i++) d.firstTime(1, 1, i, 0);
  d.firstTime(9, 9, 9, 20000);
  expect(d.size, lessThan(10));
});
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `dart test`
Expected: FAIL. `Sealer` and `Dedupe` aren't defined.

- [ ] **Step 3: Implement `Sealer` and `Dedupe`**

- **Sealer:** `Chacha20.poly1305Aead()`. `open` catches `SecretBoxAuthenticationError` and returns null.
- **Dedupe:** a `Map<(int, int, int), int>` of first-seen times. Purge entries older than the window whenever more than 1 s has passed since the last purge.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `dart test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add packages/vroo_protocol
git commit -m "feat(protocol): ChaCha20-Poly1305 sealing and dedupe"
```

---

### Task 5: vroo_protocol: box messages, SSIDs and box passwords

**Files:**
- Create: `lib/src/box_messages.dart`, `test/box_messages_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class BoxConfig { final Uint8List? groupTag; final int? channel; final String? wifiPassword; }  // only given fields change
  Uint8List encodeBoxConfig(BoxConfig c);   BoxConfig? decodeBoxConfig(Uint8List b);
  class BoxStatus { final int boxId, fwVersion, uptimeS, phones, rxFromPhones, txToPhones, dropDup, dropTag; final bool setupMode; }  // value ==
  Uint8List encodeBoxStatus(BoxStatus s);   BoxStatus? decodeBoxStatus(Uint8List b);
  String boxSsid(int boxId);     // 'Vroo-' + (boxId & 0xFFFFFF) as 6 uppercase hex digits
  String setupSsid(int boxId);   // 'Vroo-setup-' + the same 6 digits
  String newBoxPassword(Random r);  // 4 groups of 4 from 'abcdefghjkmnpqrstuvwxyz23456789', joined by '-'
  ```
- **BOX_CONFIG layout:**
  - `[0]` = 1, `[1]` = 0x10.
  - `[2]` is a field mask: bit0 group tag, bit1 channel, bit2 password.
  - Then the present fields, in this order: tag (8 bytes), channel (u8, must be 1, 6 or 11), password (u8 length of 8–63, then ASCII).
- **BOX_STATUS layout (30 bytes):**
  - `[0]` = 1, `[1]` = 0x11.
  - boxId u32, fwVersion u16, uptimeS u32.
  - flags u8, where bit0 means setup mode.
  - phones u8.
  - rxFromPhones u32, txToPhones u32, dropDup u32, dropTag u32.

- [ ] **Step 1: Write the failing tests**

```dart
const pw = 'abcd-efgh-jkmn-pqrs';
const full = '011007' 'a9968d2a1c900625' '0b' '13' '616263642d656667682d6a6b6d6e2d70717273';
const statusHex = '0111' '00a1b2c3' '0001' '00000e10' '00' '02' '00000064' '0000005a' '00000003' '00000001';

test('box config with every field', () {
  expect(hex(encodeBoxConfig(BoxConfig(groupTag: unhex('a9968d2a1c900625'), channel: 11, wifiPassword: pw))), full);
  final c = decodeBoxConfig(unhex(full))!;
  expect([hex(c.groupTag!), c.channel, c.wifiPassword], ['a9968d2a1c900625', 11, pw]);
});
test('box config with only the tag', () {
  expect(hex(encodeBoxConfig(BoxConfig(groupTag: unhex('a9968d2a1c900625')))), '011001a9968d2a1c900625');
});
test('bad box configs are rejected', () {
  expect(decodeBoxConfig(unhex('011002' '05')), isNull);            // channel 5
  expect(decodeBoxConfig(unhex('011004' '03' '616263')), isNull);   // password too short
  expect(decodeBoxConfig(unhex('011001' '0e8d')), isNull);          // truncated tag
});
test('box status layout', () {
  const s = BoxStatus(boxId: 0x00A1B2C3, fwVersion: 1, uptimeS: 3600, setupMode: false, phones: 2, rxFromPhones: 100, txToPhones: 90, dropDup: 3, dropTag: 1);
  expect(hex(encodeBoxStatus(s)), statusHex);
  expect(decodeBoxStatus(unhex(statusHex)), s);
  expect(decodeBoxStatus(unhex(statusHex).sublist(0, 29)), isNull);
});
test('box names and passwords', () {
  expect(boxSsid(0x00A1B2C3), 'Vroo-A1B2C3');
  expect(setupSsid(0x00A1B2C3), 'Vroo-setup-A1B2C3');
  expect(newBoxPassword(Random(1)), matches(RegExp(r'^[a-hjkmnp-z2-9]{4}(-[a-hjkmnp-z2-9]{4}){3}$')));
});
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `dart test test/box_messages_test.dart`
Expected: FAIL. The box message types aren't defined.

- [ ] **Step 3: Implement the box messages** in `box_messages.dart`, and export them from `lib/vroo_protocol.dart`.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `dart test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add packages/vroo_protocol
git commit -m "feat(protocol): box config and status messages"
```

---

### Task 6: Firmware `vroo_wire` component and host tests

**Files:**
- Create:
  - `firmware/components/vroo_wire/CMakeLists.txt`, `include/vroo_wire.h`, `vroo_wire.c`
  - `firmware/host_test/CMakeLists.txt`, `test_vroo_wire.c`, `vectors.h` (generated)
  - `packages/vroo_protocol/tool/gen_c_vectors.dart`

**Interfaces:**
- Consumes: `wrapEnvelope`, `encodeBoxConfig` and `encodeBoxStatus` from vroo_protocol, used by the vector generator.
- Produces (C):
  ```c
  #define VW_HEADER_SIZE 15
  #define VW_AEAD_TAG_SIZE 16
  #define VW_GROUP_TAG_SIZE 8
  #define VW_DEDUPE_WINDOW_MS 10000
  #define VW_DEDUPE_SLOTS 2048
  #define VW_BOX_STATUS_SIZE 30
  typedef struct { uint8_t version, type, ttl; uint32_t src, session, seq; } vw_header_t;
  bool vw_unwrap(const uint8_t *dgram, size_t len, const uint8_t **group_tag, const uint8_t **packet, size_t *packet_len); // false if len < 39
  bool vw_parse_header(const uint8_t *packet, size_t len, vw_header_t *out);  // false if len < 15 or version != 1
  typedef struct { uint32_t src, session, seq, t_ms; bool used; } vw_dedupe_slot_t;
  typedef struct { vw_dedupe_slot_t slots[VW_DEDUPE_SLOTS]; } vw_dedupe_t;
  void vw_dedupe_init(vw_dedupe_t *d);
  bool vw_dedupe_first(vw_dedupe_t *d, uint32_t src, uint32_t session, uint32_t seq, uint32_t now_ms);
  typedef struct { bool has_tag, has_channel, has_password; uint8_t tag[8]; uint8_t channel; char password[64]; } vw_box_config_t;
  bool vw_decode_box_config(const uint8_t *b, size_t len, vw_box_config_t *out);
  typedef struct { uint32_t box_id; uint16_t fw_version; uint32_t uptime_s; bool setup_mode; uint8_t phones;
                   uint32_t rx_from_phones, tx_to_phones, drop_dup, drop_tag; } vw_box_status_t;
  size_t vw_encode_box_status(const vw_box_status_t *s, uint8_t *out, size_t cap); // 30, or 0 if cap < 30
  ```
- **Dedupe algorithm:** the open addressing isn't settled by the tests, so it's fixed here:
  - **Hash:** `(src * 2654435761u) ^ (session * 2246822519u) ^ (seq * 3266489917u)`, modulo `VW_DEDUPE_SLOTS`.
  - **Probing:** probe up to 16 slots in a line. A slot with the same key and `(uint32_t)(now - t) <= window` is a duplicate: return false.
  - **Inserting:** otherwise, write into the first unused or expired slot that was probed. If there's none, overwrite the probed slot with the oldest `t`. Return true.

- [ ] **Step 1: Generate the shared vectors**

Write `tool/gen_c_vectors.dart`. It writes `firmware/host_test/vectors.h` with these `static const uint8_t` arrays, built with the Dart encoders:
- `VEC_GROUP_TAG[8]`
- `VEC_ENVELOPE[52]`: tag ‖ the Task 3 `sealed` vector
- `VEC_BOX_CONFIG_FULL` and `VEC_BOX_CONFIG_TAG_ONLY`: Task 5
- `VEC_BOX_STATUS[30]`: Task 5

Run: `cd packages/vroo_protocol && dart run tool/gen_c_vectors.dart ../../firmware/host_test/vectors.h`
Expected: the file is written, and `VEC_ENVELOPE` starts `0xa9, 0x96, 0x8d`.

- [ ] **Step 2: Write the failing C tests** in `test_vroo_wire.c`, using plain `assert`s

```c
// unwrap + header
const uint8_t *tag, *pkt; size_t plen; vw_header_t h;
assert(vw_unwrap(VEC_ENVELOPE, 52, &tag, &pkt, &plen) && plen == 44 && memcmp(tag, VEC_GROUP_TAG, 8) == 0);
assert(vw_parse_header(pkt, plen, &h) && h.version == 1 && h.type == 3 && h.ttl == 16
       && h.src == 0x01020304 && h.session == 0x0A0B0C0D && h.seq == 7);
assert(!vw_unwrap(VEC_ENVELOPE, 38, &tag, &pkt, &plen));
uint8_t v2[52]; memcpy(v2, VEC_ENVELOPE, 52); v2[8] = 2;   // version 2
assert(vw_unwrap(v2, 52, &tag, &pkt, &plen) && !vw_parse_header(pkt, plen, &h));
// dedupe
static vw_dedupe_t d; vw_dedupe_init(&d);
assert(vw_dedupe_first(&d, 1, 2, 3, 0) && !vw_dedupe_first(&d, 1, 2, 3, 9999));
assert(vw_dedupe_first(&d, 1, 3, 3, 0));                     // new session
assert(vw_dedupe_first(&d, 1, 2, 3, 10001));                 // expired
assert(vw_dedupe_first(&d, 5, 5, 5, 0xFFFFFF00u) && !vw_dedupe_first(&d, 5, 5, 5, 0x00000100u)); // clock wrap
// box messages
vw_box_config_t c;
assert(vw_decode_box_config(VEC_BOX_CONFIG_FULL, sizeof VEC_BOX_CONFIG_FULL, &c) && c.has_tag && c.has_channel
       && c.channel == 11 && c.has_password && strcmp(c.password, "abcd-efgh-jkmn-pqrs") == 0);
assert(vw_decode_box_config(VEC_BOX_CONFIG_TAG_ONLY, sizeof VEC_BOX_CONFIG_TAG_ONLY, &c) && c.has_tag && !c.has_channel && !c.has_password);
const uint8_t bad_channel[] = {1, 0x10, 0x02, 5};
assert(!vw_decode_box_config(bad_channel, sizeof bad_channel, &c));
vw_box_status_t s = {0x00A1B2C3, 1, 3600, false, 2, 100, 90, 3, 1}; uint8_t out[30];
assert(vw_encode_box_status(&s, out, 30) == 30 && memcmp(out, VEC_BOX_STATUS, 30) == 0);
assert(vw_encode_box_status(&s, out, 29) == 0);
puts("vroo_wire: all tests passed");
```

- [ ] **Step 3: Run the tests and watch them fail**

Run: `cmake -S firmware/host_test -B firmware/host_test/build && cmake --build firmware/host_test/build`
Expected: link errors for the `vw_*` symbols.

- [ ] **Step 4: Implement `vroo_wire.c`.** It must be plain C99 with no ESP-IDF includes, so it builds for both the host and the ESP32. `CMakeLists.txt` registers it as an ESP-IDF component with `idf_component_register(SRCS vroo_wire.c INCLUDE_DIRS include)`.

- [ ] **Step 5: Run the tests and watch them pass**

Run: `cmake --build firmware/host_test/build && firmware/host_test/build/test_vroo_wire`
Expected: `vroo_wire: all tests passed`

- [ ] **Step 6: Commit**

```bash
git add firmware/components firmware/host_test packages/vroo_protocol/tool/gen_c_vectors.dart
git commit -m "feat(firmware): vroo_wire parsing, dedupe and box messages with shared vectors"
```

---

### Task 7: Box firmware: setup mode, normal mode and the UDP bridge

**Files:**
- Create: `firmware/main/{main.c, config.c, config.h, wifi_ap.c, wifi_ap.h, bridge.c, bridge.h, led.c, led.h, button.c, button.h, Kconfig.projbuild, CMakeLists.txt}`, `firmware/sdkconfig.defaults`, `packages/vroo_protocol/tool/box_probe.dart`
- Modify: `firmware/CMakeLists.txt`. Delete `firmware/main/vroo_box.c` from Task 1.

**Interfaces:**
- Consumes: `vroo_wire` (Task 6).
- Produces (the box behaviour that Tasks 8–13 rely on):
  - **Box ID:** the lower 32 bits of the softAP MAC. The SSID suffix is the lower 24 bits as uppercase hex, matching `boxSsid` and `setupSsid` from Task 5.
  - **Setup mode** (no saved password):
    - An open AP called `Vroo-setup-XXXXXX`, on channel 6, at 192.168.4.1.
    - Control port 47001 accepts a BOX_CONFIG that includes a password. It saves the config, replies with BOX_STATUS (`setupMode` true), then restarts into normal mode within 1 s.
  - **Normal mode, Wi-Fi:** a WPA2 AP called `Vroo-XXXXXX`, with the saved password and channel and at most 4 stations.
  - **Normal mode, data port 47000:**
    - An envelope carrying the saved groupTag that passes dedupe is forwarded to every other phone heard in the last 30 s.
    - A wrong tag, or no tag saved yet, counts `dropTag`. A duplicate counts `dropDup`.
    - The datagram's (IPv4, port) refreshes the phone table: 4 entries, the least recently heard replaced first, expiring after 30 s.
  - **Normal mode, control port 47001:**
    - Accepts a BOX_CONFIG that changes the tag, channel or password, saving whatever is present. It restarts if the channel or password changed.
    - Any datagram also refreshes the phone table.
  - **Status:** every 1 s, BOX_STATUS goes from port 47001 to each phone in the table, with `fwVersion` 1.
  - **NVS:** namespace `vroo`, with keys `pw` (string), `tag` (8-byte blob) and `ch` (u8).
  - **Kconfig:** `VROO_LED_GPIO` (default 2), `VROO_LED_ACTIVE_HIGH` (default y), `VROO_BUTTON_GPIO` (default 0, the BOOT button).
  - **LED:** setup mode blinks at 1 Hz. Normal mode with no phone shows a 100 ms flash every 2 s. Normal mode with at least one phone stays solid on.
  - **Button:** holding it for 5 s erases the config and restarts into setup mode. The log reads `config erased`.
  - **Log lines** (used for verification): `vroo_box: setup mode ssid=…`, `vroo_box: config saved, restarting`, `vroo_box: normal mode ssid=… ch=…`.

- [ ] **Step 1: Write the bench probe**, a Dart command-line tool run on the Mac (`tool/box_probe.dart`).
  - **`setup --password P --tag HEX --channel C`:** sends BOX_CONFIG to 192.168.4.1:47001. Within 3 s it must get a BOX_STATUS with `setupMode` true. It prints the box's SSID.
  - **`bridge --tag HEX`:** opens two UDP sockets, A and B, and checks these in order:
    - A sends one datagram to each port so both are registered.
    - Both A and B get a BOX_STATUS with `phones == 2` within 3 s.
    - A sends `VEC_ENVELOPE` to port 47000, and B receives the same bytes within 500 ms.
    - A sends it again, so B gets nothing for 500 ms and the next status shows `dropDup` up by one.
    - A sends the envelope with its first tag byte flipped, so B gets nothing, and the next status shows `dropTag` up by one.
  - **Output:** `box probe: all checks passed`, or the first check that failed.

- [ ] **Step 2: Implement the firmware modules** with the behaviour above.
  - **Wi-Fi:** use `esp_netif_create_default_wifi_ap`, `WIFI_MODE_AP`, `WIFI_AUTH_OPEN` for setup and `WIFI_AUTH_WPA2_PSK` for normal mode, with `max_connection = 4`.
  - **Bridge:** lwIP sockets in one FreeRTOS task. Use `select` across both ports and a 1 s status tick.
  - **Persistence:** `nvs_flash` for the saved config.

Run: `cd firmware && idf.py build`
Expected: `Project build complete`.

- [ ] **Step 3: Flash the box and check setup mode**

Run: `idf.py -p <port> flash monitor`
Expected: `vroo_box: setup mode ssid=Vroo-setup-XXXXXX`

👤 Founder: the LED on the board blinks about once a second.

- [ ] **Step 4: Run the setup probe from the Mac**

The Mac will be offline while it's on the box's Wi-Fi.
- Find the Mac's Wi-Fi device: `networksetup -listallhardwareports`. It's usually `en0`.
- Join the box: `networksetup -setairportnetwork en0 Vroo-setup-XXXXXX`

Run: `cd packages/vroo_protocol && dart run tool/box_probe.dart setup --password abcd-efgh-jkmn-pqrs --tag a9968d2a1c900625 --channel 6`
Expected: `setup ok, box ssid Vroo-XXXXXX`. The monitor shows `config saved, restarting`, then `normal mode ssid=Vroo-XXXXXX ch=6`.

- [ ] **Step 5: Run the bridge probe**

Join the box's normal network: `networksetup -setairportnetwork en0 Vroo-XXXXXX abcd-efgh-jkmn-pqrs`

Run: `dart run tool/box_probe.dart bridge --tag a9968d2a1c900625`
Expected: `box probe: all checks passed`

👤 Founder: the LED is now solid.

- [ ] **Step 6: Check the reset button**

👤 Founder: hold the BOOT button on the board for 5 seconds.
Expected: the monitor shows `config erased`, then `setup mode ssid=Vroo-setup-XXXXXX`.

Then re-run Step 4 to set the box up again, and rejoin the Mac to its normal Wi-Fi.

- [ ] **Step 7: Commit**

```bash
git add firmware packages/vroo_protocol/tool/box_probe.dart
git commit -m "feat(firmware): box setup and normal modes with same-group UDP bridge"
```

---

### Task 8: vroo_net: Dart API, test double and internet probe

**Files:**
- Create: `packages/vroo_net/lib/vroo_net.dart`, `lib/src/fake_vroo_net.dart`, `lib/src/probe.dart`, `lib/src/channel_vroo_net.dart`, `test/probe_test.dart`
- Modify: `packages/vroo_net/pubspec.yaml`, adding a `vroo_protocol` path dependency for the constants.

**Interfaces:**
- Produces:
  ```dart
  sealed class NetEvent {}
  final class BoxNetworkChanged extends NetEvent { final bool available; BoxNetworkChanged(this.available); }
  final class BoxDatagram extends NetEvent { final int fromPort; final Uint8List data; BoxDatagram(this.fromPort, this.data); }
  final class InternetDatagram extends NetEvent { final InternetAddress from; final int fromPort; final Uint8List data; InternetDatagram(this.from, this.fromPort, this.data); }
  enum JoinOutcome { joined, needsManualJoin, denied, failed }
  abstract interface class VrooNet {
    Stream<NetEvent> get events;
    Future<JoinOutcome> joinBox({required String ssid, String? password});  // null password = open network
    Future<JoinOutcome> joinSetupNetwork();                                 // any "Vroo-setup-" network
    Future<void> leaveBox();
    Future<void> sendToBox(Uint8List data, {required int port});            // to 192.168.4.1:port
    Future<void> sendToInternet(Uint8List data, InternetAddress host, int port);
    Future<void> dispose();
  }
  VrooNet createVrooNet();   // ChannelVrooNet (Tasks 9–10)
  class FakeVrooNet implements VrooNet {
    final List<(int, Uint8List)> sentToBox; final List<(InternetAddress, int, Uint8List)> sentToInternet;
    final List<String> joins; JoinOutcome nextJoinOutcome; void emit(NetEvent e);
  }
  Uint8List encodeDnsQuery(int id);                 // A record for example.com, recursion desired
  bool isDnsResponseFor(int id, Uint8List bytes);   // same id, QR bit set, ≥ 12 bytes
  Future<bool> probeInternet(VrooNet net, {Duration timeout = const Duration(seconds: 2), Random? random}); // to 1.1.1.1:53
  ```
- **Channel contract** (`ChannelVrooNet`, implemented natively in Tasks 9 and 10):
  - MethodChannel `vroo_net`:
    - `joinBox {ssid, password?}` and `joinSetupNetwork {}` return `'joined' | 'needsManualJoin' | 'denied' | 'failed'`.
    - `leaveBox {}`.
    - `sendToBox {port, data}` (Android only).
    - `sendToInternet {host, port, data, viaCellular}` (iOS only).
  - EventChannel `vroo_net/events` sends maps:
    - `{kind: 'boxNetwork', available}`
    - `{kind: 'box', fromPort, data}` (Android only)
    - `{kind: 'internet', host, port, data}` (iOS only)

- [ ] **Step 1: Write the failing tests**

```dart
test('dns query layout', () {
  expect(hex(encodeDnsQuery(0x1234)), '123401000001000000000000076578616d706c6503636f6d0000010001');
});
test('dns response matching', () {
  final r = unhex('123481800001000100000000');
  expect(isDnsResponseFor(0x1234, r), isTrue);
  expect(isDnsResponseFor(0x1235, r), isFalse);
  expect(isDnsResponseFor(0x1234, unhex('123401000001000000000000')), isFalse); // a query, not a response
  expect(isDnsResponseFor(0x1234, unhex('1234')), isFalse);
});
test('probe succeeds on a matching reply and fails on timeout', () {
  fakeAsync((fa) {
    final net = FakeVrooNet(); bool? ok;
    probeInternet(net, random: Random(7)).then((v) => ok = v);
    fa.flushMicrotasks();
    final q = net.sentToInternet.single;
    expect([q.$1.address, q.$2], ['1.1.1.1', 53]);
    net.emit(InternetDatagram(InternetAddress('1.1.1.1'), 53, Uint8List.fromList([...q.$3.sublist(0, 2), 0x81, 0x80, ...List.filled(8, 0)])));
    fa.flushMicrotasks();
    expect(ok, isTrue);
    ok = null;
    probeInternet(net).then((v) => ok = v);
    fa.elapse(const Duration(seconds: 3));
    expect(ok, isFalse);
  });
});
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `cd packages/vroo_net && flutter pub add --dev fake_async && flutter test`
Expected: FAIL. The API types are undefined.

- [ ] **Step 3: Implement the API, `FakeVrooNet`, the probe and the `ChannelVrooNet` skeleton.** The skeleton forwards to the channels. Its Dart-side socket parts are filled in by Tasks 9 and 10.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `flutter test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add packages/vroo_net
git commit -m "feat(net): vroo_net API, fake, DNS internet probe"
```

---

### Task 9: vroo_net: Android (join the box's Wi-Fi, bound box socket)

**Files:**
- Create: `packages/vroo_net/android/src/main/kotlin/com/getvroo/vroo_net/VrooNetPlugin.kt`
- Modify:
  - `packages/vroo_net/android/src/main/AndroidManifest.xml`
  - `lib/src/channel_vroo_net.dart`: the Android branch, with internet over a Dart `RawDatagramSocket`
  - `example/lib/main.dart`: the "net check" screen
  - the example's AndroidManifest

**Interfaces:**
- Consumes: the channel contract (Task 8).
- Produces, for Android:
  - **Joining:**
    - `joinBox` uses `WifiNetworkSpecifier.Builder().setSsid(ssid)`, plus `.setWpa2Passphrase(password)` when a password is given.
    - `joinSetupNetwork` uses `.setSsidPattern(PatternMatcher("Vroo-setup-", PATTERN_PREFIX))` on an open network.
    - Both build the request with `TRANSPORT_WIFI` and `removeCapability(NET_CAPABILITY_INTERNET)`, and call `requestNetwork` with a 60 s timeout.
  - **Join results:**
    - `onAvailable` binds a `DatagramSocket(0)` with `network.bindSocket`, starts a reader thread that emits `box` events, emits `boxNetwork true`, and returns `'joined'`.
    - `onUnavailable` returns `'denied'`.
    - `onLost` emits `boxNetwork false` and closes the socket.
  - **Sending:** `sendToBox` sends to `192.168.4.1:port` over the bound socket.
  - **Internet:** `sendToInternet` runs in Dart over the default network, which stays on mobile data.
  - **Manifest permissions:** `NEARBY_WIFI_DEVICES` (`usesPermissionFlags="neverForLocation"`), `ACCESS_FINE_LOCATION` (`maxSdkVersion` 32), `CHANGE_NETWORK_STATE`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`, `INTERNET`.
  - **Example screen:**
    - Buttons: "Join setup Wi-Fi", "Join box (SSID + password fields)", "Register" (sends an empty BOX_CONFIG, mask 0, to 47001) and "Probe internet".
    - It also shows a live list of events.
    - It asks for the permissions above with `permission_handler` before joining.

- [ ] **Step 1: Implement the Kotlin plugin, the Android Dart branch and the example screen**

Run: `cd packages/vroo_net/example && flutter build apk --debug`
Expected: `Built build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step 2: Run the device check**

Have the box in normal mode from Task 7, with password `abcd-efgh-jkmn-pqrs`. Run: `flutter run -d <android id>`.

👤 Founder checklist, on the Android phone:
1. Allow the permissions the app asks for.
2. Type `Vroo-XXXXXX` and the password. Tap **Join box**, then tap **Connect** in the system pop-up.
3. Tap **Register**.
4. Tap **Probe internet** with mobile data switched on.

Expected:
- The events list shows `boxNetwork available` after the join.
- After Register, a `box from 47001` line appears about once a second.
- The probe shows `internet: true`.

👤 Founder: also note whether the phone's Wi-Fi icon shows "no internet". It's expected and harmless.

- [ ] **Step 3: Record the result**

Add this line to test-plan §5:

`Android, foreground: box link ok / probe true|false`

That's U3 for Android, in the foreground.

- [ ] **Step 4: Commit**

```bash
git add packages/vroo_net docs/test-plan.md
git commit -m "feat(net): Android box join and bound socket; device check"
```

---

### Task 10: vroo_net: iOS (join attempt, box socket, cellular internet socket)

**Files:**
- Create: `packages/vroo_net/ios/Classes/VrooNetPlugin.swift`
- Modify:
  - `packages/vroo_net/ios/vroo_net.podspec`: iOS 17
  - `lib/src/channel_vroo_net.dart`: the iOS branch
  - the example's `ios/Runner/Info.plist` and `Runner.entitlements`

**Interfaces:**
- Consumes: the channel contract (Task 8).
- Produces, for iOS:
  - **Joining:**
    - `joinBox` builds `NEHotspotConfiguration(ssid:passphrase:isWEP: false)`, or `(ssid:)` when there's no password, with `joinOnce = false`.
    - `joinSetupNetwork` builds `NEHotspotConfiguration(ssidPrefix: "Vroo-setup-")`.
    - Both call `apply`. No error, or `.alreadyAssociated`, returns `'joined'`. `.userDenied` returns `'denied'`. Any other error returns `'needsManualJoin'`.
  - **Box network detection (Dart):** every 2 s, if `NetworkInterface.list(type: IPv4)` has an address starting `192.168.4.`, emit `BoxNetworkChanged(true)`. Otherwise emit `false`. Only changes are emitted.
  - **Box datagrams (Dart):** one `RawDatagramSocket` bound to `anyIPv4:0` and sending to `192.168.4.1:port`. Anything arriving from 192.168.4.1 becomes a `BoxDatagram(fromPort)`.
  - **Internet (native):** `sendToInternet` keeps one `NWConnection` per (host, port), using `NWParameters.udp`. While the box network is available, Dart passes `viaCellular: true` and `requiredInterfaceType = .cellular` is set. Received data comes back as `internet` events.
  - **Info.plist:** `NSLocalNetworkUsageDescription` = "Talks to your Vroo box over its Wi-Fi."

- [ ] **Step 1: Try the Hotspot Configuration entitlement under the free account**

Add `com.apple.developer.networking.HotspotConfiguration` to the example's `Runner.entitlements`. Then run: `cd packages/vroo_net/example && flutter build ios --debug`

The outcome is a decision gate:
- **Signing works:** keep the entitlement.
- **Signing fails because the Personal Team can't use it:** remove the entitlement. Keep the code; it then returns `needsManualJoin`. Add a note to decisions.md D22: "U9 answered: not available on the free account; iPhones join the box Wi-Fi in Settings".

- [ ] **Step 2: Implement the Swift plugin and the iOS Dart branch**

Run: `flutter build ios --debug --no-codesign`
Expected: `Built build/ios/iphoneos/Runner.app`.

- [ ] **Step 3: Run the device check**

Run: `flutter run -d <iphone id>`.

👤 Founder checklist, on the iPhone:
1. Allow Local Network access when asked.
2. Tap **Join box**.
3. If the app says "join it in Settings":
   1. Open Settings → Wi-Fi.
   2. Tap `Vroo-XXXXXX`.
   3. Type `abcd-efgh-jkmn-pqrs`.
   4. Come back to the app.
4. Tap **Register**.
5. Tap **Probe internet** with mobile data switched on.

Expected:
- The events list shows `boxNetwork available`.
- After Register, a `box from 47001` line appears about once a second.
- The probe shows `internet: true`.

- [ ] **Step 4: Record the result**

Add this line to test-plan §5:

`iOS, foreground: box link ok / probe true|false, join path auto|manual`

That's U3 for iOS in the foreground, plus U9.

- [ ] **Step 5: Commit**

```bash
git add packages/vroo_net docs
git commit -m "feat(net): iOS box join, box socket and cellular internet socket; device check"
```

---

### Task 11: App core: ride log, BoxLink and BoxConnection

**Files:**
- Create:
  - `app/lib/diag/clock.dart`, `app/lib/diag/ride_log.dart`
  - `app/lib/net/peer.dart`, `app/lib/net/box_link.dart`, `app/lib/net/box_connection.dart`
  - `app/test/fake_box.dart`, `app/test/ride_log_test.dart`, `app/test/box_link_test.dart`, `app/test/box_connection_test.dart`
- Modify:
  - `app/pubspec.yaml`, adding path dependencies on `vroo_protocol` and `vroo_net`, and the dev dependency `fake_async`.
  - `packages/vroo_net/lib/src/fake_vroo_net.dart`, adding the test-only `answerDnsProbes` switch.

**Interfaces:**
- Consumes:
  - vroo_protocol: `GroupKeys`, `Sealer`, `Dedupe`, `PacketHeader`, the payload codecs, `wrapEnvelope`/`unwrapEnvelope`, the box messages and the constants (Tasks 2–5).
  - vroo_net: `VrooNet`, `FakeVrooNet`, `NetEvent`, `JoinOutcome`, `probeInternet` (Task 8).
- Produces:
  ```dart
  abstract interface class Clock { int nowMs(); DateTime wallNow(); }
  class SystemClock implements Clock { … }      class FakeClock implements Clock { int ms; DateTime wall; }
  class RideLog { RideLog(StringSink sink, Clock clock); void write(String kind, Map<String, Object?> fields); Future<void> close(); } // close() flushes and closes when the sink is an IOSink
  class PeerInfo { final int id; String name; int lastHeardMs; int? rttMs; }
  class BoxLinkState { final bool boxUp; final BoxStatus? status; final bool? internetUp; final Map<int, PeerInfo> peers; }
  class BoxLink {
    BoxLink({required VrooNet net, required GroupKeys keys, required int myId, required String myName,
             required int platform, required Clock clock, required RideLog log, Random? random});
    Stream<BoxLinkState> get states;   // after every change and every second
    int get session;
    Future<void> start();              // new random session; beat each 1 s; status watchdog 3 s; probe each 5 s
    Future<void> stop();
  }
  enum BoxConnectionState { idle, joining, joined, needsManualJoin, denied }
  class BoxConnection {
    BoxConnection({required VrooNet net, required String ssid, required String password});
    ValueListenable<BoxConnectionState> get state;
    Future<void> start();   // joinBox; on BoxNetworkChanged(false) while joined, retry joinBox every 5 s
    Future<void> stop();
  }
  ```
- **RideLog line:** `<wallNow ISO-8601 UTC with ms>,<seconds since the log started, 1 decimal>,<kind>,<k=v joined by single spaces>`. In values, spaces become `%20` and commas become `%2C`.
- **BoxLink log kinds** used here: `box state=up|down`, `path internet=up|down` (logged on change only), `peer_back peer=<name>`, `drop reason=auth|short`.
- **Test helpers** (`test/fake_box.dart`), used by the tests below:
  ```dart
  class FakeBox { FakeVrooNet join(); void sendStatus(); }   // forwards each port-47000 datagram to every joined net, the sender included
  class Phone { final FakeVrooNet net; BoxLink link; BoxLinkState lastState; String get logText; void restartLink(); } // restartLink builds a new BoxLink, same id and name
  class Harness {
    final FakeBox box; late final GroupKeys keys; Phone get a; Phone get b;  // a = 'A' id 0xA, b = 'B' id 0xB
    Phone phone(String name, {required int id}); void startBoth();
    Opened? openNow(Uint8List packet, FakeAsync fa);   // Sealer.open, then flushMicrotasks
    Uint8List foreignEnvelope();                        // right tag, sealed with a different key
  }
  ```
  The suite derives `keys` once in `setUpAll`, outside fake time.

- [ ] **Step 1: Write the failing tests**

```dart
// ride_log_test.dart
test('log line format', () async {
  final clock = FakeClock(ms: 0, wall: DateTime.utc(2026, 10, 27, 10));
  final buf = StringBuffer(); final log = RideLog(buf, clock);
  clock.ms = 12340;
  log.write('box', {'state': 'up', 'name': 'Ravi K', 'note': 'a,b'});
  expect(buf.toString(), '2026-10-27T10:00:00.000Z,12.3,box,state=up name=Ravi%20K note=a%2Cb\n');
});
```

```dart
// box_link_test.dart — two phones on one FakeBox, fake time throughout
test('sends a sealed beat to the box every second', () => fakeAsync((fa) {
  final a = harness.phone('A', id: 0xA);  a.link.start(); fa.elapse(const Duration(milliseconds: 1100));
  final (port, data) = a.net.sentToBox.last;
  expect(port, boxDataPort);
  final u = unwrapEnvelope(data)!;  expect(u.groupTag, harness.keys.tag);
  final o = harness.openNow(u.packet, fa)!;
  expect([o.header.type, o.header.ttl, o.header.src], [PacketType.beat, 16, 0xA]);
  final beat = decodeBeat(o.payload)!;
  expect(beat.name, 'A');  expect(beat.flags & BeatFlags.hasBox, BeatFlags.hasBox);
}));
test('each phone lists the other, never itself', () => fakeAsync((fa) {
  harness.startBoth(); fa.elapse(const Duration(seconds: 2));
  expect(harness.a.lastState.peers.keys, [0xB]);  expect(harness.a.lastState.peers[0xB]!.name, 'B');
  expect(harness.b.lastState.peers.keys, [0xA]);
}));
test('echo replies give a round-trip time', () => fakeAsync((fa) {
  harness.startBoth(); fa.elapse(const Duration(seconds: 6));
  expect(harness.b.lastState.peers[0xA]!.rttMs, isNotNull);
  expect(harness.a.lastState.peers[0xB]!.rttMs, isNotNull);
}));
test('wrong-group packets and garbage are ignored and logged', () => fakeAsync((fa) {
  harness.a.link.start();
  harness.a.net.emit(BoxDatagram(boxDataPort, harness.foreignEnvelope()));   // same tag, other key
  harness.a.net.emit(BoxDatagram(boxDataPort, Uint8List.fromList(List.generate(60, (i) => i * 7))));
  fa.elapse(const Duration(seconds: 1));
  expect(harness.a.lastState.peers, isEmpty);
  expect(harness.a.logText, contains(',drop,reason=auth'));
}));
test('box goes down after 3 s without status and comes back', () => fakeAsync((fa) {
  harness.a.link.start(); harness.box.sendStatus(); fa.elapse(const Duration(milliseconds: 100));
  expect(harness.a.lastState.boxUp, isTrue);
  fa.elapse(const Duration(seconds: 3, milliseconds: 100));
  expect(harness.a.lastState.boxUp, isFalse);  expect(harness.a.logText, contains(',box,state=down'));
  harness.box.sendStatus(); fa.elapse(const Duration(milliseconds: 100));
  expect(harness.a.lastState.boxUp, isTrue);
}));
test('a restarted app gets a new session but stays one rider', () => fakeAsync((fa) {
  harness.startBoth(); fa.elapse(const Duration(seconds: 2));
  final s1 = harness.a.link.session;  harness.a.link.stop();  harness.a.restartLink();  harness.a.link.start();
  fa.elapse(const Duration(seconds: 2));
  expect(harness.a.link.session, isNot(s1));
  expect(harness.b.lastState.peers.keys, [0xA]);
}));
test('internet state follows the probe', () => fakeAsync((fa) {
  harness.a.link.start(); harness.a.net.answerDnsProbes = true;  fa.elapse(const Duration(seconds: 5, milliseconds: 100));
  expect(harness.a.lastState.internetUp, isTrue);
  harness.a.net.answerDnsProbes = false;  fa.elapse(const Duration(seconds: 8));
  expect(harness.a.lastState.internetUp, isFalse);  expect(harness.a.logText, contains(',path,internet=down'));
}));
test('stop sends nothing more', () => fakeAsync((fa) {
  harness.a.link.start(); fa.elapse(const Duration(seconds: 1)); harness.a.link.stop();
  final n = harness.a.net.sentToBox.length;  fa.elapse(const Duration(seconds: 3));
  expect(harness.a.net.sentToBox.length, n);
}));
```

`FakeVrooNet.answerDnsProbes` is a test-only switch added to the fake in this task. When it's on, the fake answers any query sent to 1.1.1.1:53 with a matching response.

```dart
// box_connection_test.dart
test('rejoins every 5 s after the box network is lost', () => fakeAsync((fa) {
  final net = FakeVrooNet()..nextJoinOutcome = JoinOutcome.joined;
  final c = BoxConnection(net: net, ssid: 'Vroo-A1B2C3', password: 'abcd-efgh-jkmn-pqrs')..start();
  fa.flushMicrotasks();  expect(c.state.value, BoxConnectionState.joined);
  net.emit(BoxNetworkChanged(false));  fa.elapse(const Duration(seconds: 11));
  expect(net.joins.length, 3);   // the first join plus two retries
}));
for (final (outcome, state) in [(JoinOutcome.needsManualJoin, BoxConnectionState.needsManualJoin),
                                (JoinOutcome.denied, BoxConnectionState.denied)]) {
  test('$outcome is reported, not retried', () => fakeAsync((fa) {
    final net = FakeVrooNet()..nextJoinOutcome = outcome;
    final c = BoxConnection(net: net, ssid: 's', password: 'abcd-efgh-jkmn-pqrs')..start();
    fa.elapse(const Duration(seconds: 11));
    expect(c.state.value, state);  expect(net.joins.length, 1);
  }));
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `cd app && flutter test`
Expected: FAIL. `RideLog`, `BoxLink` and `BoxConnection` are undefined.

- [ ] **Step 3: Implement `Clock`, `RideLog`, `PeerInfo`, `BoxLink`, `BoxConnection`, and the test helpers `FakeBox` and `harness`**

`BoxLink` behaviour:
- **Heartbeat:** each beat uses ttl `originTtl`, and seq goes up across all packet types.
- **On a beat from another rider:** if that rider's beat seq is a multiple of 5, reply with an `Echo(target: src, sentAtMs: beat.sentAtMs)`.
- **On an echo aimed at this phone:** `rtt = nowMs - sentAtMs`.
- **What it drops:** anything with `src == myId`, duplicates, and anything that fails to open. A failed open is logged once per second at most, so the log isn't flooded.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `flutter test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "feat(app): ride log, BoxLink heartbeats and delay, BoxConnection rejoin"
```

---

### Task 12: Test app screens: box setup, group QR, test screen, log sharing

**Files:**
- Create:
  - `app/lib/net/box_setup.dart`, `app/lib/box/box_store.dart`, `app/lib/group/group_store.dart`
  - `app/lib/ui/home_screen.dart`, `app/lib/ui/box_setup_screen.dart`, `app/lib/ui/group_screen.dart`, `app/lib/ui/test_screen.dart`
  - `app/test/box_setup_test.dart`, `app/test/stores_test.dart`
- Modify:
  - `app/lib/main.dart`
  - `app/pubspec.yaml`: `qr_flutter`, `flutter_zxing`, `shared_preferences`, `share_plus`, `path_provider`, `permission_handler`
  - `app/ios/Runner/Info.plist`: `NSLocalNetworkUsageDescription` "Talks to your Vroo box over its Wi-Fi." and `NSCameraUsageDescription` "Scans a group's QR code."
  - `app/ios/Runner/Runner.entitlements`: the Task 10 outcome
  - `app/android/app/src/main/AndroidManifest.xml`: `CAMERA`

**Interfaces:**
- Consumes: `BoxLink`, `BoxConnection`, `RideLog`, `SystemClock` (Task 11); `VrooNet` and `createVrooNet` (Task 8); and from vroo_protocol, `encodeInvite`, `decodeInvite`, `GroupKeys`, `newBoxPassword`, `boxSsid`, `encodeBoxConfig` and `decodeBoxStatus`.
- Produces:
  ```dart
  class SavedBox { final int boxId; final String ssid; final String password; }
  class BoxSetup {
    BoxSetup({required VrooNet net, required Random random});
    Future<SavedBox?> configure({Uint8List? groupTag, int? channel}); // on the setup Wi-Fi; null if no setup-mode status within 5 s
    Future<bool> assignGroup(Uint8List groupTag, int channel);        // on the box's normal Wi-Fi; true when a status arrives within 5 s
  }
  class GroupStore { Future<Invite?> load(); Future<void> save(Invite i); Future<void> clear(); }
  class BoxStore { Future<SavedBox?> load(); Future<void> save(SavedBox b); Future<void> clear(); }
  ```
- **Screens:** these are copy and flow decisions. The layout is the builder's choice.
  - **Home:**
    - A name field, saved locally.
    - "My box": **Set up a box**, **Use a box someone set up** (enter its name and password) and **Forget box**.
    - "Group": **Start group** and **Join group**.
    - **Start test**.
  - **Box setup:**
    1. "Plug the box in. Its light blinks once a second."
    2. `joinSetupNetwork()`. If that returns `needsManualJoin`, say "Open Settings → Wi-Fi and tap the network starting with Vroo-setup-, then come back."
    3. Call `configure()` with the current group's tag and channel, if there's a group.
    4. Show "Box Vroo-XXXXXX is ready. Its Wi-Fi password is xxxx-xxxx-xxxx-xxxx", with a **Copy password** button.
    5. Join the normal network. If that returns `needsManualJoin`, say "Open Settings → Wi-Fi, tap Vroo-XXXXXX, paste the password, then come back."
    6. It's done when a BOX_STATUS arrives.
  - **If setup fails:**
    - A null from `configure()` shows "The box didn't answer. Check its light is blinking once a second and that this phone is on its Vroo-setup- Wi-Fi."
    - `denied` shows "Wi-Fi permission is needed to reach the box. Allow it and try again."
  - **Group:**
    - **Start** makes a secret with `Random.secure()` and shows the QR of `encodeInvite` with the group name.
    - **Join** scans with `flutter_zxing`'s camera reader (or reads a QR from a photo) and runs `decodeInvite`. If the code isn't a ride invite, it says "That isn't a ride QR code."
    - After saving the group, if a box is saved, it calls `assignGroup(tag, channel)`.
  - **Test:**
    - Starts `BoxConnection` and `BoxLink`.
    - Shows the box (up or down, id, phones, rx/tx, drops), internet (✓ or ✗), and the riders (name, seconds since last heard, round-trip time in ms).
    - Buttons: **Stop** and **Share log**. Share log uses `share_plus` on the log file in the app documents folder.

- [ ] **Step 1: Write the failing tests**

```dart
test('configure sets a fresh password and returns the box', () => fakeAsync((fa) {
  final net = FakeVrooNet(); SavedBox? box;
  BoxSetup(net: net, random: Random(3)).configure(groupTag: keys.tag, channel: 11).then((b) => box = b);  // keys: derived in setUpAll
  fa.flushMicrotasks();
  final (port, data) = net.sentToBox.single;  expect(port, boxControlPort);
  final cfg = decodeBoxConfig(data)!;
  expect(cfg.wifiPassword, matches(RegExp(r'^[a-hjkmnp-z2-9]{4}(-[a-hjkmnp-z2-9]{4}){3}$')));
  expect([cfg.groupTag, cfg.channel], [keys.tag, 11]);
  net.emit(BoxDatagram(boxControlPort, encodeBoxStatus(const BoxStatus(boxId: 0x00A1B2C3, fwVersion: 1, uptimeS: 1, setupMode: true, phones: 1, rxFromPhones: 0, txToPhones: 0, dropDup: 0, dropTag: 0))));
  fa.flushMicrotasks();
  expect([box!.ssid, box!.password], ['Vroo-A1B2C3', cfg.wifiPassword]);
}));
test('configure gives up after 5 s without an answer', () => fakeAsync((fa) {
  final net = FakeVrooNet(); var done = false; SavedBox? box;
  BoxSetup(net: net, random: Random(3)).configure().then((b) { box = b; done = true; });
  fa.elapse(const Duration(seconds: 6));
  expect(done, isTrue);  expect(box, isNull);
}));
test('assignGroup sends only tag and channel', () => fakeAsync((fa) {
  final net = FakeVrooNet();
  BoxSetup(net: net, random: Random(3)).assignGroup(keys.tag, 11);  fa.flushMicrotasks();
  final cfg = decodeBoxConfig(net.sentToBox.single.$2)!;
  expect([cfg.groupTag, cfg.channel, cfg.wifiPassword], [keys.tag, 11, null]);
}));
test('stores keep the group and the box', () async {
  SharedPreferences.setMockInitialValues({});
  await GroupStore().save(Invite(secret, 'Sunday ride'));
  expect((await GroupStore().load())!.name, 'Sunday ride');
  await BoxStore().save(const SavedBox(boxId: 0x00A1B2C3, ssid: 'Vroo-A1B2C3', password: 'abcd-efgh-jkmn-pqrs'));
  expect((await BoxStore().load())!.ssid, 'Vroo-A1B2C3');
});
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `flutter test`
Expected: FAIL. `BoxSetup`, `GroupStore` and `BoxStore` are undefined.

- [ ] **Step 3: Implement the setup logic, the stores, the screens, and the platform configuration**

Run: `flutter test && flutter build apk --debug && flutter build ios --debug --no-codesign`
Expected: the tests pass and both builds succeed.

- [ ] **Step 4: Commit**

```bash
git add app
git commit -m "feat(app): box setup, group QR, test screen and log sharing"
```

---

### Task 13: Bench test with the founder, and write-up

**Files:**
- Modify:
  - `docs/test-plan.md`: §5 results
  - `docs/spec.md`: §10 statuses of U3 and U9
  - `docs/decisions.md`: D22 note
  - `docs/todo.md`: tick the M0 items and Plan A

**Interfaces:**
- Consumes: the whole test build (Tasks 7–12).

- [ ] **Step 1: Install the test build on both phones**

Run: `cd app && flutter run --release -d <iphone id>`, then `flutter run --release -d <android id>`.

👤 The founder keeps both phones unlocked, with mobile data on.

- [ ] **Step 2: 👤 Founder: run the bench checklist**

Read it aloud while doing it. Claude watches the screens' descriptions and the logs.

1. Erase the box's settings: hold BOOT for 5 seconds. The light then blinks once a second.
2. **Android:** type your name, then tap **Set up a box** and follow the screen until it says the box is ready.
3. **iPhone:** type a different name. Tap **Use a box someone set up**, then type the box name and password shown on the Android phone. If asked, join it in Settings.
4. **Android:** tap **Start group**.
5. **iPhone:** tap **Join group** and scan the code.
6. **Both:** tap **Start test**.

Expected:
- Within 3 s, each phone lists the other by name.
- The round-trip time shows, under 200 ms.
- The box line shows 2 phones.
- Internet shows ✓ on both.

7. Pull the box's USB cable for 10 seconds, then plug it back in.

Expected:
- Both phones show the box down within 3 s.
- Both show it up again within 20 s, without touching the phones.

8. **Both:** tap **Share log** and send the files to the Mac, for example by email to yourself.

- [ ] **Step 3: Write up the results**

Add a dated "Plan A bench" entry to test-plan §5 that covers:
- each expected line from Step 2, with pass or fail
- the measured round-trip times
- the recovery time after the power cut
- the iOS join path, automatic or manual

Then:
- Update the statuses of U3 (foreground) and U9 in spec §10.
- Tick the done items in todo.md.

- [ ] **Step 4: Commit**

```bash
git add docs
git commit -m "docs: Plan A bench results (U3 foreground, U9)"
```

**Plan A is done when** every `dart test`, `flutter test` and host test passes, the box probe passes, and the Task 13 checklist results are written up, whether they passed or failed.
