# Architecture: Vroo

Status: approved · revised 2026-11-25 (open source, with paid licences: D34) · Read with [spec.md](spec.md) (what) and [hardware.md](hardware.md) (the box).

## 1. Shape of the system

```
 helmet intercom / earphones
          ▲  │   Bluetooth call connection (HFP/SCO), handled by the phone's OS
          │  ▼
┌──────────────────────────── each rider's phone ─────────────────────────────┐
│ Flutter app (Dart, one codebase)                                             │
│   UI ── RideEngine (paths · talk slots · alerts) ── VoicePipeline            │
│              │                                                               │
│              └──── Router (encrypt · dedupe · relay · bridge) ──────┐        │
│                                                                     │        │
│   native ▸ AudioDriver    native ▸ NetDriver           native ▸ BleDriver     │
│                            │ box socket  │ internet     (fallback only)      │
└────────────────────────────┼─────────────┼───────────────────┼──────────────┘
                   Wi-Fi to own box    mobile data     Bluetooth LE to nearby phones
                             │             │
          ┌──── box (ESP32, C) ────┐   Relay server (Dart, UDP)
          │ Wi-Fi hotspot ⇄ ESP-NOW │
          │ dedupe · relay · caps   │
          └───────────┬────────────┘
                      │  ESP-NOW long range, box to box
          other bikes' boxes ⇄ their phones
```

Three things get deployed:

- the Flutter app (iOS and Android)
- the box firmware (ESP32)
- the relay server

## 2. Principles

1. **App logic once, in Dart.** Native phone code only wraps OS APIs Dart can't reach: voice audio in and out, sockets tied to a specific network, and Bluetooth peer-to-peer. The drivers move bytes and audio frames and make no decisions.
2. **The box is a dumb, fast relay.** It never has the group key. It reads the plain routing header, filters by group, drops duplicates, enforces the talker cap, and passes packets on.
3. **One packet format on every path.** A voice packet is the same bytes through the boxes, over Bluetooth and over the internet, so the listener can keep the first copy.
4. **Paths run together, except Bluetooth.**
   - **Together:** the data and box paths run side by side, so a failing path costs no gap.
   - **Bluetooth:** switches on only when there's no healthy data path, because it competes with the intercom for the phone's Bluetooth radio.
5. **Any number of riders, a few voices at once.** Group size has no fixed limit. Airtime is bounded by carrying at most N voices at the same moment, and by slowing the background chatter as the group grows.
6. **No special phone or box.** Every box relays, and any phone can start the group. The only elected role is the internet bridge (6.4), and it re-elects itself on every heartbeat.
7. **Fail loud.** Every link, path, alert and audio event goes to the diagnostics log, and the box reports its neighbours and signal to its phone.
8. **Physical-world knobs stay tunable.** Field tests set these, rather than hard-coded guesses:
   - radio speed, channel and transmit power
   - voice-gate threshold, jitter buffer, hop limit and N
   - the "slow data" thresholds

## 3. Repository layout

```
app/                    Flutter app (iOS + Android)
  lib/ui/               screens
  lib/group/            group secret, QR, saved group
  lib/ride/             RideEngine: lifecycle, peers, path policy, talk slots, alerts, call state
  lib/voice/            voice gate, jitter buffer, mixer, Opus wrapper
  lib/net/              Router, box link, internet link, Bluetooth link, bridges
  lib/box/              box setup and configuration
  lib/diag/             ride log, stats, field-test tools
  test/
packages/
  vroo_protocol/        pure Dart: packets, crypto, dedupe, relay and bridge rules, talker cap.
                        Shared by app, server and mesh simulator
  vroo_audio/           Flutter plugin: Dart API + ios/ (Swift) + android/ (Kotlin)
  vroo_net/             Flutter plugin: Dart API + ios/ (Swift) + android/ (Kotlin)
  vroo_ble/             Flutter plugin: Dart API + ios/ (Swift) + android/ (Kotlin). Only if ble_plus fails, see 4.6
  vroo_opus/            Dart FFI package: libopus 1.5.2 compiled from source by a build hook (D32)
firmware/               ESP32 box (ESP-IDF, C), plus host-run tests of the relay logic
sim/                    Dart mesh simulator: 100+ boxes, airtime model, relay and cap rules
server/                 Dart UDP relay (vroo_relay): binary, container image, deployment guide
docs/
```

## 4. Components

### 4.1 RideEngine (Dart)

Owns a ride:

- starts and stops the drivers
- holds the peer table
- runs the **path policy** (4.3) and the **talk slots** (4.2)
- scales the timers to the group size (5.4)
- raises spoken alerts
- tracks call state and box state

It also watches the mic. Mic frames clock the whole pipeline, so if they stop for 2 s outside a call or an interruption, the ride screen says so and RideEngine asks AudioDriver to `restart()`, at most once every 10 s. Audio failures and interruptions ("paused") show on the ride screen too.

