# Plan B: Voice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two riders talk to each other hands-free through their intercoms or earphones: one on the desk iPhone, one on the desk Android phone, both on one box. The mic is open, a voice gate keeps silence off the air, talk slots and spoken alerts work, phone calls behave as usual, and the ride keeps going with the screen locked.

**Architecture:**
- **`vroo_opus`** is a pure-Dart FFI package. A Dart build hook compiles the official libopus 1.5.2 source, so the codec runs on both phones and in `dart test` on the Mac.
- **`vroo_audio`** is a thin Flutter plugin. It opens a call-style audio session on the intercom's call link and moves 20 ms frames in and out. It reports calls, interruptions and route changes, turns text into speech, and keeps the app alive: background audio on iOS, a foreground service on Android.
- **The app's voice logic is pure Dart and unit-tested:** voice gate, jitter buffer, mixer, tones, talk slots and alerts. `VoicePipeline` paces playback from the mic frames, one frame out for each frame in. `RideEngine` wires together the box link, the pipeline, audio and alerts, and handles calls.
- **BoxLink** gains VOICE packets and the heartbeat's talking and on-call flags.

**Tech Stack:**
- Flutter 3.47 and Dart. The new Dart packages are `ffi`, `hooks`, `code_assets` and `native_toolchain_c`, all BSD-3 from the Dart team.
- libopus 1.5.2 (BSD-3), vendored from the official release.
- Swift: AVFoundation, plus CallKit's `CXCallObserver`, used only to observe calls.
- Kotlin: `android.media` and `TextToSpeech`.

**Spec:** [docs/spec.md](../../spec.md) §6.4–6.6, §7.2, §7.5–7.7 and §8, and [docs/architecture.md](../../architecture.md) §4.1, §4.2, §4.5, §4.7, §5.3, §5.4, §6.2, §6.3, §6.6, §7 and §8. Decisions D5, D7 and D31 are in docs/decisions.md.

**Where this sits:** M1, Plan B ([docs/todo.md](../../todo.md)), on top of Plan A's box link. Not in this plan:

- the internet voice path, the relay server and the path policy (M2); Bluetooth (Plan D); box-to-box radio (Plan C)
- GPS distance and "pretend extra talkers" (Plan C, for FT1 and FT2)
- Plan A's follow-ups: Android rejoining without the prompt, live QR scanning on the iPhone, and the iPhone's first run after the Local Network grant. They stay in todo M1.

## Global Constraints

- **Plan A's constraints still apply**, apart from its open-source block, which D31 replaced. They cover:
  - the platforms, and keeping native code thin
  - protocol v1, the box and the invite
  - the ride-log format
  - no paid Apple account
  - the founder's 👤 checklists
  - no personal data in the repository
- **Audio frames:** 20 ms, 16 kHz, mono, signed 16-bit: 320 samples a frame. Both platforms are little-endian.
- **Opus:** 16 kHz, mono, 20 ms frames, 16 kbps VBR, the VOIP application, and in-band FEC on, with the expected loss set to 10%. *Claude's call:* the encoder adds FEC data only when it's told to expect loss.
- **VOICE payload:** frameNo (u32), then one Opus frame. frameNo counts every 20 ms mic frame since the ride started, sent or not, so a gap inside a talk spurt is a loss.
- **Voice gate:** frame energy against an adaptive noise floor plus a threshold, with a 300 ms hang and a 40 ms pre-roll. The threshold defaults to 12 dB. The ride screen sets it from 6 to 24 dB (VO1).
- **Talk slots:**
  - N = 4.
  - Another rider counts as active if their voice arrived in the last 500 ms.
  - While N others are active, a rider who isn't already talking doesn't send.
  - Held frames are dropped, not queued.
  - The busy tone plays at most once every 5 s.
- **Jitter buffer:**
  - One per sender. Playback starts once 60 ms is buffered.
  - It never holds more than 300 ms; past that it skips ahead.
  - A missing frame is rebuilt from the next frame's FEC when that frame is there. Otherwise it's concealed.
- **Mixer:** up to N voices plus alerts, summed with a soft clip.
- **Calls (D7):**
  - From the first ring until hang-up, nothing goes either way.
  - The rider is back within 2 s of hanging up (PC3).
  - There's no CallKit provider and no Telecom. iOS uses `CXCallObserver` only to observe calls.
- **iOS audio:**
  - Session `.playAndRecord`, mode `.voiceChat`, options `.allowBluetoothHFP` and `.mixWithOthers`.
  - Voice processing on, with other audio ducked at the minimum level.
  - A preferred IO buffer of 20 ms, and background mode `audio`.
- **Android audio:**
  - `MODE_IN_COMMUNICATION`.
  - SCO routing with `setCommunicationDevice` on API 31+, or `startBluetoothSco` on API 29–30.
  - `AudioRecord(VOICE_COMMUNICATION)` and `AudioTrack(USAGE_VOICE_COMMUNICATION)`, both at 16 kHz.
  - Audio focus GAIN.
  - A foreground service of types `microphone|connectedDevice`, running for the whole ride.
- **No headset or intercom:** both platforms fall back to the loudspeaker, the last resort in VO5.
- **Spoken messages:**
  - The exact English texts from spec 7.5.
  - None play during the rider's own call. The per-rider ones are off above 10 riders.
  - *Claude's call:* an Indian English voice (`en-IN`), or the phone's default English voice if it has none.
- **Log kinds:** `audio`, `call`, `slot` and `stats` (architecture §8), in Plan A's line format.
- **Closed source (D31):**
  - Every new Vroo source file starts with the comment `Proprietary and confidential. See LICENSE.` Vendored libopus files stay unchanged, with their own notices.
  - Dependencies are permissive only, and each one's licence is recorded. No dependencies beyond those named here without a note in decisions.md.
  - Packages keep `publish_to: none`.
  - The libopus notice appears on the app's licence page.
- **Commits:** the founder commits, in GitHub Desktop. Each task ends with a "Hand over" step that lists the changed files and a suggested commit message. The executor never commits.

## Review Focus

1. **The intercom disconnects or comes back mid-ride.** Audio moves to the next route without stopping the ride. It returns to the intercom when that's back, and the log records `audio route=…`. Tests: Task 9 "a route change keeps the ride going, and is logged"; the Task 6 and 7 device checks switch the intercom off and on.
2. **A call comes in while the rider, or someone else, is talking.** This includes a declined call. From the first ring until hang-up nothing goes either way. The others hear "[Name] is on a call", and the rider is back within 2 s of hanging up. Tests: the Task 9 call tests (ringing, declined, idle); the Task 7 device check; the Task 11 bench.
3. **Wi-Fi loses, reorders or repeats voice packets, in bursts.** Voice carries on through FEC and concealment. Nothing throws, and the delay never grows past 300 ms. Tests: the Task 3 jitter-buffer tests; Task 9 "each frame plays once when the box delivers it twice".
4. **The phone stays locked, or the app is swiped away, for a long time.** Mic and playback keep running: on Android through the foreground service, on iOS through the audio session. Tests: the Task 6 and 7 device checks (2 minutes locked); the Task 11 bench (10 minutes locked, and an Android swipe). The 2-hour soak is FT4, in Plan C.
5. **The mic is denied, the speech engine fails, or nothing is plugged in.** The ride screen says what to do, and the ride never hangs silently. A failed spoken message is logged and skipped. With no headset, the screen shows "Loudspeaker". Tests: Task 9 "mic denied stops the start" and "a failed speech engine doesn't stop the ride"; Task 10 "mic denied shows how to fix it".

---

## File structure

