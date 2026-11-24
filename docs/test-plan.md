# Test plan

Status: final draft · revised 2026-10-24 · Requirements are in [spec.md](spec.md), the design under test in [architecture.md](architecture.md) and the box in [hardware.md](hardware.md).

## 1. Levels

| Level | What | Where | When |
|---|---|---|---|
| Unit | `vroo_protocol` (envelope, packets, encryption, dedupe, relay, bridge and cap rules), path policy, talk slots, voice gate, jitter buffer, mixer, alert state machine | `dart test`, on the Mac and in CI | Every change |
| Firmware host tests | Box envelope parsing, groupTag filter, dedupe, relay rule, talker cap. Same test vectors as `vroo_protocol` | On the Mac | Every firmware change |
| Simulation | Mesh simulator with 10, 50, 100 and 200 boxes, bunched and strung out (architecture 4.10). Delivery, delay per hop count, airtime split | On the Mac | M1, and whenever timers or rules change |
| Bench | 2 to 3 phones, each paired with an intercom and joined to its own box, on a table. Voice both ways, calls, locked screens, box power cut, app killed and restarted, mode switching | Real phones and boxes | Each build before a ride |
| Big bench | About 10 boxes on a table or in a room, with "pretend extra talkers". Beacon and heartbeat scaling, talker cap, busy tone | Real boxes | M2 |
| Field | Bikes on the road, below | Quiet roads, founder's group | M1 and M2 milestones |

Simulators can't test intercom audio, phone Wi-Fi or Bluetooth, or box radios. The bench and field levels are the real proof. The simulator only covers what can't be tested on bikes: groups of 100.

## 2. Device matrix

Fill this in before the M1 field tests.

| Rider | Phone model | OS version | Intercom brand and model | Box ID | Box and antenna position | Bike USB (switched?) |
|---|---|---|---|---|---|---|
| | | | | | | |

Desk test devices for M1 (founder, 2026-10-27): one iPhone, one Android phone and one ESP32. Record their models and OS versions during setup. Box-to-box tests need a second ESP32.

| Desk device | Model and version | Notes |
|---|---|---|
| Desk ESP32 | ESP32-D0WD-V3 (revision 3.1), 4 MB flash, 40 MHz crystal | CP2102 USB-serial, `/dev/cu.usbserial-0001` on the Mac. Shipped with Espressif's AT firmware 2.4.0. Wi-Fi long-range (LR) mode: supported (ESP-IDF v5.5 Wi-Fi guide). Long serial reads drop through the Mac's USB-C hub; flashing at 115200 works |
| Desk iPhone | iPhone 13, iOS 27.0.1, with a SIM | Free Apple account: joins the box's Wi-Fi in Settings (D22). Xcode 26.6 (iOS 26.5 SDK) builds and installs on iOS 27 |
| Desk Android | Android 11 (API 30), a 2019 mid-range phone, no SIM | Has one Wi-Fi radio only: joining the box drops the home Wi-Fi, so its internet would have to come from mobile data |

Hardware addresses and box names stay out of this file: they identify one person's device.

## 3. Field tests

Every test runs in a diagnostics build with logging on. Logs go back to the developer, who turns them into numbers.