It must keep running with the screen locked:

- **iOS:** runs in the main isolate. The process stays alive because the audio session is active (background mode `audio`).
- **Android:** runs under a foreground service (types `microphone|connectedDevice`), in an isolate that survives the screen being closed. The mechanism is the builder's choice, for example flutter_foreground_task's service isolate, or a cached FlutterEngine held by the service. Acceptance: 2 hours with the screen locked and the app swiped away from recents, with no gap.

### 4.2 VoicePipeline (Dart)

- **Sending:**
  1. 20 ms audio frames (16 kHz, mono, 16-bit) come in from AudioDriver.
  2. **Voice gate:** energy is compared with an adaptive noise floor times a threshold, with a 300 ms hang and a 40 ms pre-roll.
  3. **Talk slot:** if N other riders (default 4) have sent voice in the last 500 ms, don't send. Play a short busy tone instead, at most once every 5 s, and start sending as soon as a slot frees up while the rider is still talking. Frames held back are dropped, not queued.
  4. **Opus encode:** 16 kHz, mono, 20 ms, 16 kbps VBR, in-band repair (FEC) on.
  5. The voice frame (frame number plus Opus bytes) goes to the Router.
- **Receiving:** each voice frame from the Router goes through:
  1. **Per-sender jitter buffer:** playback starts once 60 ms is buffered, skips ahead if more than 300 ms builds up, and Opus fills small gaps.
  2. **Decode.**
  3. **Mix** up to N voices, with a sum and a soft clip.
  4. 20 ms frames go back to AudioDriver.
- **Phone calls:** muted both ways while a call is ringing or active.
- **Knobs:** gate threshold, N, pre-buffer, buffer cap, bitrate.
- **Fallback:** if M1 shows Dart timing is too uneven for smooth playback, move the jitter buffer and mixer into AudioDriver, and record that in decisions.md.

### 4.3 Router and path policy (Dart)

**Path policy**, re-evaluated every second:

| Path | On when |
|---|---|
| Data | A relay server is set and its address is known, and either the rider has no box (the relay is their only path, so they send whatever the probe says) or they picked "Box + data" and the internet is up |
| Box | The rider has a box set up (sends are fire and forget) |
| Bluetooth | The mode is "Box only", or the data path is off or **slow** (Plan D) |

- **Internet up:** a DNS query to 1.1.1.1 over the internet path, every 5 s, answers within 2 s, or a packet came from the relay in the last 3 s. One lost probe isn't an outage: it goes down only after two failures in a row.
- **The relay's address:** an IP address is used at once. A name is looked up once the internet is up, with a DNS query to 1.1.1.1 over the internet path, never the system's lookup: on an iPhone the box's Wi-Fi can be the default network, and the box can't answer. If the internet is up but the name isn't found, the ride screen says "Relay server not found".
- **Slow data:** echo replies show more than 10% loss, or more than 600 ms round trip, over the last 5 s.
- **Hysteresis:** Bluetooth turns off again only after data has been healthy for 30 s, so it doesn't flap.

**Router behaviour** (in the app, `GroupLink`):

- **Sending:** own packets go out on every path that's on.
- **Receiving:** packets come in on every path. They're decrypted (dropped if that fails), deduped, and handled. The Router remembers which path each rider was last heard on.
- **Bluetooth relay rule:** a packet with ttl above 1 is forwarded with ttl minus 1 to every Bluetooth neighbour, except:
  - the link it came from
  - its original sender
  - the previous phone's own neighbours, taken from its last heartbeat
- **Local bridge:** a phone with both a box and Bluetooth links forwards packets between them, in both directions. Dedupe stops loops.
- **Internet bridge:** see 6.4.
- **Dedupe:** the key is (src, session, seq), and entries expire after 10 s.

### 4.4 NetDriver (native, thin), our own `vroo_net`

Dart-side API:

```
joinBox(ssid, password)   leaveBox()
events:  boxLink(up|down)   internet(up|down)   bytes(path: box|internet, data)
calls:   send(path, data)
```

Behaviour it must implement:

- **Join the box's Wi-Fi:**
  - **iOS:** `NEHotspotConfiguration`, saved (not join-once) so iOS rejoins by itself. It needs the Hotspot Configuration entitlement, and whether a free Apple account allows that is still unknown (U9). The fallback is joining once by hand in Settings. M1 runs without a paid account (D22), so build the Settings fallback first, and try the entitlement once the account exists.
  - **Android:** `WifiNetworkSpecifier`, which is app-scoped and leaves mobile data as the default network. A CompanionDeviceManager association can skip the approval dialog.
- **Two datagram sockets:**
  - one bound to the box's Wi-Fi network (the box is at 192.168.4.1)
  - one bound to mobile data, or to whatever network has internet
  - **Android:** needs `Network.bindSocket` for the box socket.
  - **iOS:** needs `Network.framework` with a required interface type, unless it routes this way on its own. M1 checks.
  - Either half drops away if plain Dart sockets turn out to route correctly on that platform.
