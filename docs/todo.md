# To-do

The ordered work list. Each milestone ends with a "done when" check. A detailed step-by-step plan gets written for each milestone just before it starts.

## Going public (D34)

- [x] Licences (GPL, AGPL, CC BY-SA), SPDX file headers, CONTRIBUTING, the CLA, SECURITY, the Code of Conduct and the defensive publication; private notes moved out of the repository (2026-11-25)
- [ ] Publish a fresh copy, with one first commit, as a public repository under `getvroo` (founder)
- [ ] Turn on private vulnerability reporting in the repository's security settings, which SECURITY.md relies on (founder)
- [ ] Bring the defensive publication up to date with the techniques added since 2026-10-27: voice, mobile data, the internet bridge and replay protection
- [ ] Optionally post the defensive publication to archives that patent examiners search (founder's choice, D34)

## M0 Project setup

- [x] Founder approves spec, architecture, hardware, decisions and test plan
- [x] Install Flutter (current stable) and ESP-IDF v5.x, and record both versions (in development.md: Flutter 3.47.8, ESP-IDF v5.5.6)
- [x] Create the git repository and the folder layout from architecture §3
- [ ] Fill in the device matrix in test-plan §2: phones, OS versions, intercoms, bike USB
- [ ] Record the model of the ESP32 on hand and check it supports long-range mode. Get one or two more boards for box-to-box tests, ideally with antenna connectors. The board on hand is fine for the first phone-to-box tests
- [x] iPhone distribution for M1: free cable installs from the Mac (decided 2026-10-27, D22)

**Done when** `flutter doctor` is clean for iOS and Android, an empty app runs on one iPhone and one Android phone, and an ESP32 board runs a test program.

## M1 Feasibility: the risky parts, on real phones and boxes

M1 is split into four step-by-step plans, each ending in something testable:

- **Plan A, setup and box link:** [docs/superpowers/plans/2026-10-27-plan-a-setup-and-box-link.md](superpowers/plans/2026-10-27-plan-a-setup-and-box-link.md). Also covers M0.
- **Plan B, voice:** [docs/superpowers/plans/2026-10-28-plan-b-voice.md](superpowers/plans/2026-10-28-plan-b-voice.md): `vroo_audio`, Opus, voice pipeline, talk slots, spoken alerts, Android foreground service. Built (2026-10-28); voice works on both desk phones. Still to do: the rest of the audio checks (calls, locked, intercom off and on), the two-phone bench, and the final review.
- **Plan E, mobile data (next, D33):** [docs/superpowers/plans/2026-11-18-plan-e-mobile-data.md](superpowers/plans/2026-11-18-plan-e-mobile-data.md): the relay server, voice over mobile data, the path policy and the two box modes, riding without a box, the internet bridge, and replay protection. Pulled forward from M2. Tasks 1–6 built (2026-11-18), with the final review's fixes (2026-11-19). Next: the desk bench (Task 7) and a relay on the internet (Task 8).
- **Plan C, box mesh (after Plan E):** [docs/superpowers/plans/2026-10-31-plan-c-box-mesh.md](superpowers/plans/2026-10-31-plan-c-box-mesh.md): ESP-NOW between boxes, simulator, flashing page, diagnostics (GPS distance, pretend talkers), bench, FT1–FT5. Its replay protection moves to Plan E.
- **Plan D, Bluetooth fallback:** FT10.

FT11 (modes and switching) needs the internet voice path, so it moves to M2 with the relay server.

- [ ] `vroo_protocol`: envelope, packets, encryption, dedupe, relay, bridge and cap rules, with unit tests and test vectors
- [ ] Mesh simulator: 10 to 200 boxes. Check the relay rule, talker cap and timer scaling (U11)
- [ ] Box firmware v0: hotspot, UDP bridge, ESP-NOW broadcast, groupTag filter, dedupe, relay rule, talker cap, beacon, status, config, lights. Host tests use the shared test vectors
- [ ] Flashing page for the box (ESP Web Tools)
- [x] `vroo_net`: join the box Wi-Fi, a socket bound to the box, a socket on mobile data, link events (Plan A, 2026-10-27)
- [ ] Android: rejoin the box without the Connect prompt, by naming the box's BSSID in the request once it's known (Plan A bench)
- [ ] iPhone: live QR scanning (reading the QR from a photo works) (Plan A bench). `mobile_scanner` is allowed now (D31)
- [ ] iPhone: get through on the first run after Local Network is granted (it needed an app restart) (Plan A bench)
- [x] Measure the round trip with voice running: mostly 10–30 ms (2026-11-18 bench); at one heartbeat a second it was 264 to 431 ms (Plan A bench)
- [ ] Box: don't rewrite the saved settings for an empty BOX_CONFIG; ride-log times in milliseconds (Plan A review notes)
- [ ] Plan A final-review notes (2026-10-28):
  - box setup: if the light no longer blinks once a second, tell the rider to hold the button for 5 s and start again (a lost setup reply)
  - "denied" also means nothing was found in 60 s, or the app was in the background: reword both screens, and offer Settings when a permission is permanently denied
  - iPhone: resend once on a fresh socket after the switch from the setup Wi-Fi, and reset a socket whose bind failed
  - box setup: send the config twice, so the box's routine status can't confirm a lost one
  - box: move the forward-or-drop decision into `vroo_wire`, with a host test, before Plan C adds relay rules; measure task stack use; report a failed reset; the dedupe table is about 40 KB, not 25 (architecture §4.8)
  - Test and group screens: close the log, and check `mounted`, when a screen closes mid-step
  - record the "light solid with a phone" check, and the Android check that Start test doesn't prompt again
- [ ] `vroo_audio`: voice in and out through the intercom's call link, echo cancelling, music-app-style call handling, spoken alerts and tones reaching the helmet
- [ ] Bluetooth fallback: check `ble_plus` against architecture 4.6, then use it, fork it, or write `vroo_ble`
- [ ] Opus over FFI on both platforms (try `flutter_opus` first)
- [ ] Path policy and talk slots in the app
- [ ] Android background: a foreground service that keeps the ride alive with the screen off
- [ ] Minimal ride screen, box setup and mode setting, plus diagnostics: ride log, stats, box status, GPS distance, "pretend extra talkers"
- [ ] Bench test with 2 to 3 phones, intercoms and boxes
- [x] Before boxes talk to each other: replay protection (a per-sender sequence window, accepting only sessions from recent authenticated heartbeats), and record box dedupe poisoning as a known limit (Plan A review). Done in Plan E: `ReplayGuard`, and heartbeats carry the wall clock (architecture §5.2)
- [ ] Field tests FT1 to FT5 and FT10 (test plan), then write up the results. In FT4 and FT8, also try a box whose DHCP offer has no router, so phones keep mobile data as the default for every app (Plan A review)
- [ ] Go or no-go on the box design and the Bluetooth fallback. Set radio speed, antenna position, N and the other knobs from the results

**Done when** those field tests are written up, the simulator results are in, and either the design is confirmed or a change is agreed and recorded in decisions.md.

## M2 Group release (v1)

- [ ] Start and join a group: secret, QR (including reading it from a photo), saved group, leave or forget
- [ ] Onboarding: name, permissions with reasons, Android battery setting, "Add my box", mode choice
- [ ] Full ride screen and settings: mode, mic sensitivity, diagnostics switch
- [ ] All spoken messages and tones from spec 7.5, including the rule that silences them for big groups
- [ ] Relay server in Dart with the talker cap, deployed to a small UDP host
- [ ] Internet bridge and local bridge (Bluetooth to box). The heartbeat's "has box" flag must then follow the real box state; today it's always set (Plan A review)
- [ ] End-to-end encryption checked on all paths. Confirm boxes can't read voice
- [ ] Keep the group secret and box passwords out of backups: they're in shared_preferences, which Android Auto Backup and iCloud copy. Use the Keychain (this device only) and Android's encrypted storage or a backup rule (Plan A review)
- [ ] Build and mount 6 boxes (5 plus a spare). Build about 10 boxes for the big-bench test (they can be reused)
- [ ] Builds and distribution for the group: APK, and TestFlight or cable. Check Google's developer-verification rules for sideloaded APKs first
- [ ] Field tests FT6 to FT9, FT11 and FT12, the big-bench test, then a full-day group ride

**Done when** the founder's group completes a full riding day, and the spec section 5 targets are met or consciously adjusted.

## M3 Public release and paid licences (v2, after the group release works)

- [ ] A short demo video from a real group ride, with the field-test numbers
- [ ] Builds anyone can try: a signed Android APK, and TestFlight on iPhone (needs the paid Apple account, D22)
- [ ] Continuous integration: protocol, plugin and app tests, firmware host tests, Android APK build, firmware build
- [ ] Versioning, a changelog, and box firmware binaries
- [ ] Relay server as a container image, with a deployment guide and the app's **Relay server** setting (D26)
- [ ] Relay server: a return-address check before anyone runs it for the public. It sends a cookie to each new address and forwards to it only once the cookie comes back, so forged addresses can't use it to send traffic at others (architecture §5.2; Plan E review)
- [ ] A list of every dependency and its licence, all permissive (D34)
- [ ] For companies interested in a paid licence: a short technical summary and the test results
- [ ] Tappable https invite links (needs the project's own web domain)
- [ ] TCP fallback for networks that block UDP
- [ ] Box firmware updates from the app
- [ ] Later idea: when nobody can be reached, let go of the intercom so its own built-in radio works

## Open decisions for the founder

Answered 2026-10-27:

- [x] Ride date: there isn't one. Keep the order: boxes and the risky parts first (D23)
- [x] Desk test devices: an iPhone and an Android phone. Record their models and OS versions in the device matrix during setup
- [x] Apple Developer account: not for now. M1 uses free cable installs from the Mac (reinstall every 7 days). Revisit before M2 (D22)
- [x] Box hardware for testing: one ESP32 on hand. Box-to-box tests need at least one more board

Still open:

- [ ] How often can 2 to 3 bikes go out for field tests? This sets how long M1 takes
- [ ] The group's phones, intercoms and bike USB (device matrix), before the M1 field tests
- [x] Patent: none. The design is published as prior art (D34, 2026-11-25)
- [ ] Trademark "Vroo": the licences don't cover the name, and a registered mark protects it better (D34)
- [x] The old history, which holds research files that name other companies: the public repository starts fresh, and the private one stays as an archive (D34)
- [ ] A relay server for the founder's group (self-hosted, about $5 a month), needed in M2
- [ ] Box parts for M2: about $15 to $30 per box. 6 boxes, plus about 10 boards for the big-bench test (reusable)
- [x] Name: Vroo (D29)
- [ ] Optionally reserve the domain getvroo.com or getvroo.app (about $10–15 a year)
