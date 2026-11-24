# Defensive publication: phone-based, intercom-agnostic group voice for vehicle groups, with optional relay boxes, multipath delivery and call-preserving audio

**Published as prior art.** Anyone may use these techniques. The aim is that nobody can patent them.

**History:** written 2026-10-27 as a defensive publication, kept private from 2026-10-28 while a patent was considered (D31), and published with the rest of Vroo on the founder's choice of no patent (D34, 2026-11-25).

## Purpose

This document describes every technique in the design, with variations, so that it serves as prior art: a dated, public description that makes later patents on these techniques invalid. [architecture.md](architecture.md) describes how Vroo builds them.

This is a technical description, not legal advice.

## 1. Field

Real-time group voice between people travelling together:

- motorcycle riders, cyclists and car convoys
- skiers, hikers, boats, marshals and event crews

It uses their own mobile phones and whatever headsets they already own. Optional low-cost radio relay devices extend reach where there's no cellular coverage.

## 2. Background

- **Dedicated mesh intercoms** give multi-party, long-range voice. They work only within one brand's hardware.
- **Budget Bluetooth intercoms** link one pair of riders at a time, and often won't pair across brands.
- **Phone apps** carry group voice over cellular data to any headset. Without coverage, they fail or fall back to brand-specific hardware.
- **An existing rider intercom app** reports that phone-to-phone Bluetooth can't carry voice while the phone is also running a Bluetooth headset's call link. It offers optional Wi-Fi router boxes for coverage.
- **Open-source mesh messengers** showed multi-hop Bluetooth LE relaying between phones.

The techniques below combine and extend these in new ways.

## 3. System overview

```
 headset (any brand) ⇄ hands-free (HFP) link ⇄ phone app
                                                │  identical encrypted packets on every available path
          ┌─────────────────────────────────────┼──────────────────────────────┐
          ▼                                     ▼                              ▼
 relay box on the vehicle              cellular relay server         phone-to-phone short-range
 (Wi-Fi to the phone;                  (forwards by group tag)       radio (Bluetooth LE), enabled
  long-range radio to other boxes)                                   only when cellular is absent
                                                                     or degraded
```

## 4. Disclosed techniques

Each technique is described with example parameters. "Variations" lists other ways to carry it out, which are disclosed as well.

### 4.1 Intercom-agnostic group voice through the phone's hands-free link

- **How it works:** a phone app opens a two-way, voice-quality audio session through the headset's ordinary phone-call profile (Bluetooth HFP), so any brand of headset works without pairing to other headsets. The app captures the wearer's voice and receives several remote voice streams. It mixes them on the phone (up to N at once), and plays the mix back through the same link.
- **Voice gate:** a voice-activity gate sends nothing while the wearer is silent. It compares energy against an adaptive noise floor and a threshold, with a hang time of about 300 ms and a pre-roll of about 40 ms. This saves airtime and keeps wind noise from many open microphones out of everyone's ears.
- **Variations:**
  - wired earphones, Bluetooth LE Audio headsets, vehicle hands-free systems
  - push-to-talk instead of voice activation
  - mixing in the headset, or in a relay device

### 4.2 Identical encrypted packets on all paths, first copy wins

- **Sending:** each voice frame (for example 20 ms of Opus at 12–16 kbps) is encrypted once and sent unchanged on every path that's currently available. The paths are local relay devices, a cellular relay server and phone-to-phone radio.
- **Packet identity:** each packet carries a sender ID (stable per install), a session ID (random per start) and a sequence number. That triple is used three ways:
  - as the AEAD nonce, for example ChaCha20-Poly1305 with nonce = sender ‖ session ‖ sequence
  - as the deduplication key at every receiver and relay, with a window of about 10 s
  - to identify the packet across paths
- **No switch-over:** receivers play the first copy and drop later ones. A failing path causes no gap and needs no switch-over logic.
- **Hop counter:** the hop counter (ttl) is excluded from the authenticated data, so relays can change it without breaking authentication.
- **Variations:**
  - other AEAD ciphers
  - per-frame sequence numbers inside bundles that carry several frames
  - deduplication by content hash

### 4.3 Per-vehicle relay boxes that can't read the voice

- **What a box is:** each vehicle may carry a small radio device (for example an ESP32-class microcontroller). It runs a password-protected Wi-Fi access point for its own rider's phones (for example up to 4), and a long-range broadcast radio to other boxes (for example ESP-NOW in Espressif's 802.11 long-range mode at 250 or 500 kbps).
- **No keys:** boxes never hold the content key. They route on a plain group tag that's derived one way from the group secret (for example the first 8 bytes of HKDF-SHA256(secret, "vroo/v1/tag")), and on the packet's plain header.
- **Forwarding:** a box delivers same-group packets to its own phones, drops duplicates, and rebroadcasts with the hop count reduced by one.
- **Relay suppression:** a box rebroadcasts a packet only if it has a neighbouring box that the box it heard the packet from doesn't have. Neighbour lists come from periodic plain beacons. In a bunched group only the originating box transmits, and down a strung-out line each box transmits once.
- **Channel choice:** the radio channel is derived from the group tag (for example 1, 6 or 11), which spreads nearby groups across channels.
- **Setup:** a new box opens an open setup network (for example "Vroo-setup-XXXXXX"). The rider's phone joins it and sends a configuration message (a new Wi-Fi password, the group tag and the channel). The box saves it and restarts on its private network. A long button press returns it to setup mode.
- **Joining a new group** only updates the box's group tag over the private network.
- **Variations:**
  - other radios: Wi-Fi long range, 802.11ah, sub-GHz FSK, Thread or 802.15.4, LoRa for status and metadata only
  - unicast with acknowledgements instead of broadcast
  - several packets packed into one radio frame
  - boxes powered by the vehicle's USB or a battery
  - boxes worn by a person
  - the phone linked to the box over USB or Bluetooth instead of Wi-Fi