- **Permissions:**
  - **iOS:** `NSLocalNetworkUsageDescription`.
  - **Android 13+:** `NEARBY_WIFI_DEVICES`.
  - **Android 10–12:** location, for Wi-Fi network requests. Confirm in M1.
- **Join helpers:** `wifi_iot` and `plugin_wifi_connect` are candidates for the joining part only. Neither binds a socket to a specific network, so the sockets stay ours.

### 4.5 AudioDriver (native, thin), our own `vroo_audio`

Dart-side API:

```
start(notificationText) → started | micDenied | failed      stop()      restart()  (fresh mic and playback streams)
stream micFrames            20 ms, 16 kHz, mono, int16
play(int16 frame)           queued for output; the native side holds at most 200 ms
synthesize(text) → int16    speech at 16 kHz, for Dart to mix with the voices and its own tones
events:  interruption(began|ended)   callState(ringing|active|idle)   route(output, name, rate)   failed(message)
```

Behaviour it must implement:

- **iOS:**
  - AVAudioSession `.playAndRecord`, mode `.voiceChat`, options `.allowBluetoothHFP` and `.mixWithOthers`. The mix option lets navigation prompts play.
  - Voice processing on (echo and noise cancelling), with other audio ducked as little as possible.
  - Resample whatever rate the hardware gives (8, 16, 24 or 48 kHz) to 16 kHz.
  - Take the mic through an `AVAudioSinkNode`, which gets it in IO-buffer-sized pieces (about 20 ms). A tap can't deliver less than 100 ms at a time, which would send voice in bursts.
  - iOS stops the engine whenever the hardware's format changes (a route change, or the route settling just after a start): restart it with a fresh mic capture each time. Outside a call, an interruption with no end notice (after Siri, say) is retried after 3 s.
  - When an interruption or a call ends (CXCallObserver), reactivate and restart, retrying if needed.
  - No CallKit (D7).
- **Android:**
  - `MODE_IN_COMMUNICATION`.
  - Route with `setCommunicationDevice(TYPE_BLUETOOTH_SCO)` on Android 12+, or `startBluetoothSco()` on Android 10–11.
  - Record with `AudioRecord(VOICE_COMMUNICATION)` and play with `AudioTrack(USAGE_VOICE_COMMUNICATION)`.
  - Hold audio focus GAIN. Pause on LOSS_TRANSIENT (calls, assistants) and resume on GAIN. A ducking request is a navigation prompt: Android doesn't duck speech for us, so the prompt plays over the group (OA1).
  - Detect calls with `OnModeChangedListener` (12+), or from audio focus (10–11).
  - No Telecom (D7).
- **Spoken alerts and tones:** the phone's text-to-speech renders speech to audio, which Dart mixes into the voice output with its own tones, so they go out over the intercom path. Never during the rider's own call. Route outputs are bluetooth, wired, speaker, earpiece or other.
- **Why our own:** checked 2026-10-24. `audio_io` has no echo cancelling, no routing to the call link, and no interruption handling. `audio_session` doesn't cover Android communication routing, and using it alongside our driver would split who owns the audio session.

### 4.6 BleDriver (native, thin), the fallback path

It only runs while the path policy has the Bluetooth path on.

Dart-side API:

```
start(serviceIos: UUID, serviceAndroid: UUID, info: bytes)   stop()
events:  linkOpened(linkId, isCentral)   bytes(linkId, data)   linkClosed(linkId, reason)   rssi(linkId, dBm)
calls:   send(linkId, data)   close(linkId)
```

Behaviour it must implement:

- **Advertising:** advertise this platform's group service UUID (5.1), and host one GATT characteristic holding {L2CAP PSM, rider ID}.
- **Linking:** scan for the group UUIDs, connect, read the characteristic, and open an insecure L2CAP channel. Data is end-to-end encrypted above this layer. Packets on the stream are u16 length-prefixed. Each phone keeps at most 3 links.
- **Who connects to whom.** Android can't see a locked iPhone, because iOS moves a background app's advertisement into an Apple-only "overflow area". So:
  - **iPhone to Android:** the iPhone always connects. Android never scans for iPhones.
  - **Same platform:** the lower rider ID connects. The higher one waits 10 s, then connects anyway.
  - **Duplicate links:** if a pair ends up with two links, keep the one whose connecting side has the lower ID.
- **Reconnect:**
  - **iOS:** keeps a pending `connect()` to known peers. These never time out and work in the background.
  - **Android:** keeps one long filtered scan, restarted every 10 min. Retries are at least 3 s apart.
- **Background:**
  - **iOS:** background modes `bluetooth-central` and `bluetooth-peripheral`. L2CAP channels must be reopened after state restoration.
  - **Android:** the work runs inside the ride's foreground service.