```
packages/vroo_opus/                  pure Dart FFI package, no Flutter
  hook/build.dart                    compiles libopus and the shim with native_toolchain_c
  third_party/opus/                  libopus 1.5.2: include/ src/ celt/ silk/, the *_sources.mk files, COPYING, AUTHORS
  src/vroo_opus.c                    C shim, so Dart needn't call varargs functions
  lib/vroo_opus.dart                 OpusEncoder, OpusDecoder, OpusException, libopusLicense
  lib/src/bindings.dart              @Native bindings
  lib/src/libopus_license.dart       the COPYING text as a constant
  test/opus_test.dart
packages/vroo_audio/                 Flutter plugin (android + ios)
  lib/vroo_audio.dart                API, events, createVrooAudio(), and the FakeVrooAudio export
  lib/src/fake_vroo_audio.dart       test double
  lib/src/channel_vroo_audio.dart    platform implementation over the channels
  lib/src/resample.dart              linear resampling to 16 kHz
  android/src/main/kotlin/com/getvroo/vroo_audio/VrooAudioPlugin.kt, RideService.kt, Wav.kt
  ios/vroo_audio/Sources/vroo_audio/VrooAudioPlugin.swift
  example/                           "audio check" screen
app/
  lib/voice/voice_gate.dart mixer.dart tones.dart jitter_buffer.dart talk_slots.dart voice_pipeline.dart
  lib/ride/alerts.dart ride_engine.dart
  lib/net/box_link.dart peer.dart    voice, heartbeat flags, display names
  lib/ui/ride_screen.dart            replaces test_screen.dart
  android/app/src/main/kotlin/com/getvroo/vroo/VrooApplication.kt, MainActivity.kt
  test/voice/…  test/ride/…  test/fake_codec.dart
```

---

### Task 1: vroo_opus: libopus from source, with a build hook

**Files:**
- Create: `packages/vroo_opus/`, with:
  - `pubspec.yaml` (`publish_to: none`) and `analysis_options.yaml`
  - `hook/build.dart` and `src/vroo_opus.c`
  - `lib/vroo_opus.dart`, `lib/src/bindings.dart` and `lib/src/libopus_license.dart`
  - `test/opus_test.dart`
  - `third_party/opus/`
- Modify:
  - `app/pubspec.yaml`: `vroo_opus` by path
  - `docs/architecture.md`: §4.7, and the §9 Codec row
  - `docs/decisions.md`: a new D32
  - `docs/development.md`: the test command

**Interfaces:**
- Produces:
  ```dart
  class OpusEncoder {
    OpusEncoder({int sampleRate = 16000, int bitrate = 16000, int expectedLossPercent = 10});
    /// One 20 ms frame (sampleRate ~/ 50 samples) to one Opus packet. ArgumentError for any other length,
    /// StateError after close, OpusException if libopus fails.
    Uint8List encode(Int16List frame);
    void close(); // safe to call twice
  }
  class OpusDecoder {
    OpusDecoder({int sampleRate = 16000});
    /// Always sampleRate ~/ 50 samples. A null packet conceals one lost frame. With fec, it rebuilds the frame
    /// before [packet] from the FEC data inside [packet].
    Int16List decode(Uint8List? packet, {bool fec = false});
    void close();
  }
  class OpusException implements Exception { final int code; final String message; }
  const String libopusLicense; // the vendored COPYING text
  ```
- **C shim (`src/vroo_opus.c`).** It exists because Dart FFI can't call the variadic `opus_*_ctl` functions.
  - **Functions** (all integers are `int32_t`):
    - `vroo_opus_encoder_new(rate, bitrate, loss_percent, *error)` and `vroo_opus_encoder_free`
    - `vroo_opus_encode(enc, pcm, samples, out, max_bytes)`
    - `vroo_opus_decoder_new(rate, *error)` and `vroo_opus_decoder_free`
    - `vroo_opus_decode(dec, data, len, pcm, samples, fec)`
    - `vroo_opus_strerror(code)`
  - **Encoder settings:** `OPUS_APPLICATION_VOIP`, `OPUS_SET_BITRATE`, `OPUS_SET_VBR(1)`, `OPUS_SET_INBAND_FEC(1)`, `OPUS_SET_PACKET_LOSS_PERC(loss_percent)` and `OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE)`.

- [ ] **Step 1: Vendor libopus 1.5.2**

1. Download `opus-1.5.2.tar.gz` and its published SHA-256 list from https://downloads.xiph.org/releases/opus/ into a new empty folder in the scratchpad.
2. Check the checksum. Stop if it doesn't match.
3. Extract the archive there.
4. Copy only these into `third_party/opus/`: `include/`, `src/`, `celt/`, `silk/`, `celt_sources.mk`, `silk_sources.mk`, `opus_sources.mk`, `COPYING` and `AUTHORS`. Leave out `dnn/`, `doc/`, `tests/` and the build scripts.
5. Write `lib/src/libopus_license.dart` as `const libopusLicense = r'''<COPYING text>''';`.

Expected: the checksum matches, and `COPYING` is libopus's BSD licence text.

- [ ] **Step 2: Write the failing tests**

In `test/opus_test.dart`, with small helpers `sine(hz, samples, dbfs)` and `rmsDb(frame)` in the test file:

```dart
test('a 20 ms frame of voice-band sound becomes a small packet', ...);
  // 50 frames of 440 Hz at -12 dBFS peak. Every packet is 1..120 bytes; frames 10..49 average 20..70 bytes.
test('decoded audio is about as loud as the input', ...);
  // The same 50 frames, decoded. Frames 5..49 are within 3 dB of the input's RMS (-15 dBFS).
test('silence stays quiet', ...);            // 50 zero frames decode to below -60 dBFS
test('a lost frame is concealed with a full frame', ...);   // decode(null).length == 320
test('FEC rebuilds a lost frame from the next packet', ...);
  // Decode packets 0..29, skip 30, then decode(p[31], fec: true): 320 samples, within 6 dB of the input's RMS.
  // Then decode(p[31]) as usual.
test('frames of the wrong length are refused', ...);   // encode(Int16List(319)) throws ArgumentError
test('a closed encoder refuses to encode', ...);       // close(), then encode throws StateError
test('the libopus licence is included', ...);
  // libopusLicense contains 'Xiph.Org' and 'Redistribution and use in source and binary forms'
```

- [ ] **Step 3: Run them and watch them fail**

Run: `cd packages/vroo_opus && dart pub get && dart test`
Expected: FAIL. Compile errors, because `OpusEncoder` isn't defined.

- [ ] **Step 4: Implement the hook, the shim and the bindings**

- **`hook/build.dart`:** one `CBuilder.library(name: 'vroo_opus', assetName: 'src/bindings.dart', …)`.
  - **Sources:** the shim, plus the files listed under `CELT_SOURCES`, `SILK_SOURCES`, `SILK_SOURCES_FLOAT`, `OPUS_SOURCES` and `OPUS_SOURCES_FLOAT` in the vendored `.mk` files. The hook reads those lists at build time: it joins the backslash-continued lines and splits on whitespace.
  - **Include folders:** `third_party/opus/include`, `celt`, `silk` and `silk/float`.
  - **Defines:** `OPUS_BUILD`, `USE_ALLOCA`, `HAVE_LRINTF` and `HAVE_LRINT`.
  - **Optimisation:** O2.