| # | Test | Setup | Measure | Pass (proposed) |
|---|---|---|---|---|
| FT1 | Box range per hop | 2 bikes on a quiet straight road. Ride apart slowly until "dropped off", then close in until "is back". Repeat for each antenna position (tail, handlebar, windscreen) and each radio speed (long-range 250 kbps, long-range 500 kbps, 1 Mbps) | Distance at loss and at recovery, signal | Record the numbers. They set the default speed and antenna position |
| FT2 | Box capacity | Parked, 3 boxes, "pretend extra talkers" stepped 0 to 4, at each radio speed | Lost packets, delay, box drops | 5% loss or less with N = 4 voices at the chosen speed. Otherwise lower N and record it |
| FT3 | Relay chain | M1: 3 bikes in a line, the middle box relays (2 hops). M2: 5 bikes (up to 4 hops) | End-to-end delay and loss | 400 ms or less and 5% loss or less end to end, at each hop count tested |
| FT4 | Phone stays on box and data | 30-minute ride, all screens locked, regroups at lights | Phone stays joined to its box? Internet path works at the same time? Rejoin time, app deaths | No app deaths. Box link and internet both up 95% or more of the ride, rejoin within 10 s |
| FT5 | Phone calls | Call each rider while riding: answer with the intercom button, with auto-answer, decline, make an outgoing call | Normal ringtone? Group silent both ways? Resume time? Box keeps relaying? | All calls answerable as usual, no audio leaks, resume within 2 s |
| FT6 | Internet and bridge | One rider with no box (data only). Another rides beyond box range with data, then switches to airplane mode | Box-less rider hears everyone? Far rider bridged? "Move closer" when every path is gone? | All work as specced |
| FT7 | Battery and heat | 2-hour ride, once on bike power and once without | Phone battery % per hour, intercom battery (in call mode the whole time), box and phone temperature on a sunny mount | Within spec targets. Note any charging pauses and when each intercom dies |
| FT8 | Navigation and music | Voice guidance from each navigation app the riders use, during the group. A music app playing | Prompts audible? What happens to music? | Prompts audible on at least one navigation app. Music behaviour documented |
| FT9 | Rain and vibration | Boxes on bikes through rain (or a hose test) and rough roads | Box still working, case dry, connectors tight | All boxes survive. Fix the case or mount if not |
| FT10 | Bluetooth fallback | 2 to 3 phones, no boxes, data off. First with wired earphones, then with Bluetooth intercoms. Parked, then riding close together | Does voice pass at all? Loss, delay, range. Does the intercom's own audio get worse? | With earphones: works within a few tens of metres. With intercoms: record the result. If it harms intercom audio, keep Bluetooth off while an intercom is connected (D20) |
| FT11 | Modes and switching | Riders with boxes in "Box + data", then "Box only". One box-less rider. Data deliberately throttled, then cut | Bluetooth comes on when data is slow or gone, and off again after recovery. No gap in voice. Box-less rider bridged over Bluetooth | Matches the spec 6.4 table. No audible gap on switching |
| FT12 | Talk slots | 6 riders (or pretend talkers) talking at once at a stop | First 4 heard, 5th and 6th get a busy tone and are heard when a slot frees | As specced |

## 4. Safety

- Nobody touches a phone or box while riding. Change settings at stops, or have a pillion handle the phone.
- Range tests run on quiet roads at low speed, within traffic law.
- Keep box cables clear of steering, chain and hot parts.
- If something misbehaves on a ride, stop somewhere safe before looking at it.

## 5. Results

Each field session ends with a short note added to this file: date, riders, phones, boxes, settings, what passed or failed, and the knob changes it led to. Decisions that change because of results go in decisions.md.

### 2026-10-27 desk checks (Plan A)

- **Box, from a Mac (Task 7):** setup and bridge probes pass (setup, forwarding within 500 ms, duplicate and foreign-group drops counted), the reset button works, and the status light follows the rules. On macOS, run the probe from Terminal: the editor's Local Network permission may not cover it.
- **Android, foreground (Task 9, U3):** box link ok / probe false on the box, true on home Wi-Fi. The phone joined the box through Android's own prompt, then got a box status every second after Register, and the box let it go 30 s after it last spoke. With no SIM, and only one Wi-Fi radio, the phone had no internet while on the box. Box plus mobile data still needs a phone with a SIM.

### 2026-10-27 Plan A bench (the box, the desk iPhone and the desk Android)