- **Expectation:** with a Bluetooth intercom connected, this may not carry voice at all (U10; another rider app reports this). It should work with wired earphones. Its effect on the intercom's own audio gets measured (FT10). If it hurts the intercom, the path policy keeps Bluetooth off while an intercom is connected.
- **Candidate:** `ble_plus` 1.0.4 (MIT licence). It claims both roles, L2CAP, background mode and iOS state restoration on Android 10+ and iOS 11+. It's barely used: unlisted on pub.dev, an unverified uploader, about 100 downloads (checked 2026-10-24). Check it in M1 against this list and read its native code, then use it, fork it, or write `vroo_ble`.

### 4.7 Opus (FFI)

Our own `vroo_opus`: libopus 1.5.2 (BSD-3) from the official source, compiled by a Dart build hook for each phone and for the Mac, so the codec runs in `dart test` too. No prebuilt binaries. A small C shim gives Dart the encoder settings, because FFI can't call libopus's variadic `opus_*_ctl` functions. `flutter_opus` and `opus_dart` were checked and skipped (D32).

### 4.8 Box firmware (ESP32, ESP-IDF, C)

The board gets chosen in M1 (see hardware.md). It must be an ESP32 chip with Espressif's 802.11 long-range mode and an external antenna connector.

- **Wi-Fi hotspot:** for the rider's phones.
  - 802.11b/g/n with WPA2, up to 4 phones.
  - A fixed channel (5.1).
  - SSID `Vroo-<box id>`, with the password set by the owner's app.
- **UDP bridge:** on 192.168.4.1, at a port the builder records in the protocol package.
  - **From a phone:** check the groupTag, check dedupe, check the talker cap, broadcast over ESP-NOW, and hand the packet to any other phones on this box.
  - **From ESP-NOW:** check the groupTag, check dedupe, hand the packet to this box's phones, then relay it.
- **ESP-NOW:** broadcast frames on the hotspot's channel, sent from the station interface. The radio speed is a knob, with defaults set by FT1 and FT2:
  - long-range 250 kbps (furthest)
  - long-range 500 kbps
  - 1 Mbps or faster (most capacity)
- **Relay rule:** a box rebroadcasts a new packet (ttl above 1, sent on with ttl minus 1) only if it has a neighbour box that the box it heard the packet from doesn't have. Neighbour lists come from box beacons.
  - In a bunched group, only the sender transmits.
  - Down a strung-out line, each box passes the packet on once.
- **Talker cap (hard limit):**
  - The box admits voice from at most N distinct riders. A rider counts as active if their voice was heard in the last 1 s.
  - Voice from anyone else isn't relayed while all N slots are taken. The app's talk slots (4.2) normally keep things from getting that far. This cap catches the case where several riders start at the same instant.
  - Heartbeats and echoes are never capped.
- **Box beacon:** sent in the clear (no secrets; the groupTag is derived one way). It carries:
  - box ID and groupTag
  - up to 16 neighbour box IDs with signal strength (the strongest ones)
  - firmware version
  - The interval grows with the number of neighbours (5.4).
- **Status to the phone (every second):** neighbours, signal, packet and drop counts, and capped-talker counts.
- **Configuration from the phone:** groupTag, Wi-Fi password, channel, radio speed, transmit power, N and ttl. It's saved to flash. The change is authenticated by the box's own password-protected Wi-Fi.
- **Memory:** the dedupe table is sized for large groups: about 2,000 entries over the 10 s window, roughly 25 KB.
- **Lights:** power, phone connected, other boxes heard.
- **Airtime fallback:** if airtime runs out in FT2, pack several packets into one ESP-NOW frame, with a waiting time as the knob. That's not in the first version.
- **Size:** roughly 800 to 1,200 lines of C. The relay, dedupe, cap and envelope code gets host-run tests that use the same test vectors as `vroo_protocol`.

### 4.9 Relay server (Dart)

- **Forwarding:**
  - One UDP port, 47100 by default. Each datagram is groupTag (8 bytes) followed by the packet. It's accepted when it's 39–512 bytes and its packet starts with a protocol v1 header.
  - The server keeps a map from groupTag to {address: last seen}. An address is the IP and port a phone last sent from, so a phone behind carrier NAT is reached where its packets come from. It forwards each datagram to every other address in that group seen in the last 30 s, never back to the sender.
  - It doesn't decrypt or store anything. Every 10 s it logs one line of counters: groups, addresses, packets in and out, and drops for size, rate, the talker cap, sends the system refused, and full groups.
  - A send the system refuses (a routing blip, a phone gone from the network) is counted, never fatal. A datagram from port 0 is dropped, since nothing can be sent back there.
