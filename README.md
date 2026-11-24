# Vroo

**Group voice for motorcycle riders: any intercom, any phone, with or without signal.**

![Status: prototype](https://img.shields.io/badge/status-prototype-orange) ![Licence: GPL-3.0](https://img.shields.io/badge/licence-GPL--3.0-blue) ![Platforms: iOS 17+ and Android 10+](https://img.shields.io/badge/platforms-iOS%2017%2B%20%7C%20Android%2010%2B-lightgrey)

**Status, 2026-11-25: an early prototype.**

- **Voice works on the bench.** An iPhone and an Android phone talk both ways through an ESP32 box, over the loudspeaker or earphones, with a round trip of 10–30 ms.
- **Voice over mobile data is built,** through a small relay server, and waiting for its first device test.
- **The box-to-box radio link comes next.**
- Nothing has been tested on a bike yet. Bench results are in [docs/test-plan.md](docs/test-plan.md) §5.

⭐ Star or watch the repository to follow along, or [help build it](CONTRIBUTING.md).

## Why

Riding in a group should mean talking as a group. Today it usually doesn't:

- **One rider at a time:** budget Bluetooth intercoms link to just one other rider. To talk to someone else, you disconnect and pair again.
- **Brands don't mix:** intercoms from different brands often refuse to pair, and some riders have no intercom at all.
- **Range runs out:** helmet-to-helmet range is short.
- **Apps need signal:** group voice apps need mobile data the whole time, and they break up on mountain roads.

Vroo puts the group conversation on the phone you already carry. Your intercom just has to do what it already does: connect to your phone.

## Features

Planned for v1:

- 🎙️ **Everyone hears everyone.** It's an open-mic group conversation, like a conference call. No buttons while riding.
- 🎧 **Any intercom brand, or plain earphones.** It uses your intercom's normal phone connection, so nothing needs pairing to anything else.
- 📱 **iPhone and Android in the same group.**
- 📶 **Talks without signal.** An optional ESP32 box on each bike passes voices from bike to bike, relaying along the group.
- 🌐 **Mobile data when you spread out.** The box and mobile data run together, and each voice plays from whichever copy arrives first, so a fading signal causes no gap.
- 🔵 **Bluetooth fallback.** Without a box, phones try Bluetooth to nearby riders when data drops. It's best effort (see [limits](#honest-limits)).
- 🔗 **Join with a QR code.** No accounts, no sign-up, and joining works offline.
- 📞 **Phone calls work as usual.** Your phone rings normally and you answer it the usual way. The group goes quiet for you and comes back by itself when you hang up.
- 🗣️ **Spoken alerts in your helmet.** For example "Ravi dropped off", "Ravi is back", and "You've lost the group. Move closer."
- 👥 **No fixed group size with boxes.** Up to 4 voices are carried at the same moment, and a busy tone tells you to wait.
- 🔒 **End-to-end encrypted.** Boxes, relays and servers pass voices along but can't listen.

## How it works

```
 your intercom ⇄ (its normal phone connection) ⇄ your phone ── Vroo app
                                                     │
            ┌────────────────────────────────────────┼─────────────────────────┐
            ▼                                        ▼                         ▼
   ESP32 box on your bike                     mobile data                Bluetooth
   (Wi-Fi to your phone,                  (relay server, when        (nearby phones, when
    long-range radio to                    there's signal)            data drops; best effort)
    the other bikes' boxes)
```

- **The phone does the work.** It records your voice, compresses it (Opus), encrypts it, and sends the same packet on every path that's working. Listening phones keep the first copy and drop the rest.
- **The box is a small relay.** Each one passes voices to the next bike using the ESP32's long-range mode. A group can stretch out as long as each bike can reach the next. It can't decrypt anything.
- **Calls take priority.** The app runs like a music player, not a phone call. When a real call comes in, the phone handles it normally.

The full design is in [docs/architecture.md](docs/architecture.md).

## What a rider needs

| | Required? | Notes |
|---|---|---|
| A phone | Yes | An iPhone on iOS 17+, or Android 10+ |
| An intercom or earphones | Yes | Any brand, paired with the phone as usual |
| An ESP32 box per bike | For talking without signal | About $15–30 in parts, powered from the bike's USB ([docs/hardware.md](docs/hardware.md)) |
| A relay server | For talking over mobile data | A small UDP server (about $5 a month), shared by the group |

## Trying it

There are no ready-made builds yet. For now, you build it yourself and install it by cable, from a Mac:

- **Phones and box:** [docs/development.md](docs/development.md) has the toolchain, build and flashing steps. With a free Apple account, the iPhone app has to be reinstalled every 7 days.
- **What to try:** on two phones, start a group on one and join it from the other with its QR code. Then either add a box ([docs/hardware.md](docs/hardware.md)), or run the relay server ([server/README.md](server/README.md)) and type its address on both phones. Tap **Start ride** and talk.

## Honest limits

- **Range without signal depends on the boxes.** Espressif says the long-range mode reaches up to about 1 km in open space. Between moving bikes, expect a few hundred metres per hop. Field tests will give real numbers.
- **The Bluetooth fallback may not work next to a Bluetooth intercom.** The phone's Bluetooth is busy with the intercom. Another rider intercom app reports the same. It should work with wired earphones.
- **Music pauses, or drops to call quality, while the group is on.** Every phone call does the same to music.
- **Up to 4 voices are carried at once.** No radio can carry a hundred, and nobody could follow them.

## Roadmap

| Milestone | What | State |
|---|---|---|
| M0 | Tooling, repository, devices | Done, apart from more ESP32 boards for box-to-box tests |
| M1 | The risky parts on real phones and boxes: box link, voice, mobile data, box-to-box range, Bluetooth fallback | In progress: the box link and voice work on the bench ([Plans A and B](docs/superpowers/plans/)); mobile data is built ([Plan E](docs/superpowers/plans/2026-11-18-plan-e-mobile-data.md)); box-to-box is next ([Plan C](docs/superpowers/plans/2026-10-31-plan-c-box-mesh.md)) |
| M2 | First full version, tested by the founder's riding group | Planned |
| M3 | Public release: builds anyone can install, a demo from a real ride, and a relay server that's easy to run | Planned |

The detailed list is in [docs/todo.md](docs/todo.md).

## Documentation

| Doc | What it answers |
|---|---|
| [docs/spec.md](docs/spec.md) | What the app does, and what "done" means |
| [docs/architecture.md](docs/architecture.md) | How it's built: app, native modules, box firmware, relay server, protocol |
| [docs/hardware.md](docs/hardware.md) | The box: parts, assembly, mounting, flashing |
| [docs/test-plan.md](docs/test-plan.md) | How it's tested, including on-bike field tests |
| [docs/development.md](docs/development.md) | Toolchain, build instructions and working rules for developers |
| [docs/defensive-publication.md](docs/defensive-publication.md) | Every technique in the design, published as prior art so that nobody can patent it |

## Licence

Vroo is free software. Copyright © 2026 Shubhanjan Medhi.

| Part | Licence |
|---|---|
| The app, plugins, protocol, box firmware and tools | [GNU GPL, version 3 or later](LICENSE) |
| The relay server (`server/`) | [GNU AGPL, version 3 or later](LICENSES/AGPL-3.0-or-later.txt) |
| The docs and the box design | [CC BY-SA 4.0](LICENSES/CC-BY-SA-4.0.txt) |

You can use, change and share Vroo. If you share a changed version, or run a changed relay server for others, you must publish its source under the same licence.

- **Paid licences for companies:** to build Vroo into a product without publishing your own source, ask for a licence on other terms: s.medhi1@gmail.com.
- **The name:** "Vroo" isn't covered by these licences. If you publish a changed version, give it a different name.

## Contributing

Issues, device test results and pull requests are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md). Contributors agree to a short [Contributor Licence Agreement](CLA.md), which lets the owner offer paid licences too. You keep your copyright.

## Safety and radio rules

- Never handle your phone or the box while riding. Set everything up before you leave, or at stops.
- The box transmits in the 2.4 GHz band. Use the module's approved antennas and the firmware's default power limits, and follow local radio rules.
- This is experimental software. Don't rely on it for emergencies.

Built with Flutter and Dart, Swift and Kotlin, Espressif's ESP-IDF and ESP-NOW in C, and Opus.