The Android app set the box up from scratch (fresh password) and started the group, which it sent to the box; the box moved to the group's channel 1, and the Android followed it by itself. The iPhone used **Use a box someone set up**, joined the box's Wi-Fi in Settings (the free account can't join from the app, U9), and joined the group from a photo of the QR code.

| Expected | Result |
|---|---|
| Each phone lists the other by name within 3 s | Pass, once both phones were on the box's Wi-Fi. At first the iPhone jumped to the home Wi-Fi, which has internet; on the road there's none to jump to |
| The round-trip time shows, under 200 ms | Shows, but over: Android 264 ms, iPhone 431 ms, at one heartbeat a second. Likely the phones' Wi-Fi power saving between packets. Measure again with voice running (50 packets a second) |
| The box line shows 2 phones | Pass (3 for up to 30 s while the box forgot a connection the iPhone had replaced) |
| Internet shows ✓ on both | iPhone pass: mobile data while on the box's Wi-Fi. The Android has no SIM, so its ✗ is right |
| Both show the box down within 3 s of the power cut | Pass on both |
| Both show it up again within 20 s, without touching the phones | iPhone pass: up 12.6 s after it showed down, including about 10 s with the box unpowered. Android fail: it doesn't rejoin by itself, and each new request shows Android's Connect prompt |

- **iOS join path:** manual (Settings), as D22 expects.
- **Fixed during the bench:**
  - The iPhone's box socket died when the box's Wi-Fi dropped. It's now replaced.
  - A restarted box handed the address an iPhone silently reuses to the Android. Each boot now starts its address pool at random.
  - A join made in iPhone Settings now counts as joined.
- **Still open:**
  - Android rejoining without the prompt.
  - Live QR scanning on the iPhone (the photo route works).
  - The round trip with voice running.
  - The iPhone's first run after Local Network is granted needed an app restart.

### 2026-10-28 audio checks (Plan B, Tasks 6 and 7)

Run with the `vroo_audio` example app on the desk phones, with Bluetooth earphones (the founder's intercom wasn't used).

- **Android audio check:** route Bluetooth and loudspeaker, hear yourself ok on both. Speech, intercom off and on, and locked 2 min not yet confirmed. Calls wait for a phone with a SIM.
- **iOS audio check:** route Bluetooth (24 kHz) and loudspeaker (48 kHz), hear yourself ok, speech ok, after the fix below. Earphones off and on, locked 2 min, and the call checks not yet run.
- **Fixed during the check:** the iPhone was silent at first: the mic level stayed at -90 dBFS, and the test message was made but never played. iOS stops the audio engine whenever the hardware's format changes, which happens just after every start as the route settles, and on every route change. The plugin now restarts the engine with a fresh mic tap in the new format each time, except during a call, whose end restarts it.

### 2026-11-18 Plan B bench, part 1 (the desk iPhone, the desk Android, one box on a battery)

Release builds of the app on both phones, after the review fixes. Bluetooth earphones on the iPhone; the Android on its loudspeaker and on earphones.

- **Voice both ways through the box:** works, on the loudspeaker and on earphones (founder).
- **Round trip with voice running:** mostly 10–30 ms, with spikes up to about 500 ms. Plan A measured 264–431 ms with heartbeats only, so the phones' Wi-Fi power saving between packets was the cause, as suspected.
- **Loss (the Android heard on the iPhone):** 0.3% over the first 4 minutes. One minute reached about 7%; the cause is unknown, so watch it in the full bench.
- **Earphones out and back in:** the iPhone moved to the loudspeaker and back to the earphones by itself, within 3 s.
- **Box power cut:** the iPhone rejoined by itself, 53 s after it showed the box down (Plan A: 12.6 s). iOS rejoins on its own schedule.
- **Fixed during the bench:**
  - The Android couldn't load the voice codec: the library wasn't linked with Android's maths library, so the Android carried no voice at all. Mac tests and the iPhone can't show this, because Apple's system library includes the maths functions.
  - An unhandled network error every 5 s on the Android with no SIM: a failed internet check is now just "no internet".
- **Found:** the Android had Vroo restricted in the background (its battery setting), which can stop the ride when the phone locks. Set Vroo's battery use to unrestricted before the lock tests. M2's onboarding must walk riders to this setting (spec 6.1).
- **Not run yet:** both phones locked for 10 minutes, the Android swipe-away, the iPhone restart, the call, Siri, and a navigation prompt.