- **Talker cap:** the same as the box, so internet-only riders get the same N.
- **Keepalive:** phones send heartbeats, which also keep mobile-network address mappings open.
- **Limits:**
  - Rate limits are token buckets: 200 packets a second per address (a burst of 400), and 2,000 a second per group (a burst of 4,000). Over a limit, or oversized, a datagram is dropped.
  - A new address is refused past 256 in one group, 16 from one host in one group (riders on one café Wi-Fi, or behind one carrier address, share a host), or 50,000 in all. So forged addresses can't grow the server's memory or work without bound (§5.2), and a datagram goes out at most 255 times.
  - A group's rate limit and talker cap are forgotten with its last address.
- **Hosting:** self-hosted (D26).
  - The server ships as a container image and a single binary.
  - One small VM or container with UDP (about $5 a month), near the riders, serves a group or a club.
  - The app has a **Relay server** setting (address and port), so each group points at its own. The project doesn't promise to run a public relay.
  - With N = 4 talkers in a 100-rider group, the server sends out roughly 12 Mbit/s.
- **No TLS:** not needed, because payloads are end-to-end encrypted.
- **Blocked UDP:** where UDP is blocked, the internet path is simply unavailable in v1. A TCP fallback comes in v2.

### 4.10 Mesh simulator (Dart)

A command-line simulation of 10 to 200 boxes, in a bunched group and in a strung-out convoy. It runs the real `vroo_protocol` relay and cap rules, plus a C-equivalent box model, over an airtime and loss model. It reports:

- delivery
- delay per hop count
- airtime used by voice compared with beacons and heartbeats

It settles how the timers should scale with group size (U11) before any hardware exists.

## 5. Protocol v1

### 5.1 Group secret and derived values

The starter's phone creates `groupSecret`, 32 random bytes. Everything else is derived from it:

```
key        = HKDF-SHA256(groupSecret, info="vroo/v1/key")               32 bytes, ChaCha20-Poly1305
groupTag   = HKDF-SHA256(groupSecret, info="vroo/v1/tag")[0..8]          box and relay-server routing
channel    = 1, 6 or 11, picked from groupTag                             spreads nearby groups (overridable)
bleIos     = UUID from HKDF(groupSecret, "vroo/v1/ble-ios")[0..16]       Bluetooth fallback discovery
bleAndroid = UUID from HKDF(groupSecret, "vroo/v1/ble-android")[0..16]
```

The QR carries `vroo://join?v=1&s=<base64url(groupSecret)>&n=<group name>`. Tappable https links come in v2.

### 5.2 Envelope and packet

**Envelope.** Every path except Bluetooth wraps each packet as groupTag (8 bytes) ‖ packet. That covers phone and box (UDP), box to box (ESP-NOW broadcast) and phone and server (UDP).

**Bluetooth framing.** Bluetooth carries the bare packet, u16 length-prefixed, because the link itself is already group-specific.

**Packet layout:**

```
offset size field
0      1    version   1
1      1    type      1 HELLO (Bluetooth links only) · 2 VOICE · 3 BEAT · 4 ECHO · 5 FILL (diagnostics builds only)
2      1    ttl       hops left (boxes and Bluetooth relays); 0 for HELLO
3      4    src       rider ID: random u32, stable per install
7      4    session   random u32, new every ride start
11     4    seq       per-sender counter for this session, across all packet types
15     n    payload   encrypted
15+n   16   tag       Poly1305
```

- **Encryption:** ChaCha20-Poly1305.
  - The nonce is src ‖ session ‖ seq: 12 bytes, never repeated for a key.
  - The AAD is bytes 0–1 and 3–14. ttl is left out because relays change it.
- **What boxes read:** only bytes 0–14 and the groupTag.
- **Dedupe key:** (src, session, seq), on phones and boxes alike.
- **Byte order:** integers are big-endian.
- **Size:** a voice packet is about 71 bytes plus the 8-byte envelope, well inside ESP-NOW's 250-byte frame.

**Box messages** (BOX_BEACON, BOX_STATUS, BOX_CONFIG) are separate. They aren't encrypted and never leave the box mesh, except the status a box sends to its own phones. They start with their own version and type bytes. The builder fixes their layouts in `vroo_protocol` and the firmware, from one spec table.

**Replay protection (phones, after decryption).** Anyone who hears the boxes, or sits on the internet path, can record sealed packets and send them again later, after the 10 s dedupe window. So each phone keeps, per (src, session):

- a window of the 1,024 newest sequence numbers it has accepted: anything older, or already seen, is dropped
- the time of the session's last accepted BEAT: its VOICE and ECHO count only within 40 s of one (four times the longest heartbeat interval), while FILL needs only the window
- and a BEAT counts only if its sentAt, the sender's wall clock, is within ±10 minutes of this phone's, so a session recorded long ago can't come back to life

Sessions are forgotten 10 minutes after their last accepted packet. A rider whose phone clock is more than 10 minutes wrong isn't heard, and the drop is logged as `stale`. It doesn't pass silently:

