# Spec: Vroo

Status: approved · revised 2026-11-25 (open source, with paid licences for companies: D34) · Read with [architecture.md](architecture.md) (how) and [hardware.md](hardware.md) (the box).

## 1. Summary

A phone app that joins a group of motorcycle riders into one always-on conversation, like a conference call where everyone hears everyone. Each rider uses the intercom or earphones they already pair with their phone.

- **Mobile data:** voices travel over mobile data. When data drops, phones switch on Bluetooth to reach nearby riders.
- **The box:** a small ESP32 box on each bike adds a long-range path that needs no signal. The boxes pass voices from bike to bike, either together with mobile data or on their own.
- **Who can join:** iPhones and Android phones work together in the same group. With boxes there's no fixed limit on group size.
- **Open source, with paid licences:** the app, the box firmware, the box design and the relay server are free and open under copyleft licences: GPL-3.0, AGPL-3.0 for the relay server, and CC BY-SA 4.0 for the docs and box design. Companies can get a paid licence to build Vroo into closed products. The design is also published as prior art (D34).

## 2. The problem

From the founder's own five-rider trips:

- **One-to-one only:** cheap intercoms link one pair at a time. To talk to someone else you disconnect and reconnect.
- **Brand lock-in:** intercoms of different brands often won't pair at all, and some riders have no intercom.
- **Short range:** intercom range is short.
- **Existing apps fall short:** the apps riders use today (the intercom makers' own apps, and push-to-talk apps) need mobile data unless you add hardware, and they turn choppy or drop on weak signal.
- **Bluetooth is taken:** phones struggle to pass voice to each other over Bluetooth while also connected to a Bluetooth intercom. An app already on sale reports this (decisions D3). That's why the box exists, and why Bluetooth is only a fallback here.

## 3. Who it's for

- **v1:** the founder's riding group. About 5 riders, a mix of iPhones and Android phones, mostly budget intercoms of different brands, one box per bike.
- **Later:** riding groups of any size, anywhere, who build it themselves or get it from a company that licenses Vroo (D34). The box stays optional. Riders without one use mobile data, with Bluetooth as a short-range fallback.

## 4. Goals, non-goals and anti-goals

**Goals (v1)**

- **G1** Everyone hears everyone, both ways at once. The mic stays open and nobody presses buttons while riding.
- **G2** Works with any intercom brand through its normal phone connection, and with earphones.
- **G3** With a box on each bike, no internet is needed while the bikes are in box range of each other. Each box passes voices along, so the group can stretch out. With data too, the box and data run together for the longest reach.
- **G4** Mobile data keeps a rider in the conversation when they're out of box range or have no box. When data drops, the phone switches on Bluetooth to reach nearby riders (best effort, see CO3).
- **G5** Any rider, on iPhone or Android, can start a group, and others join with a QR code. No rider is special and riding position doesn't matter.
- **G6** Hands-free after setup: spoken messages in the helmet say what's happening.
- **G7** Phone calls work exactly as they do without the app.
- **G8** Each voice is heard once, never twice, and never your own.
- **G9** The box is optional. The app works on mobile data without one.
- **G10** A rider with a box chooses the mode: box only, or box plus mobile data.
- **G11** With boxes, there's no fixed limit on group size. A group of 100 riders can ride together and anyone can talk, though only a few voices are carried at the same moment (VO7).
- **G12** Free and open source: the app, the box firmware, the box design and the relay server, so any group can build, run and improve it. *(Withdrawn 2026-10-28 by D31, restored 2026-11-25 by D34.)*

**Non-goals (not in v1)**

- **No LoRa voice:** it carries too little data for an open conversation.
- **No phone-to-phone Wi-Fi:** it doesn't work between iPhone and Android. Phone-to-phone Bluetooth is in, as a best-effort fallback (CO3).
- **No boxes for sale in v1:** the group's boxes are built from ready-made boards. Boxes made for sale need radio certification in each market.
- **No box-to-intercom pairing:** a box that pairs straight with the intercom, without the phone, is a later idea.
- **No extra features:** no music sharing, push-to-talk, text chat, maps or location sharing, or recording.
- **No accounts, payments or store listings in v1:** test builds go straight onto the group's phones (PL3).
- **No crowd-talk:** more than a few voices at the very same moment isn't supported (VO7).
- **Phones only:** no tablets, watches, web or desktop.

**Anti-goals: any of these makes it a failure even if it technically works**

- A rider has to touch the phone or the box while riding.
- The box needs fiddling on every ride, instead of once at setup.
- Voices lag enough to make talking awkward, or chop all the time.
- The app quietly dies when the screen is locked.
- Phone calls behave differently: missed calls, intercom auto-answer broken, call audio leaking into the group, or the group leaking into the call.
- Hearing your own voice back, or anyone twice.
- The Bluetooth fallback ruins the intercom's own audio.
- The phone, intercom or box can't last a riding day.

## 5. Success for the first group ride

The founder said success can only be judged after trying it, so these are proposed starting targets to check against, not promises:

- Five riders, each with a box, talk for a whole riding day, and nobody touches their phone after setup except to stop.
- Every intercom in the group works.
- With no signal, the group stays connected while each bike is in box range of the next one.
- A rider who falls out of box range but has signal stays in the conversation.
- Calls ring normally, are answered as usual, and the group comes back on its own afterwards.
- Boxes survive the ride (rain, vibration, heat) and start by themselves with the bike.

## 6. How it works for riders

### 6.1 First launch (once per phone)

1. Type your name. It's what others hear in spoken messages.
2. Allow the microphone and the camera (for scanning the QR).
3. Allow Bluetooth, for the fallback when data drops.
4. On iPhone, allow local network access, for talking to the box.
5. On Android:
   - allow notifications and nearby devices
   - on Android 10 and 11, also allow location and keep it switched on, because those versions need it for Bluetooth and Wi-Fi scanning
   - the app walks you to the setting that stops the phone from closing it to save battery

   Each request explains why it's needed.
6. Pair your intercom or earphones with the phone as you normally would. Nothing app-specific.

### 6.2 Set up your box (once per box)

1. Mount the box and plug it into the bike's USB socket ([hardware.md](hardware.md)). The first time, its software gets loaded from a web page on a computer.
2. In the app, tap **Add my box** and approve joining the box's Wi-Fi.
3. The app gives the box its own Wi-Fi password and remembers it. From then on the phone joins its box by itself, every ride.
4. Pick the mode in settings: **Box + data** (the default) or **Box only**.

### 6.3 Start or join a group (at the meeting point)

- **Start:** tap **Start group**. A QR code appears. The group name is optional (default "[Name]'s ride").
- **Join:** tap **Join**, then scan the QR on any member's phone. The starter can also send the QR as a picture, and the app can read it from the photo.
- **Latecomers:** any member's phone can show the QR, so a latecomer can join from anyone.
- **No internet needed:** joining works offline.
- **Your box follows:** when you join, the app tells your box which group it belongs to.
- **Ride again** (*Claude's call*): the phone remembers the last group, so the same riders can start again next time without rescanning.

### 6.4 Riding

- **Starting:** start the bike, which powers the box. Tap **Start ride**, lock the phone and put it away. The phone joins its box by itself.
- **Talking:** the mic is open, and your phone sends your voice only while you're talking.
- **Listening:** you hear everyone in your helmet. Navigation voice prompts still play (confirmed per nav app in field tests).
- **The ride screen:** shows each rider as connected through the boxes, over the internet, over Bluetooth, or lost. It also shows who's talking and who's on a call.

Which path carries your voice:

| You have | Normally | When data drops or gets slow |
|---|---|---|
| No box | Mobile data | Bluetooth to nearby phones (best effort, short range) |
| A box, mode "Box + data" (default) | Box and mobile data together; the first copy wins | Box, plus Bluetooth to nearby phones that have no box |
| A box, mode "Box only" | Box, plus Bluetooth to nearby phones that have no box | Same |

The switch is automatic. When data recovers, Bluetooth switches off again. With a box and data, a slow data link causes no gap, because the box keeps carrying the voices.

*As built (Plan E, 2026-11-18):* the box and mobile-data paths and both modes work, including riding with no box; the Bluetooth parts of the table come with Plan D.

```
┌──────────────────────────────┐
│ Sunday ride · 5 riders ■ Stop│
│                              │
│ ● Ravi      box         🎙   │
│ ● Meera     box              │
│ ● Arjun     internet         │
│ ● Kabir     Bluetooth        │
│ ● Dev       box         📞   │
│                              │
│ You: talking · box ✓ · data ✓│
│ [ Show group QR ]            │
└──────────────────────────────┘
```

### 6.5 Phone calls

Like a music app: the phone rings with your normal ringtone and you answer the usual way. The group goes silent both ways, and comes back on its own when you hang up. Your box keeps passing the other riders' voices along during your call. See 7.6.

### 6.6 Music

Music pauses, or plays in call quality, while the group is on. This is a phone limitation (the same happens during any app's voice call), so it's documented, not fixed.

### 6.7 Ending

Tap **Stop ride**. The box keeps running while the bike is on, but carries nothing once no phone is sending. Leaving or forgetting the group is in settings.

## 7. Requirements

### 7.1 Group

- **GR1** A group is a shared secret created on the starter's phone, carried in the QR. Creating or joining needs no server and no internet.
- **GR2** No fixed limit on riders per group. Tested with 5 riders on bikes, about 10 boxes on a bench, and 100 in simulation (test plan). Bluetooth links reach only the few phones nearby.
- **GR3** A phone, and its box, are in one group at a time.
- **GR4** Phones and boxes from other groups nearby never carry or hear the group's voices.
- **GR5** Names come from each rider's own phone. Two riders with the same name both work (shown as "Ravi" and "Ravi 2").
- **GR6** A rider can leave a group and forget it.

### 7.2 Voice

- **VO1** Both ways at once, open mic, sending only while the rider talks. Mic sensitivity can be adjusted in settings.
- **VO2** All incoming voices are mixed. Each voice plays once, even when it arrives over several paths or through several boxes.
- **VO3** A rider never hears their own voice.
- **VO4** Voice is compressed (Opus, about 12 to 16 kbps) so slow links don't make it choppy. It uses wideband 16 kHz where the intercom supports it.
- **VO5** Audio goes through the intercom's phone-call connection, or through wired or Bluetooth earphones. The phone's own mic and speaker are a last resort.
- **VO6** The phone's voice processing (echo and noise cancelling) is used where it helps, and idle mics send nothing, so wind noise doesn't add up.
- **VO7** Up to 4 voices are carried at the same moment. The number gets tuned once field tests show what the radio can take. If you start talking while 4 others already are, you hear a short busy tone, and your voice is carried as soon as someone stops. *Claude's call:* large mesh intercoms work this way too, and nobody can follow more than a few people at once.

### 7.3 Connectivity

- **CO1** Data path: every phone sends and receives over mobile data whenever it has signal and the rider's mode allows it.
- **CO2** Box path: the phone sends and receives through its own bike's box over Wi-Fi. The boxes pass voices to each other over long-range radio and relay for bikes further along. No box is special.
- **CO3** Bluetooth path (best effort): when data drops or gets slow, the phone switches on Bluetooth and links to nearby group phones, passing voices along. In "Box only" mode it stays on.
  - **Why it switches off:** Bluetooth competes with the intercom for the phone's Bluetooth radio, so it switches off again once data recovers.
  - **Where it works:** it should work with wired earphones. With a Bluetooth intercom it may not work at all, according to another rider app's report (D3). M1 tests it.
- **CO4** Paths run together: every voice packet goes over every path that's on, and the listener keeps the first copy.
- **CO5** Mode: a rider with a box picks **Box + data** (the default) or **Box only** in settings.
- **CO6** Bridges:
  - A phone with data and a box passes voices between the internet and the boxes.
  - A phone with a box and Bluetooth links passes voices between nearby box-less phones and the boxes.
- **CO7** All switching, reconnecting and rejoining is automatic, with no taps.
- **CO8** A rider reconnects within about 10 seconds of coming back into range.
- **CO9** Everything keeps working with the screen locked and the app in the background, for a full riding day.
- **CO10** A rider without a box is a full member over mobile data, and over Bluetooth when near others.

### 7.4 The box

- **BX1** Powered from the bike's USB, about 1 W or less. It starts by itself when power comes on, and needs no buttons.
- **BX2** Survives rain, vibration and summer heat on a motorbike ([hardware.md](hardware.md)).
- **BX3** Serves its own rider's phone and a pillion's, up to 4 phones.
- **BX4** Passes along only its own group's packets. It can't decrypt voices: it reads only the plain routing header (7.8).
- **BX5** Setup happens once per box, from the app. After that, joining a new group only updates the box's group setting.
- **BX6** A status light shows power, connected to the phone, and other boxes heard.
- **BX7** Its software gets loaded once from a web page. Updates from the app come later (v2).
- **BX8** Works in groups of any size: it relays for any number of other boxes, and its own radio chatter slows down as the group grows, so voice keeps the airtime.

### 7.5 Spoken messages in the helmet

| When | Who hears it | What they hear |
|---|---|---|
| A rider connects for the first time | Everyone else | "[Name] joined" |
| A rider can't be heard on any path for 4 seconds (longer in big groups) | Everyone else | "[Name] dropped off" |
| That rider comes back | Everyone else | Short tone, then "[Name] is back" |
| You can't reach anyone on any path for 4 seconds (once you've heard someone this ride) | You | "You've lost the group. Move closer to the others." Repeats every 60 seconds while you're alone |
| Your phone loses its box for 10 seconds (if you've set one up) | You | "Your box is disconnected" |
| You hear nobody because your phone's clock and the others' are more than 10 minutes apart | You | "The phone clocks are too far apart to hear each other. Check the date and time are set to automatic." Once a ride. *Claude's call.* |
| A rider's phone call starts or ends | Everyone else | "[Name] is on a call" / "[Name] is off the call" |
| You start talking while 4 others already are | You | Short busy tone |

- **Quiet changes:** some changes don't affect the conversation, so they play no message. That covers losing data while the box or Bluetooth still connects you, Bluetooth switching on or off, and losing the box while data still connects you (apart from the box warning).
- **Your calls:** no message plays during your own phone call.
- **Big groups:** in groups of more than 10, the per-rider "joined", "dropped off", "is back" and call messages are off, because there'd be too many to be useful. The ride screen shows the counts instead. Your own messages still play. *Claude's call.*
- **Language:** v1 messages are in English.

### 7.6 Phone calls

- **PC1** Incoming calls ring with the normal ringtone and are answered the usual way: intercom button, intercom auto-answer or the screen.
- **PC2** From the first ring until hang-up, the group can't hear the rider or the caller, and the rider and caller can't hear the group.
- **PC3** After hang-up or decline, the rider is back in the group on their own within 2 seconds.
- **PC4** Outgoing calls behave the same way.
- **PC5** The rider's box keeps relaying other riders' voices during the call, because it doesn't depend on the phone.
- **PC6** The app does not register the group as a phone call. That is what keeps PC1 true (see decisions D7).

### 7.7 Other audio

- **OA1** Navigation prompts play alongside the group where the phone allows it. Each nav app gets checked in field tests (some navigation apps have a "play voice during calls" setting).
- **OA2** Music pauses or drops to call quality while the group is on (see 6.6).

### 7.8 Privacy and security

- **PS1** Voice is encrypted end to end with the group secret. Boxes, Bluetooth relays and the internet relay can't listen.
- **PS2** Nothing is recorded or stored, there are no accounts, and v1 has no analytics.
- **PS3** Location is never shared, except in diagnostics mode for field tests, and then only within the group.
- **PS4** Anyone with the group's QR can join, so the app tells the starter to share it only with the riders.
- **PS5** Each box's Wi-Fi has its own password, set by its owner's app.

### 7.9 Diagnostics (field tests)

- **DG1** A diagnostics switch adds on-screen stats and a ride log the rider can share afterwards. The log covers paths, box neighbours and signal, Bluetooth links, distances, lost packets, delay, battery and calls.
- **DG2** A "pretend extra talkers" switch that loads the links as if more people were talking.
- **DG3** Off by default in release builds.

### 7.10 Platforms and distribution

- **PL1** iPhone on iOS 17 or later, and Android 10 or later. Both minimums get checked against the group's actual phones.
- **PL2** One Flutter codebase, with thin native modules for intercom audio, network sockets and Bluetooth (see [architecture](architecture.md)). The box runs its own small program in C.
- **PL3** Distribution for the group test, with no app stores. Store listings are decided later (D34):
  - **Android:** an APK, installed directly. Google's developer-verification rules for sideloaded apps, rolling out in 2026–27, may require registering as a developer.
  - **iPhone:** cable installs from the founder's Mac (D22). A free Apple ID means reinstalling every 7 days. A paid developer account ($99 a year) lasts a year and allows TestFlight.

## 8. Targets (v1, confirmed or adjusted by field tests)

| Area | Target |
|---|---|
| Delay, mouth to ear, through two boxes | 250 ms or less, not counting the intercom's own Bluetooth delay |
| Delay, worst case (up to 8 box hops, or internet) | 400 ms or less (the ITU-T G.114 planning limit). Longer chains add delay |
| Lost packets before it sounds bad | 5% or less, with Opus repair |
| Voices carried at the same moment | 4 (tunable) |
| Group size | No fixed limit. Tested with 5 bikes, about 10 boxes on a bench, and 100 in simulation |
| Mobile data | About 15 MB an hour or less in normal use |
| Reconnect after regrouping | 10 seconds or less |
| Background | A full 8-hour ride with the screen locked and no app death |
| Phone battery | Measured in field tests. Target: 4 hours or more without bike power |
| Box power | About 1 W or less, from the bike's USB |
| Box-to-box reach per hop | Measured in field tests. Espressif says its long-range mode reaches up to about 1 km in open space, so expect a few hundred metres between moving bikes |
| Bluetooth reach (fallback) | Tens of metres at best. Measured in field tests |

## 9. Releases

- **M1, feasibility:** the box software, the audio, network and Bluetooth modules, a minimal screen and diagnostics. Built and tested on 2 to 3 phones, boxes and bikes, plus a simulation of large groups. Field tests answer the unknowns in section 10 and decide whether the design goes ahead as planned.
- **v1, group release:** everything in this spec, for the founder's group of five, with a box on each bike.
- **v2, public release (D34):**
  - a demo from a real group ride, with the field-test numbers
  - builds anyone can try: a signed Android APK, and TestFlight on iPhone
  - box firmware binaries and a flashing page, and a relay server that's easy to deploy
  - onboarding polish, and box updates from the app

## 10. Known unknowns (answered in M1)

- **U1** How far do two boxes reach between moving bikes, for each antenna placement and radio speed?
- **U2** How many talkers can the boxes carry at long-range speed once voices get passed along several bikes? This sets the VO7 number.
- **U3** Does each phone stay on its box's Wi-Fi and keep using mobile data at the same time, on both iPhone and Android, with the screen locked? The box's Wi-Fi has no internet. **Partly answered 2026-10-27, screen on:** yes on iPhone. The desk Android has no SIM, so its mobile data is untested. Screen locked: still open.
- **U4** How does each intercom brand's button and auto-answer behave while the group is running?
- **U5** Do navigation prompts play during the group, per nav app?
- **U6** Do Android phone makers' battery savers kill the app on long rides?
- **U7** How long does each intercom's battery last when it stays in call mode all day? Its talk-time rating is the limit, not its standby time.
- **U8** Do the boxes survive rain, vibration and heat? Where should the antenna go?
- **U9** Does joining a box's Wi-Fi from the app need anything an Apple free account doesn't allow (the Hotspot Configuration entitlement)? **Answered 2026-10-27: yes.** On a free account, iPhones join the box's Wi-Fi in Settings (D22).
- **U10** Does the Bluetooth fallback work at all next to a Bluetooth intercom, and does it hurt the intercom's audio? Another rider app says it doesn't work. With wired earphones it should.
- **U11** How does the box mesh behave with dozens of boxes? That covers airtime used by the boxes' own chatter, how far voices travel down a long convoy, and the delay across many hops. Answered by simulation first, then with about 10 boards on a bench.

Settled since the first draft: phone-to-phone Bluetooth is no longer the main offline path, because another rider app reports it fails next to a Bluetooth intercom. The box took over that job, and Bluetooth stays as a best-effort fallback (decisions D15, D20).

## 11. Glossary

- **Box:** the small ESP32 device on each bike. It's a Wi-Fi hotspot for its rider's phone and a long-range radio to the other boxes.
- **ESP-NOW:** the ESP32's direct radio messaging between boxes. **Long-range mode** is Espressif's slower but further-reaching setting for it.
- **Intercom call connection (HFP):** the Bluetooth link an intercom uses for phone calls. It carries mic and speaker at call quality.
- **Mode:** for riders with a box, "Box + data" or "Box only".
- **Hop:** one box-to-box link, or one phone-to-phone Bluetooth link, that a voice crosses.
- **Relay:** a box or phone passing other riders' voices along.
- **Bridge:** a phone passing voices between mobile data, the boxes and Bluetooth.
- **Path:** the box, the internet, or Bluetooth.
- **Busy tone:** what you hear if you start talking while the maximum number of voices is already being carried.
