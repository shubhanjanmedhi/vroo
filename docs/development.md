# Development

How to set up the toolchain and build every part of Vroo. The design is in [architecture.md](architecture.md), and the work order is in [todo.md](todo.md).

## Repository layout

```
app/                     Flutter app (iOS + Android)
packages/vroo_protocol/  protocol v1 in pure Dart: shared by app, relay server and simulator
packages/vroo_net/       Flutter plugin: box Wi-Fi and network sockets (Swift + Kotlin)
packages/vroo_opus/      Opus codec: libopus 1.5.2 from source, compiled by a build hook (D32)
packages/vroo_audio/     Flutter plugin: voice through the intercom (Swift + Kotlin)   (Plan B)
packages/vroo_ble/       Flutter plugin: Bluetooth fallback (or ble_plus)              (Plan D)
firmware/                ESP32 box firmware (ESP-IDF, C), plus firmware/host_test for logic tests on your computer
sim/                     mesh simulator (Dart)                                          (Plan C)
server/                  relay server (Dart, UDP): see server/README.md to run one      (Plan E)
docs/                    spec, architecture, hardware, decisions, test plan, plans
```

## Toolchain

| Tool | Version | Notes |
|---|---|---|
| Flutter | 3.47.8 stable (Plan A was built with it) | `brew install --cask flutter` |
| Xcode | 26 or later (Plan A: 26.6) | iPhone builds need a Mac. Also install the iOS platform in Xcode → Settings → Components: without it, Xcode offers no iOS destination and `flutter build ios` fails with "No Xcode build settings have been found" |
| CocoaPods | Current (Plan A: 1.17.0) | `brew install cocoapods` |
| Android SDK and JDK 17 | Current (Plan A: SDK 36, JDK 17.0.21) | With Homebrew: `brew install --cask android-commandlinetools` and `brew install openjdk@17`, then `flutter config --android-sdk /opt/homebrew/share/android-commandlinetools --jdk-dir /opt/homebrew/opt/openjdk@17` |
| ESP-IDF | Newest v5.x release (Plan A: v5.5.6) | `git clone -b <tag> --recursive https://github.com/espressif/esp-idf.git ~/esp/esp-idf && ~/esp/esp-idf/install.sh`, then `. ~/esp/esp-idf/export.sh` in each shell. If downloads fail with `CERTIFICATE_VERIFY_FAILED` (python.org Python on macOS has no certificate store), prefix the commands with `SSL_CERT_FILE=/etc/ssl/cert.pem`, or `export` it in the shell first |
| CMake and Ninja | Current | `brew install cmake ninja`. ESP-IDF needs them on macOS, and so do the firmware host tests |
| ESP32 board | Any ESP32, ESP32-S3 or ESP32-C3 board (Plan A desk board: ESP32-D0WD-V3) | The firmware builds for `esp32` by default; other chips need `idf.py set-target esp32s3` (or `esp32c3`) first |
| Python 3 | For the test-vector oracle only | `python3 -m venv v && v/bin/pip install cryptography` |

Run `flutter doctor`. iOS and Android should be ✓.

## Phones and boards

None of the radio or intercom parts can be tested in simulators. You need real devices.

- **iPhone:**
  - Turn on Developer Mode: Settings → Privacy & Security → Developer Mode.
  - Sign in to Xcode with your Apple ID: Xcode → Settings → Accounts.
  - In `app/ios/Runner.xcworkspace`, set Signing & Capabilities → Team.
  - A free Apple ID works, but the app has to be reinstalled every 7 days. iPhones then join the box's Wi-Fi once by hand in Settings (decisions D22).
- **Android:**
  - Tap Settings → About phone → Build number seven times.
  - Turn on Developer options → USB debugging.
- **ESP32:**
  - Use a USB cable that carries data.
  - Find the port with `ls /dev/cu.usb*`.
  - Identify the chip with `esptool.py --port <port> chip_id`.

## Build and run