- The refused heartbeat has passed its seal, so its name and clock are genuine. Other phones show "Ravi's phone clock is 2 h off" when they hear the rest of the group, or "Ravi's phone clock and this one are 2 h apart" when they hear nobody, since either clock could be the wrong one.
- A phone that hears nobody, and finds two or more riders off by the same amount (within a minute), shows "This phone's clock is 2 h off".
- A phone that hears nobody because of the clocks says once: "The phone clocks are too far apart to hear each other."
- A refused heartbeat from a rider who is heard is an old one played again, and shows nothing.

**Limits, by design:**

- **The QR is the key.** Anyone with a group's QR code or invite link can join that group, so riders share it only with each other.
- **Relays see metadata.** Boxes and the relay server see the groupTag, sender ID, sequence numbers and timing, but never content.
- **Boxes can be fooled by forged headers.** A stranger who copies a rider's src, session and next seq can make boxes drop the real packet as a duplicate, because boxes can't check seals. Phones check seals before deduping, so they can't be fooled this way.
- **The relay server trusts the plain header and the sender's address.**
  - Anyone holding a group's tag (someone on the network path, or a former rider) can receive the group's sealed relay traffic. They can also mute its relay voice by sending VOICE under made-up rider IDs, because the talker cap trusts the header, or use up the group's 2,000 packets a second.
  - Someone who can forge source addresses can make the relay send a group's traffic to machines that never asked for it: at most 255 copies of each datagram, and 16 to any one host.
  - The fix is a return-address check: the relay sends a cookie to each new address and forwards to it only once the cookie comes back. It's planned before anyone runs a relay for the public (todo).
- **Radios can be jammed.** That goes for the box mesh and the Bluetooth fallback, like any radio.

### 5.3 Payloads (after decryption)

- **HELLO:** link-local, the first packet both ways on each Bluetooth link.
  - platform u8 (0 iOS, 1 Android)
  - name: u8 length, then up to 32 bytes of UTF-8
  - A link whose HELLO fails to decrypt belongs to another group and is closed.
- **VOICE:** frameNo u32, then one Opus frame (20 ms). frameNo counts the sender's 20 ms mic frames since the ride started, sent or not, so a gap inside a talk spurt is a loss. The jitter buffer orders frames by frameNo.
- **BEAT:** the heartbeat, sent on a timer (5.4).
  - platform u8
  - flags u8: bit0 talking, bit1 on a call, bit2 has internet (it sends over mobile data now), bit3 has box (its box answered in the last 3 s), bit4 Bluetooth on, bit5 diagnostics
  - battery u8
  - sentAt u32: the sender's wall clock, in milliseconds since the Unix epoch, low 32 bits. Receivers check it for replays (5.2), and the sender measures round trips with it when the ECHO comes back
  - Bluetooth neighbours: u8 count, then that many u32 rider IDs, for the Bluetooth relay rule
  - name
  - When diagnostics is on: lat f32, lon f32, accuracy u16. Before the first GPS fix, lat and lon are NaN.
- **ECHO:** target u32, sentAt u32. A reply to the 1st and every 5th BEAT received from each rider, counted by the receiver: voice packets share the sender's sequence counter, so seq can't pick the beats. Used for delay and the "slow data" test.
- **FILL:** VOICE-sized, relayed but not played. It drives "pretend extra talkers" in diagnostics builds.

### 5.4 Timers and limits (all tunable)

| What | Value |
|---|---|
| Heartbeat interval | 1 s for up to 10 riders, otherwise (riders ÷ 10) s, at most 10 s |
| Rider counts as lost | 4 heartbeat intervals of silence on every path |
| Box beacon interval | 1 s for up to 10 neighbours, otherwise (neighbours ÷ 10) s, at most 10 s |
| Box disconnected warning | after 10 s |
| Alone warning | after 4 s, then repeated every 60 s |
| Talker cap N | 4 |
| Echo | on every 5th heartbeat |
| Slow data | over 10% loss or over 600 ms round trip, across 5 s |
| Bluetooth-off hysteresis | 30 s |
| Dedupe window | 10 s |
| ttl | 16 |
| Jitter buffer | starts at 60 ms, caps at 300 ms |
| ESP-NOW speed, channel, power | set by FT1 and FT2 |

The simulator (4.10) checks these against groups of 100 or more before field use.

## 6. Key flows

### 6.1 Starting a ride

1. Check permissions.
2. Start `AudioDriver`.
3. `NetDriver.joinBox`, if the rider has a box.
4. Open the internet socket, if the mode and signal allow it.
5. Make sure the box has this group's tag.
6. Path policy decides on Bluetooth.
7. Heartbeats start, and "joined" alerts play (up to 10 riders).

### 6.2 Talking