- **`lib/src/bindings.dart`:** `@DefaultAsset('package:vroo_opus/src/bindings.dart')`, and one `@Native` per shim function.
- **Buffers:** each encoder and decoder keeps its native input and output buffers (allocated with `package:ffi`'s `malloc`) for its whole life, and frees them in `close`.

- [ ] **Step 5: Run the tests and watch them pass**

Run: `dart test && dart analyze`
Expected: all 8 tests pass, and analyze reports "No issues found!"

- [ ] **Step 6: Check that it builds for both phones**

Add `vroo_opus` to `app/pubspec.yaml` by path.

1. Run: `cd app && flutter build apk --debug && unzip -l build/app/outputs/flutter-apk/app-debug.apk | grep libvroo_opus`
   Expected: `lib/arm64-v8a/libvroo_opus.so`, plus the other ABIs.
2. Run: `flutter build ios --debug --no-codesign && find build/ios -name 'vroo_opus*'`
   Expected: `Built build/ios/iphoneos/Runner.app`, and the `vroo_opus` framework is listed.

If the hook can't build for a phone, keep the same Dart API and switch to an FFI plugin: CMake on Android, a podspec on iOS. Ledger that as a ruling.

- [ ] **Step 7: Record the choice**

- **architecture §4.7:** "Our own `vroo_opus`: libopus 1.5.2 from the official source, compiled by a Dart build hook. No prebuilt binaries. `flutter_opus` and `opus_dart` were checked and skipped (D32)."
- **architecture §9, Codec row:** "Our own `vroo_opus`, libopus 1.5.2 from source | Decided (D32)".
- **decisions.md:** an index row and a section for **D32, Opus from source in our own package**, marked Claude's call, 2026-10-28.
  - **Why:**
    - `flutter_opus` has no Android support yet. It needs the app to supply libopus binaries, and its API has no FEC.
    - `opus_dart` with `opus_flutter` hasn't had a release in two years. Its prebuilt binaries come from an unverified publisher: a supply-chain and due-diligence risk for a closed product (D31).
    - Built from source, the codec runs in `dart test` too.
  - **Cost:**
    - Updating libopus means copying in a new release and rerunning the tests.
    - The first build compiles libopus, which takes about a minute.
- **development.md, Tests table:** `| Opus codec | cd packages/vroo_opus && dart test (the first run compiles libopus) |`.

- [ ] **Step 8: Hand over**

List the changed files. Suggested message: `feat(opus): libopus 1.5.2 from source with a build hook`.

---

### Task 2: Voice gate, mixer and tones

**Files:**
- Create: `app/lib/voice/voice_gate.dart`, `mixer.dart` and `tones.dart`
- Test: `app/test/voice/voice_gate_test.dart`, `mixer_test.dart` and `tones_test.dart`

**Interfaces:**
- Produces:
  ```dart
  double frameDb(Int16List frame); // RMS level in dBFS, floored at -90
  class VoiceGate {
    VoiceGate({double thresholdDb = 12, int hangFrames = 15, int preRollFrames = 2, double minDb = -55,
        double floorRiseDbPerFrame = 0.1});
    double thresholdDb; // the ride screen's mic sensitivity
    bool get open;
    /// The frames to send now: none while closed; the pre-roll frames and then this one when it opens;
    /// then one at a time until the hang runs out.
    List<Int16List> push(Int16List frame);
  }
  Int16List mix(List<Int16List> frames); // inputs are 320 samples; no inputs gives 320 zeros
  Int16List busyTone(); // 425 Hz, 150 ms on, 100 ms off, 150 ms on, -12 dBFS, 5 ms fades: 6400 samples
  Int16List backTone(); // 880 Hz, 120 ms, -12 dBFS, 5 ms fades: 1920 samples
  ```
- **The gate rule.** The tests depend on it.
  - **Floor:** the first frame only sets the floor. After that, each frame is judged against the floor as it stood before that frame, and then the floor updates. It falls straight to any quieter frame, and rises by at most `floorRiseDbPerFrame` per frame (5 dB/s).
  - **Loud:** a frame is loud when `db >= minDb` and `db > floor + thresholdDb`.
  - **Opening:** a loud frame opens the gate and resets the hang to `hangFrames`.
  - **Closing:** each quiet frame while open uses up one hang frame and is still sent. When the hang is used up, the gate closes.
  - **Pre-roll:** while closed, the gate keeps the last `preRollFrames` frames.
- **Mixer:** sum the inputs, scaled so full scale is 1.0. Values up to 0.6 pass unchanged. Above that, `y = sign(x) × (0.6 + 0.4 × tanh((|x| − 0.6) ÷ 0.4))`. Round back to int16.

- [ ] **Step 1: Write the failing tests**

```dart
// voice_gate_test.dart. Frames are built at a given dBFS with a small helper.
test('silence and quiet noise send nothing', ...);    // 250 frames at -90, then 250 at -60: never any frames
test('speech opens the gate with 40 ms of pre-roll', ...);
  // 50 frames at -60, then one at -20: push returns the 2 previous frames (the same objects), then the loud one
test('the gate stays open 300 ms after speech, then closes', ...);
  // 50 at -60, 10 at -20, 20 at -60: 2 + 10 + 15 frames sent; the 16th quiet frame and later send nothing
test('a steady loud noise closes the gate within 6 s', ...);    // 50 at -60, then -25 constant: closed before frame 300
test('a 6 dB threshold opens on soft speech that 24 dB ignores', ...);   // floor -60, speech -45
// mixer_test.dart
test('one quiet voice passes through unchanged', ...);   // a -20 dBFS sine comes out sample for sample
test('two loud voices never wrap around', ...);
  // two in-phase sines at 0.9 of full scale: every sample keeps the sum's sign and stays within int16
test('no voices is silence', ...);                       // mix([]) == 320 zeros
// tones_test.dart
test('the busy tone is two 150 ms beeps at -12 dBFS', ...);
  // 6400 samples; peak 0.24..0.26 of full scale; samples 2400..3999 are zero
test('the back tone is 120 ms', ...);                    // 1920 samples, same peak
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd app && flutter test test/voice`
Expected: FAIL. Compile errors, because `VoiceGate`, `mix` and `busyTone` aren't defined.

- [ ] **Step 3: Implement `voice_gate.dart`, `mixer.dart` and `tones.dart`**

- [ ] **Step 4: Run the tests and watch them pass**

Run: `flutter test test/voice && flutter analyze`
Expected: all pass, and analyze reports no issues.

- [ ] **Step 5: Hand over**

Suggested message: `feat(voice): voice gate, mixer and tones`.

---

### Task 3: Jitter buffer

**Files:**
- Create: `app/lib/voice/jitter_buffer.dart`
- Test: `app/test/voice/jitter_buffer_test.dart`

**Interfaces:**
- Produces:
  ```dart
  sealed class Playout {}
  final class PlayFrame extends Playout { PlayFrame(this.opus); final Uint8List opus; }
  /// Decode nextOpus with fec: true, to rebuild the missing frame before it.
  final class RecoverFrame extends Playout { RecoverFrame(this.nextOpus); final Uint8List nextOpus; }
  final class ConcealFrame extends Playout {}
  class JitterBuffer {
    JitterBuffer({int startFrames = 3, int maxFrames = 15, int tailConcealFrames = 2});
    void put(int frameNo, Uint8List opus);
    Playout? next(); // once every 20 ms; null means this sender is quiet
    int get depth;   // frames held
    int played = 0, recovered = 0, concealed = 0, late = 0, skipped = 0;
  }
  ```
- **Behaviour:**
  - **Starting:** it stays quiet until `startFrames` frames are held, then plays from the lowest one held.
  - **Each `next()`:**
    1. If the frame due is held, it returns `PlayFrame`.
    2. If the frame after it is held, it returns `RecoverFrame` with that next frame's data.
    3. If any other frame is held, it returns `ConcealFrame`.
    4. If nothing is held, it returns up to `tailConcealFrames` `ConcealFrame`s, then goes quiet and starts over.
  - **Late frames:** a frame at or below the last one played or concealed is late, even after going quiet. It counts in `late` and is dropped.
  - **Duplicates:** a frame number already held is ignored.
  - **Too much buffered:** when the frames held span more than `maxFrames` (from the frame due, or the oldest held while quiet, to the newest), it drops the oldest until `startFrames` remain. Each dropped frame counts in `skipped`.

- [ ] **Step 1: Write the failing tests**

```dart
test('waits for 60 ms before playing', ...);          // put 0, 1: next() is null; put 2: next() is PlayFrame(0)
test('plays frames in order when they arrive out of order', ...);   // put 2, 0, 1, 3: plays 0, 1, 2, 3
test("rebuilds one lost frame from the next frame's FEC", ...);
  // put 0, 1, 2, 4, 5: PlayFrame 0, 1, 2, then RecoverFrame(4), PlayFrame(4), PlayFrame(5)
test('conceals a burst loss', ...);
  // put 0, 1, 2, 5, 6: PlayFrame 0, 1, 2, ConcealFrame, RecoverFrame(5), PlayFrame(5), PlayFrame(6)
test('goes quiet after the talker stops', ...);       // put 0..2: 3 plays, 2 conceals, then null; depth 0
test('a late frame is dropped', ...);                 // after playing 0..2, put 1: late == 1, it never plays
test('never holds more than 300 ms', ...);
  // put 0..19 while quiet: first next() is PlayFrame(13), skipped == 13, and depth never exceeds 15
test('counts what it did', ...);                      // played, recovered and concealed match the sequence above
```

- [ ] **Step 2: Run them and watch them fail**

Run: `flutter test test/voice/jitter_buffer_test.dart`
Expected: FAIL, because `JitterBuffer` isn't defined.

- [ ] **Step 3: Implement `jitter_buffer.dart`**

- [ ] **Step 4: Run the tests and watch them pass**

Run: `flutter test test/voice`
Expected: all pass.

- [ ] **Step 5: Hand over**

Suggested message: `feat(voice): jitter buffer with FEC and concealment`.

---

### Task 4: Talk slots, spoken alerts and display names

**Files:**
- Create: `app/lib/voice/talk_slots.dart` and `app/lib/ride/alerts.dart`
- Modify:
  - `app/lib/net/peer.dart`: `displayNames`, and the `talking` and `onCall` fields
  - `docs/spec.md` §7.5: the "lost the group" row
- Test: `app/test/voice/talk_slots_test.dart`, `app/test/ride/alerts_test.dart` and `app/test/ride/names_test.dart`

**Interfaces:**
- Consumes: `PeerInfo` from Plan A. This task adds `bool talking = false, onCall = false` to it.
- Produces:
  ```dart
  enum SlotDecision { send, hold, holdWithBusyTone }
  class TalkSlots {
    TalkSlots({int n = 4, int activeMs = 500, int busyEveryMs = 5000});
    void heard(int src, int nowMs);   // another rider's voice frame arrived
    SlotDecision decide(int nowMs);   // for each frame the gate wants to send
  }
  sealed class Alert {}
  final class Say extends Alert { Say(this.text); final String text; }
  final class BackTone extends Alert {}
  class Alerts {
    /// Called once a second. [peers] are on the same clock as [nowMs]; [names] come from displayNames.
    List<Alert> update({required Map<int, PeerInfo> peers, required Map<int, String> names, required bool boxUp,
        required bool myCall, required int nowMs});
  }
  /// Riders who share a name, mine included, are told apart by rider ID order: "Ravi", "Ravi 2"…
  /// An empty name becomes "Rider".
  Map<int, String> displayNames(Map<int, PeerInfo> peers, {required int myId, required String myName});
  ```
- **Talk-slot rules:**
  - If this phone sent within `activeMs`, it sends.
  - Otherwise, if `n` or more others were heard within `activeMs`, it holds. The decision is `holdWithBusyTone` if no busy tone played in the last `busyEveryMs`.
  - Otherwise it sends.
  - A send records this phone's last send time.
- **Alert rules.** The texts are exactly those in spec 7.5.
  - **Joined:** a rider seen for the first time this ride → "[Name] joined".
  - **Dropped off:** a rider not heard for more than 4,000 ms → "[Name] dropped off", once.
  - **Back:** a rider who dropped off and is heard again → `BackTone`, then "[Name] is back".
  - **Calls:** a rider's `onCall` flag turning on → "[Name] is on a call"; turning off → "[Name] is off the call".
  - **Lost the group:** once at least one rider has been heard this ride, and nobody has been heard for 4,000 ms → "You've lost the group. Move closer to the others." It repeats every 60 s while that lasts.
  - **Box:** the box down for 10 s → "Your box is disconnected", once per outage.
  - **During my call:** nothing is returned. The state still updates, so nothing replays afterwards.
  - **Big groups:** with more than 10 riders, me included, the per-rider messages (joined, dropped off, back, calls) aren't returned. My own messages still are.
  - *Claude's call:* "lost the group" only after someone was heard, so the first rider to start isn't told they're lost. Add "(once you've heard someone this ride)" to that row in spec 7.5.