| What | Command |
|---|---|
| App on a phone | `cd app && flutter run -d <device id>` (`flutter devices` lists the ids) |
| Android APK | `cd app && flutter build apk --release` |
| A ride | **Start ride** on the home screen (it replaced Plan A's test screen). Each phone needs a paired intercom or earphones; without one, voice uses the loudspeaker |
| Firmware | `cd firmware && idf.py set-target <chip> && idf.py build && idf.py -p <port> flash monitor` |
| Relay server on this Mac | `cd server && dart compile exe bin/vroo_relay.dart -o build/vroo_relay`, then start `build/vroo_relay --port 47100` from Terminal.app (the editor's Local Network permission may be denied, and the relay has to answer phones on the home network) |
| Relay server for Linux | `cd server && dart compile exe --target-os linux --target-arch x64 bin/vroo_relay.dart -o build/vroo_relay-linux-x64`; installing it is in `server/README.md` |
| Box bench probe from a Mac | Join the box Wi-Fi, then `cd packages/vroo_protocol && dart run tool/box_probe.dart bridge --tag <hex>`. macOS must allow the app you run it from (Terminal, or your editor) in System Settings → Privacy & Security → Local Network; otherwise every send fails with "No route to host" |

## Tests

| Part | Command |
|---|---|
| Protocol | `cd packages/vroo_protocol && dart test` |
| Opus codec | `cd packages/vroo_opus && dart test` (the first run compiles libopus) |
| Network plugin | `cd packages/vroo_net && flutter test` |
| Network plugin, Android side | `cd packages/vroo_net/example && flutter build apk --config-only`, then in `android/`: `JAVA_HOME=/opt/homebrew/opt/openjdk@17 ./gradlew :vroo_net:testDebugUnitTest` (Gradle needs JDK 17, which the shell may not default to) |
| Audio plugin | `cd packages/vroo_audio && flutter test` |
| Audio plugin, Android side | `cd packages/vroo_audio/example && flutter build apk --config-only`, then in `android/`: `JAVA_HOME=/opt/homebrew/opt/openjdk@17 ./gradlew :vroo_audio:testDebugUnitTest` |
| App | `cd app && flutter test` |
| Relay server | `cd server && dart test` |
| Firmware logic | `cmake -S firmware/host_test -B firmware/host_test/build && cmake --build firmware/host_test/build && firmware/host_test/build/test_vroo_wire` |

Test vectors are produced by independent tools and shared between Dart and C:

- `packages/vroo_protocol/tool/oracle.py` computes them with Python's `cryptography`.
- `tool/gen_c_vectors.dart` writes `firmware/host_test/vectors.h`.

## Working on a milestone

Each milestone gets a step-by-step plan in `docs/superpowers/plans/` before code is written. Tick its checkboxes as you go, and record device results in [test-plan.md](test-plan.md) §5.

## Working rules

- **Docs first:** a change to what the app does, or how it's built, updates spec.md or architecture.md in the same change. Decisions get a dated entry in the decision log, `docs/decisions.md`, which stays private: git ignores it, and the public docs refer to its entries by number only. Old entries are marked superseded, never rewritten.
- **Protocol changes:** a change to protocol v1 (packets, crypto, envelope or box messages) needs new test vectors from `tool/oracle.py` and `tool/gen_c_vectors.dart`.
- **Tests first:** write the failing test, then the code. Every command under Tests passes before a commit.
- **Thin native code:** Swift and Kotlin move bytes and audio frames, and all decisions live in Dart. The box firmware never decrypts anything and never holds the group key.
- **Style:** `dart analyze` with no warnings, and lines up to 120 characters. Match the code around a change, and don't run `dart format` over whole files, which would rewrap them. C99 for the firmware. Commit messages look like `fix(net): rejoin the box after a power cut`.
- **Device results:** add them to [test-plan.md](test-plan.md) §5: date, phones, intercoms, boards, what passed and what failed.
- **Open source, with paid licences (D34):**
  - Every source file starts with an SPDX line: `// SPDX-License-Identifier: GPL-3.0-or-later`, or `AGPL-3.0-or-later` in `server/` (`#` comments where `//` doesn't work).
  - Dependencies need permissive licences, such as MIT, BSD, Apache-2.0, zlib or ISC, so Vroo can be licensed closed as well as open. Never GPL, LGPL, AGPL or another copyleft licence, and no proprietary SDKs. Note the licence in the change that adds the dependency.
  - Outside contributions need the contributor's agreement to [CLA.md](../CLA.md) ([CONTRIBUTING.md](../CONTRIBUTING.md)).
  - Packages keep `publish_to: none`.
- **Nothing personal in the repository,** which is public: no Apple team IDs (they go in the git-ignored `app/ios/Flutter/Local.xcconfig`), box passwords, group secrets apart from the fixed test vectors, ride logs, phone serial numbers, hardware addresses or home Wi-Fi names, and nothing about the business (that stays in private notes outside the repository).