1. A mic frame passes the voice gate (silence sends nothing).
2. Talk-slot check: when all N slots are taken, play the busy tone instead of sending.
3. Encode with Opus.
4. Build an encrypted VOICE packet.
5. Send it on every path that's on.
6. Boxes broadcast and relay it, subject to their own cap. Bluetooth neighbours relay it by the Bluetooth rule.

### 6.3 Hearing

1. A packet arrives through the box, the relay or Bluetooth (often several).
2. It's decrypted and deduped. Later copies are dropped.
3. Local and internet bridges apply (4.3, 6.4).
4. It goes to the VoicePipeline, which mixes up to N voices.

### 6.4 Internet bridge election

A phone is the bridge for its local cluster when two things are true:

- It has internet and a local path (its box, or Bluetooth links).
- No rider it hears locally with "has internet" and a local path has a lower ID.

The bridge does two extra jobs:

- It uploads packets heard locally from riders whose heartbeat says they have no internet.
- It sends into its local paths, with ttl 16, the relay packets from riders it hasn't heard locally for 4 heartbeat intervals.

Other phones upload only their own packets. The election re-runs on every heartbeat. A brief double bridge is harmless, because dedupe drops the extra copies.

As built (Plan E, `GroupLink`):

- **"Heard locally"** means the rider's own heartbeat says their box answers, and a copy of their packets (the first or a later one) came through the box in the last 4 heartbeat intervals. A rider with no box is never local, even when a bridge has brought their packets into the box. So when the bridge changes, the new one brings internet-only riders in at once.
- **A known limit:** a rider who has a box but rides in another cluster, beyond the mesh, reaches this cluster only through a bridge. When the bridge changes, the new one sees that rider's packets in the box (from the old bridge) for up to 4 heartbeat intervals. During that time the cluster's box-only riders don't hear them.
- **The log** records `bridge,state=on|off`, and the ride screen says when this phone is the bridge.

### 6.5 Losing and regaining riders

- Each rider is tracked as reachable on any path, or not. The spoken alerts in spec 7.5 play on changes, for groups of up to 10.
- If nobody is reachable on any path for 4 s, you hear "move closer".
- If your box is gone for 10 s, you hear "Your box is disconnected".
- Path changes, such as Bluetooth switching on, are silent.

### 6.6 Phone call

1. AudioDriver reports the call state.
2. RideEngine marks the rider as on a call. Voice is muted both ways, and the heartbeat flag is set.
3. The others hear "[Name] is on a call" (up to 10 riders).
4. The box keeps relaying for everyone else.
5. When the call ends, the app resumes within 2 s, retrying if needed, and clears the flag.

### 6.7 Box setup (once per box)

1. A freshly flashed box opens an open setup Wi-Fi, `Vroo-setup-<id>`.
2. The app joins it and sends BOX_CONFIG: a random Wi-Fi password, the current groupTag and the default radio settings.
3. The box saves these and restarts on its own password-protected Wi-Fi.
4. The app stores the SSID and password, and from then on joins by itself.

A long press of the box's button returns it to setup mode, in case the phone that set it up is lost.

## 7. Platform configuration

### 7.1 iOS (Info.plist and entitlements)

- **Usage descriptions:**
  - `NSMicrophoneUsageDescription`
  - `NSCameraUsageDescription` (QR)
  - `NSBluetoothAlwaysUsageDescription` (Bluetooth fallback)
  - `NSLocalNetworkUsageDescription` (box)
  - `NSLocationWhenInUseUsageDescription` (diagnostics only)
- **Background modes:** `audio`, `bluetooth-central`, `bluetooth-peripheral`. Add `location` only in diagnostics builds, which means two build flavors.
- **Entitlement:** Hotspot Configuration (U9).
- **URL scheme:** `CFBundleURLTypes` for `vroo://`.

### 7.2 Android (manifest)

- **Audio and camera:** `RECORD_AUDIO`, `CAMERA`, `POST_NOTIFICATIONS`.
- **Bluetooth:**
  - `BLUETOOTH_SCAN`, with `usesPermissionFlags="neverForLocation"`
  - `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`
  - the legacy `BLUETOOTH` and `BLUETOOTH_ADMIN`, with `maxSdkVersion` 30
- **Wi-Fi:**
  - `NEARBY_WIFI_DEVICES` (13+, `neverForLocation`)
  - `ACCESS_FINE_LOCATION` on 10–12: needed for Bluetooth scanning and Wi-Fi requests on those versions, and used for diagnostics GPS
- **Network:** `CHANGE_NETWORK_STATE`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`, `INTERNET`.
- **Foreground service:** `FOREGROUND_SERVICE`, plus `_MICROPHONE` and `_CONNECTED_DEVICE`.
- **Other:** `MODIFY_AUDIO_SETTINGS`, `WAKE_LOCK`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.
- **Service and intents:** foreground service types `microphone|connectedDevice`, and an intent filter for `vroo://`.
- **Minimum SDK:** 29.