- [ ] **Step 1: Write the failing tests**

```dart
// talk_slots_test.dart
test('sends while fewer than 4 others are talking', ...);
test('a fifth talker is held and hears one busy tone every 5 s', ...);
  // 4 others heard every 20 ms; decide every 20 ms for 6 s: holdWithBusyTone at 0 s and at 5 s, hold otherwise
test('the held talker is carried once a slot has been free for 500 ms', ...);
test('a rider already talking keeps the slot when others start', ...);
// alerts_test.dart (names via displayNames; time moves in 1 s steps)
test('a new rider is announced once', ...);            // ["Meera joined"]
test('a rider silent for 4 s dropped off, and is back with a tone', ...);
  // ["Meera dropped off"], then ['<tone>', "Meera is back"]
test('alone for 4 s after riding together: move closer, every 60 s', ...);
test('alone at the start says nothing', ...);
test('the box down for 10 s is said once', ...);       // ["Your box is disconnected"]
test('call flag changes are announced', ...);          // "Dev is on a call", then "Dev is off the call"
test('nothing is said during my own call', ...);
test('above 10 riders only my own messages play', ...);
// names_test.dart
test('two riders with the same name are "Ravi" and "Ravi 2"', ...);
test('my own name counts, and an empty name is "Rider"', ...);
```

- [ ] **Step 2: Run them and watch them fail**

Run: `flutter test test/voice/talk_slots_test.dart test/ride`
Expected: FAIL, because `TalkSlots`, `Alerts` and `displayNames` aren't defined.

- [ ] **Step 3: Implement `talk_slots.dart`, `alerts.dart` and `displayNames`, and edit spec 7.5**

- [ ] **Step 4: Run the tests and watch them pass**

Run: `flutter test`
Expected: all pass, Plan A's included.

- [ ] **Step 5: Hand over**

Suggested message: `feat(ride): talk slots, spoken alerts and display names`.

---

### Task 5: vroo_audio: Dart API, test double and channels

**Files:**
- Create:
  - `packages/vroo_audio/`, from `flutter create --template=plugin --platforms=android,ios --org com.getvroo -a kotlin -i swift vroo_audio`. Set `publish_to: none` and replace the template's README.
  - `lib/vroo_audio.dart`, `lib/src/fake_vroo_audio.dart`, `lib/src/channel_vroo_audio.dart` and `lib/src/resample.dart`
  - `test/channel_vroo_audio_test.dart` and `test/resample_test.dart`
- Modify:
  - `docs/architecture.md` §4.5, the API block
  - `.gitignore`, to ignore every `ios/Flutter/Local.xcconfig`, and both examples' `ios/Flutter/Debug.xcconfig` and `Release.xcconfig`, to add `#include? "Local.xcconfig"`. Then signing an example never writes the team ID into a tracked file (Plan A review)

**Interfaces:**
- Produces:
  ```dart
  const audioSampleRate = 16000, audioFrameSamples = 320;
  enum CallState { idle, ringing, active }
  enum AudioRoute { bluetooth, wired, speaker, earpiece, other }
  enum StartResult { started, micDenied, failed }
  sealed class AudioEvent {}
  final class CallStateChanged extends AudioEvent { final CallState state; }
  final class InterruptionChanged extends AudioEvent { final bool began; }   // assistants, alarms, other apps
  final class RouteChanged extends AudioEvent { final AudioRoute output; final String name; final int hardwareRate; }
  final class AudioFailed extends AudioEvent { final String message; }
  abstract interface class VrooAudio {
    Stream<Int16List> get micFrames;   // 320 samples each
    Stream<AudioEvent> get events;
    /// Opens the call-style session, starts mic and playback, and keeps the app alive until stop().
    Future<StartResult> start({required String notificationText});
    Future<void> stop();
    void play(Int16List frame);        // 320 samples, queued for output
    Future<Int16List> synthesize(String text);   // speech as 16 kHz mono PCM
  }
  VrooAudio createVrooAudio();
  Int16List resample(Int16List pcm, int fromRate, int toRate);   // linear; the same rate gives a copy
  class FakeVrooAudio implements VrooAudio {
    StartResult startResult;
    final played = <Int16List>[];
    final spoken = <String>[];
    void emitMic(Int16List frame);
    void emit(AudioEvent e);
    bool speechFails;
  }
  ```