### 4.4 Path policy that protects the headset link

- **Box and data together:** box and cellular paths run at the same time.
- **Phone-to-phone radio on demand:** short-range phone-to-phone radio (Bluetooth LE) competes with the headset's call link for the phone's radio time. So it's switched on only when the cellular path is absent or degraded, for example more than 10% loss or more than 600 ms round trip over 5 s, measured by echo replies to heartbeats. It's switched off again after a hysteresis period of healthy cellular, for example 30 s.
- **Modes:** a rider with a box chooses "box only" (no cellular use) or "box plus data".
- **If it hurts the headset:** if phone-to-phone radio degrades the headset's audio, it's disabled while a headset is connected.
- **Variations:** other thresholds, quality measures based on jitter, or user-selected policies.

### 4.5 Bridge election between local and internet paths

- **The election:** a phone becomes the bridge for its local cluster when two things are true. It has both a local path (its box, or phone-to-phone links) and internet. And no rider it hears locally with both flags set in their heartbeat has a lower ID. The election re-runs on every heartbeat.
- **What the bridge does:**
  - it uploads locally heard packets from riders that have no internet
  - it injects into the local paths the server packets from riders it hasn't heard locally for a few heartbeat intervals
- **Duplicates:** a brief double bridge is harmless, because deduplication drops the extra copies.
- **Local bridging:** a phone that has both a box and phone-to-phone links forwards packets between them, so nearby riders without a box join the box mesh.

### 4.6 Floor control and scaling for large groups

- **Talk slots:** at most N voices (for example 4) are carried at the same moment, with no fixed limit on group size.
  - A phone counts a rider as active if it received that rider's voice in the last 500 ms.
  - If N are active, the phone doesn't send. It plays a short busy tone to its wearer instead, and starts sending as soon as a slot frees.
- **Hard cap:** relay boxes and the server enforce the same cap. They admit voice from at most N distinct senders active within the last second, which covers simultaneous starts.
- **Scaling the chatter:** heartbeat and beacon intervals grow with group size, for example 1 s up to 10 members, then members ÷ 10 seconds, at most 10 s. Loss detection scales with them (4 intervals). Per-member spoken alerts are suppressed above a group size (for example 10). The hop limit rises for long convoys (for example 16).

### 4.7 Call-preserving audio session

- **Not a phone call:** the app runs as a background audio session, not a registered telephony call. Specifically, it doesn't use the platform's VoIP call integration (CallKit or Telecom). So an incoming cellular call rings with the normal ringtone, can be answered with the headset's button, and still triggers the headset's own auto-answer.
- **Silence both ways:** when the app detects a call through a call observer, an audio mode listener or an audio focus loss, it mutes both directions, from ringing until the call ends. Its own spoken alerts stop.
- **Resume:** it reactivates automatically afterwards, retrying if needed.
- **The rest of the group:** others are told the member is on a call. The member's relay box keeps relaying for everyone else, because it doesn't depend on the phone.

### 4.8 Spoken status rendered into the voice path

- **How it plays:** status messages are synthesised and rendered into the same output stream as the voices, so they reach the helmet through the hands-free link. The messages are:
  - "[Name] joined"
  - "[Name] dropped off" after a few seconds without packets on any path
  - a tone and "[Name] is back"
  - "[Name] is on a call"
  - "You've lost the group. Move closer." when the wearer has no path at all, repeated at an interval
  - "Your box is disconnected"
- **Variations:** tones only, distances included, other languages.

### 4.9 Server-free group formation and platform-aware radio roles

- **The invite:** a group is a 32-byte random secret, carried in a QR code or link, for example `vroo://join?v=1&s=<base64url secret>&n=<name>`. Joining works offline.
- **Derived values:** HKDF-SHA256 derives the content key, the routing tag, the radio channel and per-platform Bluetooth service UUIDs. That lets phones discover only their own group.
- **Platform roles:** some phones can't be discovered by other platforms while in the background. So phones of that kind always initiate (central role) towards phones that remain discoverable. Between phones of the same kind, the lower ID initiates, and the higher waits about 10 s and then initiates anyway.
- **Duplicate links:** if a pair ends up with two links, the one whose initiator has the lower ID is kept. Both ends compute the same answer.
- **Pending connects:** on platforms that keep connection attempts open indefinitely, reconnection to known peers uses those pending attempts, which also work in the background.

### 4.10 Field-test instrumentation

- **Range:** in diagnostics mode, heartbeats carry GPS coordinates, so each phone logs the distance to the other rider at the moment of link loss and recovery, for each mounting position and radio speed.
- **Load:** synthetic "fill" packets the size of voice packets are relayed but not played, to load the radio links in a controlled way.

### 4.11 Further variations disclosed

- **Box as the phone:** a relay box pairs directly with the headset as a hands-free audio gateway, taking the phone out of the voice path. The phone remains a configuration tool and an optional internet bridge.
- **Mixing in relays:** decoding and re-encoding at relays, instead of forwarding packets unchanged.
- **Delivery choices:** packing several packets into one radio frame, or using unicast with retries.
- **Other uses:** the same system for bicycles, cars, boats, skiing, hiking, events, search teams and industrial crews.
- **Other parts:** other codecs (LC3, AAC-ELD, ADPCM, Codec2) and other encryption ciphers.

## 5. References

- ITU-T G.114 (one-way transmission time).
- RFC 5869 (HKDF).
- RFC 8439 (ChaCha20-Poly1305).
- Espressif ESP-NOW and the 802.11 long-range mode documentation.
- This project's [architecture.md](architecture.md) holds the full design.