## 8. Diagnostics

- **Log format:** one line per event: `ISO-time,seconds,kind,key=value…`. Kinds are `app`, `box`, `path`, `ble`, `peer_lost`, `peer_back`, `stats`, `call`, `audio`, `route`, `bridge`, `slot`, `error`.
- **Stats:** every 5 s, per rider: paths, hops, delay (from echo), voice packets and loss, battery. Box status adds neighbours, signal, drops and capped talkers.
- **Sharing:** through the phone's share sheet.
- **Field-test tools:** GPS distance in heartbeats, and the FILL load generator.

## 9. Technology choices

| Need | Choice | Status |
|---|---|---|
| App framework | Flutter (latest stable at setup, 3.47 in Oct 2026), Dart | Decided (D8) |
| Long-range offline path | ESP32 box per bike: ESP-NOW between boxes, Wi-Fi to the phone | Decided (D15) |
| Short-range fallback | Phone-to-phone Bluetooth LE, only when data is down or slow | Decided (D20), works or not per FT10 |
| Box firmware | ESP-IDF v5.x, C | Decided (D18) |
| Voice audio in and out | Our own `vroo_audio` | Decided 2026-10-24 |
| Box and internet sockets | Our own `vroo_net`. The join can use `wifi_iot` or `plugin_wifi_connect` | Evaluate the join in M1 |
| Bluetooth driver | `ble_plus` (or a fork), else our own `vroo_ble` | Evaluate in M1 |
| Codec | Our own `vroo_opus`, libopus 1.5.2 from source | Decided (D32) |
| Encryption | `cryptography` package (ChaCha20-Poly1305, HKDF) | Decided |
| QR | `flutter_zxing` (built on ZXing) to scan and read from photos, `qr_flutter` to show | Decided. Live scanning fails on iPhone (todo). `mobile_scanner` isn't an option: its Android version relies on Google's proprietary ML Kit (D34) |
| Android background | Foreground service, e.g. `flutter_foreground_task` | Evaluate in M1 |
| Relay server, simulator | Dart, `dart:io` UDP | Decided |

"Evaluate" means: try the package on real phones against the behaviour it must have (section 4). If anything required fails, write our own thin module instead. Every dependency must have a permissive licence, such as MIT, BSD or Apache-2.0, and never a copyleft one such as GPL, so Vroo can be licensed closed as well as open. No proprietary SDKs either (D34). Record each one's licence when it's added.

## 10. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| The Bluetooth fallback fails next to a Bluetooth intercom (another rider app's report) | Riders without a box and without data are cut off | Expected. Spec calls it best effort. FT10 measures it. Works with wired earphones. Boxes are the real offline path |
| Bluetooth fallback degrades the intercom's own audio | Choppy group audio exactly when data is gone | Bluetooth runs only when data is down or slow. If FT10 shows harm, keep it off while an intercom is connected |
| Box range between bikes is shorter than hoped | Offline only works with the group close together | Antenna placement and speed tests (FT1), relaying across boxes, the internet path |
| Airtime runs out at long-range speed | Choppy voice | Voice gate, talker cap N, relay rule, slower chatter in big groups, faster radio speed, packet packing. FT2 and the simulator |
| Very large groups (100) behave differently from 5 | Delays, missed packets, noisy alerts | Simulator (4.10), a ~10-box bench test, scaled timers, alerts off above 10 riders |
| More than N riders start talking at once | Some voices aren't heard | Busy tone tells them; the hard cap in boxes and server keeps the radio clear |
| Phone drops the box's Wi-Fi (no internet), or loses data while on it | That rider falls back to fewer paths | NetDriver keeps both sockets bound, rejoins by itself, and logs it. FT4 |
| Free Apple account can't use Hotspot Configuration | iPhones join the box Wi-Fi in Settings once | Document the step, or use the paid account the group test needs anyway |
| Box damaged by water, vibration or heat | That rider loses the offline path | IP65 case, strain relief, shaded mount (hardware.md). FT9 |
| Box power cut (ignition off at a stop) | That box is gone until the bike restarts | Expected. Spoken box warning. A small USB power bank is optional |
| An Android maker's battery saver kills the app | A rider drops silently | Battery-setting step at onboarding, foreground service, "[Name] dropped off" |
| Google's developer verification for sideloaded Android apps (2026–27) | Test APKs may need a registered developer | Check before M2. Installing over USB keeps working |
| No paid Apple account yet | iPhone test builds must be reinstalled by cable every 7 days | The paid account (a year per install, and TestFlight) before M2 (D22) |
| Boxes break local radio rules | Legal risk | Firmware defaults stay within the module's certified power. hardware.md insists on approved antennas. Boxes made for sale need certification in each market |
| No public relay server | Each group hosts its own for the internet path | A one-command container image and guide. The box path works with no server at all |