- **Channel contract:**
  - **MethodChannel `vroo_audio`:**
    - `start {notificationText}` answers `'started' | 'micDenied' | 'failed'`.
    - `stop`.
    - `synthesize {text}` answers `{rate: int, pcm: Uint8List}`, with the PCM as int16 little-endian. The Dart side resamples it to 16 kHz.
  - **EventChannel `vroo_audio/mic`:** `Uint8List` frames of 640 bytes. Decode them without assuming the byte offset is even; copy when it isn't.
  - **EventChannel `vroo_audio/events`:** maps, one per event:
    - `{type: 'call', state: 'idle' | 'ringing' | 'active'}`
    - `{type: 'interruption', began: bool}`
    - `{type: 'route', output: 'bluetooth' | 'wired' | 'speaker' | 'earpiece' | 'other', name, rate}`
    - `{type: 'failed', message}`
  - **BasicMessageChannel `vroo_audio/play`** with `BinaryCodec`: frames of 640 bytes.
- **Architecture §4.5 update:**
  - `synthesize` returns PCM, and tones are made in Dart. Speech, tones and voices are all mixed in Dart.
  - Route names are the five above.

- [ ] **Step 1: Write the failing tests**

```dart
// resample_test.dart
test('32 kHz to 16 kHz halves the length and keeps a constant level', ...);
test('22.05 kHz to 16 kHz gives round(n × 16000 ÷ 22050) samples', ...);
test('the same rate gives a copy', ...);
// channel_vroo_audio_test.dart, using TestDefaultBinaryMessengerBinding mock handlers
test('mic bytes become 320-sample frames, also from an odd offset', ...);
test('call, interruption and route events are decoded', ...);
test("start maps the platform's answer", ...);    // 'micDenied' becomes StartResult.micDenied
test('play sends 640 little-endian bytes', ...);
test('synthesize resamples speech to 16 kHz', ...);   // {rate: 22050, pcm: 2205 samples} gives 1600 samples
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd packages/vroo_audio && flutter test`
Expected: FAIL, because `resample` and the channel implementation aren't defined.

- [ ] **Step 3: Implement the API, the fake, the channel implementation and `resample`, and update architecture §4.5**

- [ ] **Step 4: Run the tests and watch them pass**

Run: `flutter test && flutter analyze`
Expected: all pass, with no issues.

- [ ] **Step 5: Hand over**

Suggested message: `feat(audio): vroo_audio Dart API, test double and channels`.

---

### Task 6: vroo_audio: Android

**Files:**
- Create: `android/src/main/kotlin/com/getvroo/vroo_audio/VrooAudioPlugin.kt`, `RideService.kt` and `Wav.kt`, plus `android/src/test/kotlin/com/getvroo/vroo_audio/WavTest.kt`
- Modify:
  - the plugin's `AndroidManifest.xml`
  - `example/lib/main.dart`: the "audio check" screen
  - `docs/test-plan.md` §5
  - `docs/development.md`: the Kotlin test command

**Interfaces:**
- Consumes: the channel contract (Task 5).
- Produces, for Android:
  - **`start`:**
    1. Answers `micDenied` if `RECORD_AUDIO` isn't granted.
    2. Starts `RideService`. It's in the foreground with an ongoing notification ("ride" channel, `notificationText`, the app's launcher icon). Its types are `microphone|connectedDevice` on API 30+; API 29 uses the plain `startForeground`. It holds a partial wake lock until stop.
    3. Requests audio focus: GAIN, with `USAGE_VOICE_COMMUNICATION` and `CONTENT_TYPE_SPEECH`.
    4. Sets `MODE_IN_COMMUNICATION`, then routes.
    5. Starts `AudioRecord(VOICE_COMMUNICATION, 16000, mono, PCM_16BIT)`, adding `AcousticEchoCanceler` and `NoiseSuppressor` where available. A reader thread reads 320 samples at a time and posts each frame to the main thread's event sink.
    6. Starts `AudioTrack(USAGE_VOICE_COMMUNICATION, CONTENT_TYPE_SPEECH, 16000, mono, MODE_STREAM)` in low-latency mode, primed with 40 ms of silence. `play` writes with `WRITE_NON_BLOCKING`, so whatever doesn't fit is dropped.
  - **Routing:**
    - **API 31+:** `setCommunicationDevice`, with the first available device of type `TYPE_BLUETOOTH_SCO`, then `TYPE_BLE_HEADSET`, `TYPE_WIRED_HEADSET` or `TYPE_USB_HEADSET`, then `TYPE_BUILTIN_SPEAKER`.
    - **API 29–30:**
      - When `isBluetoothScoAvailableOffCall` is true, run `startBluetoothSco()` and wait up to 3 s for `SCO_AUDIO_STATE_CONNECTED`.
      - Otherwise use the wired headset if one is plugged in, or turn the speakerphone on.
    - **Re-routing:** an `AudioDeviceCallback` re-routes whenever a device is added or removed. On API 31+, so does the communication-device listener.
    - **Route events:** every route is sent as a `route` event, once at start and then on every change.
  - **Calls:**
    - **API 31+:** `addOnModeChangedListener`. `MODE_RINGTONE` → ringing; `MODE_IN_CALL`, `MODE_CALL_SCREENING` or `MODE_CALL_REDIRECT` → active; any other mode after one of those → idle.
    - **API 29–30:** `TelephonyManager.listen(LISTEN_CALL_STATE)`. RINGING → ringing, OFFHOOK → active, IDLE → idle.
      - Expect no permission prompt on these versions. If Android asks for `READ_PHONE_STATE`, add it to the manifest and to the app's permission requests, and ledger it.
    - **On idle:** set the mode and routing again, and restart the record and track if they've stopped. Retry every 500 ms for 2 s, then every 2 s.
  - **Interruptions:** losing focus with `LOSS_TRANSIENT` or `LOSS_TRANSIENT_CAN_DUCK` → `began`; GAIN → `ended`.
  - **`synthesize`:**
    1. `TextToSpeech` is created once, with locale `en-IN`, or the default English voice when `en-IN` isn't available.
    2. `synthesizeToFile` writes into `cacheDir`.
    3. When it's done, `Wav.parse` reads the WAV and the answer is `{rate, pcm}`.
    4. After 10 s with no result, the call fails.
  - **`stop`:** releases the record, the track and the threads; abandons focus; clears the communication device or stops SCO; sets `MODE_NORMAL`; stops `RideService`.
  - **`Wav.parse(bytes): Pair<Int, ShortArray>?`:** reads RIFF/WAVE 16-bit PCM, mixes stereo down to mono, skips chunks other than `fmt ` and `data`, and returns null for anything else.
  - **Manifest:**
    - **Permissions:** `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`, `BLUETOOTH` (maxSdkVersion 30), `BLUETOOTH_CONNECT`, `CHANGE_NETWORK_STATE`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `POST_NOTIFICATIONS` and `WAKE_LOCK`. Android 14 lets a connected-device service start only when the app holds `CHANGE_NETWORK_STATE`, which is a normal permission.
    - **Service:** `.RideService`, not exported, `foregroundServiceType="microphone|connectedDevice"` and `stopWithTask="false"`.
  - **The audio check screen** (example):
    - **Start** and **Stop** buttons.
    - The route, and the mic level in dBFS.
    - A **Hear yourself** switch: each mic frame plays again 25 frames (500 ms) later.
    - A **Say a test message** button. It synthesizes "This is Vroo. Can you hear me?" and plays it frame by frame on the mic clock.
    - A list of events.

- [ ] **Step 1: Write the failing Kotlin test**

`WavTest.kt`:
- `parses 16-bit mono PCM and skips a LIST chunk`
- `mixes stereo down to mono`
- `returns null for non-PCM data`

- [ ] **Step 2: Run it and watch it fail**

Run: `cd packages/vroo_audio/example && flutter build apk --config-only && cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@17 ./gradlew :vroo_audio:testDebugUnitTest`
Expected: FAIL, because `Wav` isn't defined.

- [ ] **Step 3: Implement `Wav.kt`, the plugin, `RideService`, the manifest and the example screen**

- [ ] **Step 4: Run the test and build the example**

Run: the Gradle command again, then `cd .. && flutter build apk --debug`.
Expected: 3 Kotlin tests pass, and `Built build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step 5: Run the device check**

Run: `flutter run -d <android id>`.

👤 Founder checklist, on the Android phone:
1. Pair your intercom or Bluetooth earphones with the phone as usual, and put them on.
2. Tap **Start**. Allow the microphone if asked.
3. Turn on **Hear yourself**, then say "one, two, three".
4. Tap **Say a test message**.
5. Switch the intercom off. Talk for a few seconds. Then switch it on again.
6. Lock the phone for 2 minutes with **Hear yourself** on, and talk now and then.
7. Tap **Stop**.

Expected:
- **Step 3:** you hear yourself in the intercom about half a second later, and the route says Bluetooth.
- **Step 4:** you hear "This is Vroo. Can you hear me?" in the intercom.
- **Step 5:** the route changes to the loudspeaker within a few seconds, and the phone keeps playing. Within 10 s of the intercom coming back, the route is Bluetooth again, without touching the app.
- **Step 6:** you're still heard while locked, and the "Vroo" notification shows.

The desk Android has no SIM, so the call check waits for a phone with one.

- [ ] **Step 6: Record the result**

Add a dated line to test-plan §5:

`Android audio check: route <route>, hear yourself ok|fail, speech ok|fail, intercom off and on ok|fail, locked 2 min ok|fail`

Add the Kotlin command to the development.md Tests table.

- [ ] **Step 7: Hand over**

Suggested message: `feat(audio): Android audio, calls, speech and the ride service; device check`.

---

### Task 7: vroo_audio: iOS

**Files:**
- Create: `ios/vroo_audio/Sources/vroo_audio/VrooAudioPlugin.swift`
- Modify:
  - `ios/vroo_audio/Package.swift` and `ios/vroo_audio.podspec`: iOS 17
  - the example's `ios/Runner/Info.plist`
  - `docs/test-plan.md` §5

**Interfaces:**
- Consumes: the channel contract (Task 5), and the audio check screen (Task 6).
- Produces, for iOS:
  - **`start`:**
    1. **Permission:** checks `AVAudioApplication.shared.recordPermission`. If undetermined, it asks. If denied, it answers `micDenied`.
    2. **Session:**
       - Category `.playAndRecord`, mode `.voiceChat`, options `[.allowBluetoothHFP, .mixWithOthers]`.
       - Preferred sample rate 16000, and a preferred IO buffer of 0.02 s. Then `setActive(true)`.
    3. **Engine:**
       - `inputNode.setVoiceProcessingEnabled(true)` before starting, and other-audio ducking set to `.min` without advanced ducking.
       - A tap on input bus 0, in the hardware format. An `AVAudioConverter` turns the tap's audio into 16 kHz mono Int16, using channel 0 when there are several. It cuts that into 320-sample frames and sends each to the event sink on the main thread.
       - An `AVAudioSourceNode` (16 kHz mono float) is connected to the main mixer. It reads a lock-protected ring of up to 200 ms that `play` fills: the oldest frames are dropped on overflow, and it plays zeros when empty. The ring is primed with 40 ms of silence and cleared on every restart.
    4. **Loudspeaker fallback:** when the output is the built-in receiver, `overrideOutputAudioPort(.speaker)`.
  - **Interruptions:**
    - **`interruptionNotification`:** `began` → `began`. On `ended`, it reactivates the session and restarts the engine, retrying every 0.5 s for 2 s and then every 2 s. Then it sends `ended`.
    - **`mediaServicesWereResetNotification`:** it rebuilds the engine, and sends `failed` if it can't.
  - **Routes:** each `routeChangeNotification` sends a `route` event with the session's sample rate.
    - `.bluetoothHFP` and `.bluetoothLE` → bluetooth
    - `.headphones`, `.headsetMic` and `.usbAudio` → wired
    - `.builtInSpeaker` → speaker
    - `.builtInReceiver` → earpiece
    - anything else → other
  - **Calls:** a `CXCallObserver` delegate. A call that hasn't ended and has connected → active. An incoming call not yet connected → ringing. An outgoing call is active from dialling (PC4). No calls → idle. If no interruption `ended` arrives within 1 s of idle, it restarts anyway.
  - **`synthesize`:** `AVSpeechSynthesizer.write`, with an `en-IN` voice or the default English one. It collects the buffers as Int16 mono at the buffer's own rate, and answers `{rate, pcm}` when the final empty buffer arrives.
  - **`stop`:** stops the engine and removes the tap, then `setActive(false, options: .notifyOthersOnDeactivation)`.
  - **Info.plist (example):** `NSMicrophoneUsageDescription` = "Vroo carries your voice to the other riders.", and `UIBackgroundModes` = `audio`.

- [ ] **Step 1: Implement the Swift plugin**

Run: `cd packages/vroo_audio/example && flutter build ios --debug --no-codesign`
Expected: `Built build/ios/iphoneos/Runner.app`.

- [ ] **Step 2: Run the device check**

Run: `flutter run -d <iphone id>`.

👤 Founder checklist, on the iPhone. Steps 1 to 6 are the same as Task 6. Then:

7. Ask someone to call the iPhone while **Hear yourself** is on.
8. Answer with the intercom's button. Talk for a few seconds, then hang up.

Expected:
- **Steps 1 to 6:** as in Task 6. When locked, there's no notification on iPhone; instead the status bar shows the mic indicator.
- **Step 7:** the ringtone sounds as usual.
- **During the call:** you don't hear yourself. The events list shows `call ringing`, then `call active`.
- **After hanging up:** within 2 s you hear yourself again, and the events list shows `call idle`.

- [ ] **Step 3: Record the result**

Add a dated line to test-plan §5:

`iOS audio check: route <route>, hear yourself ok|fail, speech ok|fail, intercom off and on ok|fail, locked 2 min ok|fail, call: ringtone ok|fail, intercom answer ok|fail, silent during the call ok|fail, back within 2 s ok|fail`

- [ ] **Step 4: Hand over**

Suggested message: `feat(audio): iOS audio session, calls and speech; device check`.

---

### Task 8: Voice over the box link, and VoicePipeline

**Files:**
- Modify:
  - `app/lib/net/box_link.dart` and `app/lib/net/peer.dart`
  - `app/pubspec.yaml`: `vroo_audio` by path
  - `docs/architecture.md` §5.3: the VOICE frameNo and ECHO lines
  - `packages/vroo_net/lib/src/channel_vroo_net.dart`: iOS box sends
- Create: `app/lib/voice/voice_pipeline.dart` and `app/test/fake_codec.dart`
- Test: `app/test/box_link_test.dart` (more tests) and `app/test/voice/voice_pipeline_test.dart`

**Interfaces:**
- Consumes:
  - `OpusEncoder` and `OpusDecoder` (Task 1)
  - `VoiceGate`, `mix` and `busyTone` (Task 2)
  - `JitterBuffer` (Task 3)
  - `TalkSlots` (Task 4)
  - `VrooAudio` and `FakeVrooAudio` (Task 5)
- Produces:
  ```dart
  // box_link.dart
  class HeardVoice { const HeardVoice(this.src, this.session, this.frame); final int src, session; final VoiceFrame frame; }
  // in BoxLink:
  Future<void> sendVoice(VoiceFrame frame);   // a sealed VOICE packet, same seq counter
  Stream<HeardVoice> get voices;              // others' voice after dedupe; never this phone's own
  bool talking = false, onCall = false;       // the heartbeat's flag bits 0 and 1
  // PeerInfo.talking and PeerInfo.onCall follow each BEAT's flags.

  // voice_pipeline.dart
  class VoiceStats { final int played, recovered, concealed, late, skipped, depth; }
  class VoicePipeline {
    VoicePipeline({required VrooAudio audio, required OpusEncoder encoder, required OpusDecoder Function() newDecoder,
        required Future<void> Function(VoiceFrame) send, required Clock clock, required VoiceGate gate,
        required TalkSlots slots, required RideLog log, int maxVoices = 4});
    void start();             // listens to audio.micFrames
    Future<void> stop();      // closes every decoder
    bool muted = false;       // calls and interruptions: nothing sent, silence played, buffers cleared
    bool get talking;         // the gate is open and frames are going out
    bool get held;            // the last frame was held for a talk slot
    void onVoice(HeardVoice v);
    void say(Int16List pcm);  // queues alert audio into the mix
    Map<int, VoiceStats> get stats;
    int sentFrames = 0, heldFrames = 0;
  }
  ```
- **Per mic frame, in order:**
  1. **Count:** frameNo goes up by one.
  2. **Send side, unless muted:**
     - The gate's frames get consecutive numbers ending at the current one, so pre-roll frames keep their own.
     - Each frame goes to `slots.decide`:
       - `send`: encode it and send it.
       - `hold`: count it.
       - `holdWithBusyTone`: count it, `say(busyTone())`, and log `slot,state=busy`.
  3. **Playback side:**
     - The oldest `maxVoices` senders' buffers each give one `next()`:
       - `PlayFrame` → `decode(opus)`
       - `RecoverFrame` → `decode(next, fec: true)`
       - `ConcealFrame` → `decode(null)`
     - Add the next 320 samples of queued alert audio, `mix`, and `audio.play` one frame. When muted, play silence.
- **Senders:**
  - Each sender has a buffer and a decoder, keyed by src.
  - A different session from the same src resets that sender.
  - A sender quiet for 10 s is removed, and its decoder closed.
  - `onVoice` also calls `slots.heard`.
- **iOS socket churn (Plan A review):** a box send that returns 0 means the socket's buffer is full, which happens at 50 packets a second.
  - It drops that datagram but keeps the socket. Only a SocketException, or the box's Wi-Fi coming back, replaces it.
  - Why: each new socket is a new source port, and the box keeps a stale entry for 30 s in its 4-entry phone table.
  - There's no unit test, because a socket can't be made to fill on demand. The Task 11 bench checks it: the box line shows 2 phones while both talk.
- **ECHO fix:** BoxLink replies to every 5th BEAT it has received from each sender, counted per sender (architecture §5.3). Before this, the rule was the packet's seq % 5. Voice packets share that counter, so the old rule could stop echoes while someone talks.

- [ ] **Step 1: Write the failing tests**

`fake_codec.dart`:
- `FakeEncoder implements OpusEncoder` puts the frame's first sample into 2 bytes.
- `FakeDecoder implements OpusDecoder` returns a frame filled with that value. With `fec`, it returns half the value; for a null packet, zeros. It counts its calls and records whether it's closed.

```dart
// box_link_test.dart
test('voice frames reach the other phone with their frame numbers', ...);
test('a phone never hears its own voice', ...);
test('the talking and on-call flags travel in the heartbeat', ...);
test('echoes keep coming while voice runs', ...);   // both send 50 voice frames a second for 12 s; rttMs updates after 6 s
// voice_pipeline_test.dart, with FakeVrooAudio and the fake codec
test('silence sends nothing, and speech goes out with its pre-roll frame numbers', ...);   // frames 48, 49, 50
test('heard voice plays, one frame out for each mic frame', ...);
test('held frames are dropped, not queued, with one busy tone', ...);
test('up to 4 voices are mixed; a fifth sender is not played', ...);   // 5 senders at 1000 each: samples are 4000
test('muted: nothing is sent and silence is played', ...);
test("a new session from the same rider restarts that rider's buffer", ...);
test('a sender quiet for 10 s is removed and its decoder closed', ...);
test('alert audio mixes over the voices', ...);
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd app && flutter test test/box_link_test.dart test/voice/voice_pipeline_test.dart`
Expected: FAIL, because `sendVoice`, `voices` and `VoicePipeline` aren't defined.

- [ ] **Step 3: Implement BoxLink's voice, flags and the ECHO fix, then `VoicePipeline`, and update architecture §5.3**

- [ ] **Step 4: Run the tests and watch them pass**

Run: `flutter test && flutter analyze`
Expected: all pass, Plan A's included, with no issues.

- [ ] **Step 5: Hand over**

Suggested message: `feat(voice): voice over the box link and the voice pipeline`.

---

### Task 9: RideEngine: calls, interruptions, alerts and stats

**Files:**
- Create: `app/lib/ride/ride_engine.dart`, and `app/test/ride/ride_harness.dart` (two phones on a `FakeBox`, each with `FakeVrooAudio` and the fake codec)
- Modify: `app/test/fake_box.dart`, to add `FakeBox({bool duplicate = false})`, which delivers every datagram twice
- Test: `app/test/ride/ride_engine_test.dart`

**Interfaces:**
- Consumes: `BoxConnection` and `BoxLink` (Plan A and Task 8); `VoicePipeline` (Task 8); `Alerts` and `displayNames` (Task 4); `VrooAudio` (Task 5).
- Produces:
  ```dart
  enum RideProblem { micDenied, audioFailed }
  class RideState {
    final BoxLinkState? link;
    final AudioRoute? route;
    final String? routeName;
    final bool talking, onCall, held;
    final Map<int, String> names;
    final Map<int, VoiceStats> voice;
    final RideProblem? problem;
    final String? problemText;
  }
  class RideEngine {
    RideEngine({required VrooNet net, required VrooAudio audio, required SavedBox box, required GroupKeys keys,
        required String groupName, required int riderId, required String riderName, required int platform,
        required Clock clock, required RideLog log, double sensitivityDb = 12,
        OpusEncoder Function() newEncoder = OpusEncoder.new, OpusDecoder Function() newDecoder = OpusDecoder.new});
    Stream<RideState> get states;
    Future<StartResult> start();
    Future<void> stop();
    set sensitivityDb(double db);
  }
  ```
- **`start`:**
  1. `audio.start(notificationText: 'Riding with <groupName>')`. If the answer isn't `started`, set the problem, log it, and stop there: nothing goes on the box.
  2. Then start BoxConnection, BoxLink and the pipeline.
- **Calls and interruptions:**
  - `CallStateChanged`:
    - `ringing` or `active`: the pipeline is muted, `link.onCall` turns on, and the log records `call,state=<state>`.
    - `idle`: both turn off, unless an interruption is still running.
  - `InterruptionChanged`: mutes while it lasts, and logs `audio,interruption=began|ended`.
  - `RouteChanged`: logs `audio,route=<output> name=<name> rate=<rate>` and updates the state. The ride carries on.
- **Every second, on BoxLink's state:**
  1. `link.talking = pipeline.talking`.
  2. Run `alerts.update(...)`.
  3. For each `Say`, `audio.synthesize` the text, then `pipeline.say` it. Texts are cached once spoken. A failed synthesis logs `audio,speech=failed` and is skipped.
  4. For each `BackTone`, `pipeline.say(backTone())`.
- **Every 5 s:**
  - One `stats` line per rider: `peer=<name> rx=… fec=… plc=… late=… skip=… depth=… rtt=…`.
  - One line for this phone: `me tx=… held=…`.

- [ ] **Step 1: Write the failing tests**

```dart
test("A's voice plays on B and never on A", ...);
test('each frame plays once when the box delivers it twice', ...);
test('a call mutes both ways, and the others hear about it', ...);
  // A ringing: A sends no voice, plays silence, and B speaks "A is on a call".
  // A idle: A's voice reaches B again within 100 ms, and B speaks "A is off the call".
test('a declined call brings the rider straight back', ...);   // ringing, then idle
test('an interruption mutes until it ends', ...);
test('a route change keeps the ride going, and is logged', ...);   // ',audio,route=bluetooth'
test('mic denied stops the start', ...);
  // start() is micDenied, the state's problem is micDenied, and no packet goes to the box
test("a failed speech engine doesn't stop the ride", ...);   // ',audio,speech=failed', and voice keeps flowing
test('spoken alerts reach the speaker', ...);    // B hears the synthesized "A dropped off" in its played frames
test('stats are logged every 5 s', ...);
```

- [ ] **Step 2: Run them and watch them fail**

Run: `flutter test test/ride/ride_engine_test.dart`
Expected: FAIL, because `RideEngine` isn't defined.

- [ ] **Step 3: Implement `RideEngine`, the harness and the duplicate mode**

- [ ] **Step 4: Run the tests and watch them pass**

Run: `flutter test && flutter analyze`
Expected: all pass, with no issues.

- [ ] **Step 5: Hand over**

Suggested message: `feat(ride): ride engine with calls, alerts and stats`.

---

### Task 10: Ride screen, platform setup and licences

**Files:**
- Create: `app/lib/ui/ride_screen.dart` and `app/android/app/src/main/kotlin/com/getvroo/vroo/VrooApplication.kt`
- Delete: `app/lib/ui/test_screen.dart`
- Modify:
  - `app/lib/ui/home_screen.dart`: **Start ride**, and **Licences** in the app bar
  - `app/lib/main.dart`: register the libopus licence, and pass `createVrooAudio()` down the way `net` is passed
  - `app/lib/rider_store.dart`: `micSensitivityDb`, default 12
  - `app/android/app/src/main/kotlin/com/getvroo/vroo/MainActivity.kt`, and the app's `AndroidManifest.xml` (`android:name=".VrooApplication"`)
  - `app/ios/Runner/Info.plist`
  - `docs/development.md`
- Test: `app/test/ride_screen_test.dart`, and update `app/test/widget_test.dart`

**Interfaces:**
- Consumes: `RideEngine` and `RideState` (Task 9); `libopusLicense` (Task 1).
- Produces:
  - **The ride screen, top to bottom:**
    - The group name with a rider count, and **Stop**
    - The box line, as Plan A's test screen has it, with `boxHint`'s instruction under it (Plan A review)
    - "Internet ✓/✗"
    - "Audio: Bluetooth (16 kHz)", or "Wired", "Loudspeaker", "Earpiece"
    - "You: talking", "quiet", "on a call", or "waiting for a slot"
    - A **Mic sensitivity** slider, 6 to 24 dB, saved
    - The riders, by display name, with 🎙 while talking, 📞 while on a call, "heard N s ago", the round trip and the lost percentage
    - **Share log**
  - **Problems:**
    - For `micDenied`, the screen says "Allow the microphone in Settings, then start the ride again." with an **Open Settings** button (`openAppSettings`).
    - For `audioFailed`, it says "Audio didn't start: <text>".
  - **Permissions:** before the start, ask with `permission_handler` for the microphone, notifications (Android 13+, denial is fine) and Bluetooth connect (Android 12+, denial is fine).
  - **Licences:** `LicenseRegistry.addLicense` adds `libopusLicense` under "libopus", and **Licences** opens `showLicensePage(applicationName: 'Vroo')`.
  - **Android, so the ride survives a swipe from recents:**
    - `VrooApplication` starts a `FlutterEngine` in `onCreate`, runs the default Dart entrypoint, and caches it as `"main"`.
    - `MainActivity` overrides `getCachedEngineId()` to return `"main"`. A cached engine isn't destroyed with the activity.
  - **iOS Info.plist:** `NSMicrophoneUsageDescription` = "Vroo carries your voice to the other riders.", and `UIBackgroundModes` = `audio`.

- [ ] **Step 1: Write the failing widget tests**

```dart
testWidgets('mic denied shows how to fix it', ...);
  // FakeVrooAudio with startResult micDenied: the screen shows "Allow the microphone" and Open Settings
testWidgets('a talking rider shows the mic, and a rider on a call shows the phone', ...);
testWidgets('no headset shows Loudspeaker', ...);   // RouteChanged(speaker)
```

- [ ] **Step 2: Run them and watch them fail**

Run: `flutter test test/ride_screen_test.dart`
Expected: FAIL, because `RideScreen` isn't defined.

- [ ] **Step 3: Implement the screen, the home and main changes, the store field, the Android engine and the Info.plist keys. Delete `test_screen.dart`**

- [ ] **Step 4: Run all the tests and both release builds**

Run: `flutter test && flutter analyze && flutter build apk --release && flutter build ios --release`
Expected: all pass, with no issues, and both builds succeed. iOS signs with `Local.xcconfig`.

- [ ] **Step 5: Update development.md**

The ride screen replaces the test screen. Running a ride needs a paired intercom or earphones on each phone.

- [ ] **Step 6: Hand over**

Suggested message: `feat(app): ride screen with voice, permissions and licences`.

---

### Task 11: Bench test with the founder, and write-up

**Files:**
- Modify:
  - `docs/test-plan.md` §5
  - `docs/spec.md` §10: U5, if it's tested
  - `docs/todo.md`
  - `docs/decisions.md`, if a knob changes

**Interfaces:**
- Consumes: the whole test build (Tasks 1–10).

- [ ] **Step 1: Install the release build on both phones**

Run: `cd app && flutter run --release -d <iphone id>`, then `flutter run --release -d <android id>`.

👤 The founder plugs in the box, and pairs an intercom or earphones with each phone. Wired earphones on one phone are fine.

- [ ] **Step 2: 👤 Founder: run the bench checklist**

Read it aloud while doing it.

1. Both phones join the box's Wi-Fi as in Plan A. Then, on both, open Vroo and tap **Start ride**. Allow the microphone, and on Android notifications if asked.
2. Take turns: the Android rider counts to ten, the iPhone rider answers. Then both talk at the same time for 10 seconds.
3. Both stay quiet for 30 seconds.
4. Talk softly, and move the mic sensitivity slider until soft talk gets through.
5. Lock both phones for 10 minutes. Talk every 2 minutes.
6. On the Android phone: unlock, swipe Vroo away from recent apps, and lock it again. Talk.
7. On the iPhone: close Vroo completely (swipe it away), open it again and tap **Start ride**. The Android rider talks.
8. Ask someone to call the iPhone. Answer with the intercom's button. The Android rider talks during the call. Hang up after 20 seconds.
9. Optional: start navigation with voice guidance on one phone and drive the route in a simulator, or walk it.
10. Pull the box's power for 15 seconds, then plug it back in.
11. On both, tap **Stop**, then **Share log**, and send the files to the Mac.

Expected:
- **Step 1:** each phone lists the other, and the audio line says Bluetooth or Wired.
- **Step 2:** each rider hears the other clearly, nobody hears themselves, and both voices come through when they talk at once. The box line shows 2 phones throughout.
- **Step 3:** there's no hiss or noise from the other phone.
- **Step 4:** a setting is found that lets soft talk through.
- **Steps 5 and 6:** voice keeps working, and the Android notification stays.
- **Step 7:** the iPhone hears the Android rider again within a few seconds of starting the ride, and the Android rider hears the iPhone. The restarted app has a new session.
- **Step 8:**
  - The ringtone is normal.
  - During the call the group is silent both ways, and the caller hears no group.
  - The Android rider hears "<iPhone name> is on a call".
  - Within 2 s of hanging up the group is back, and the Android rider hears "<iPhone name> is off the call".
- **Step 9:** note whether the prompts are heard (OA1, U5).
- **Step 10:** after 10 s each phone says "Your box is disconnected". Voice returns by itself on the iPhone. The Android needs the Connect tap; that's a known follow-up.

- [ ] **Step 3: Write up the results**

1. Add a dated "Plan B bench" entry to test-plan §5:
   - each expected line, with pass or fail
   - from the logs: round trip with voice running, loss, FEC and concealment counts, and jitter depth
   - an estimated mouth-to-ear delay: half the round trip, plus 20 ms per frame of jitter depth, plus 60 ms (one frame and the playout ring)
   - the founder's words on quality
2. **If the round trip with voice is still over 200 ms:** add a todo M1 item "Keep the phones' Wi-Fi power saving off during a ride (Android low-latency Wi-Fi lock)". Otherwise tick the round-trip follow-up.
3. **If voice sounds choppy while the network is fine** (concealment is high but loss is low), Dart's timing is too uneven. Record it as architecture §4.2's fallback: move the jitter buffer and mixer into `vroo_audio`, as a todo item and a decisions.md entry.
4. Add a todo item: "Calls on Android: check with a phone that has a SIM".
5. **spec §10:** update U5 if step 9 ran.
6. **todo M1:**
   - Tick `vroo_audio`, Opus, and the Android background item.
   - Split "Path policy and talk slots" so the talk slots part is ticked.
   - Mark the minimal ride screen as partly done.
   - Tick M2's spoken-messages item for the box path.
7. **decisions.md:** record any knob that changed, with its reason.

- [ ] **Step 4: Hand over**

Suggested message: `docs: Plan B bench results`.

**Plan B is done when:**
- every test passes: `dart test` (vroo_opus), `flutter test` (vroo_audio and the app), the firmware host tests, and both Kotlin suites
- the two audio device checks and the Task 11 bench are written up, whether they passed or failed
