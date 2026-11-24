// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CallKit
import Flutter
import UIKit
import os

/// iOS side of vroo_audio; the channel contract is in lib/src/channel_vroo_audio.dart. Voice runs in a voice-chat
/// session on the intercom's HFP link, mixable so navigation prompts still play, and iOS keeps the app running in the
/// background while the session is active (background mode `audio`). The group is never registered as a call:
/// CallKit is used only to observe the phone's own calls (D7). Method calls, notifications and events are handled
/// on the main queue. The mic sink and the playback node run on the audio IO thread, and a capture thread turns the
/// mic's audio into frames.
public class VrooAudioPlugin: NSObject, FlutterPlugin, CXCallObserverDelegate {
  private let session = AVAudioSession.sharedInstance()
  private let ring = Ring(capacity: 3200)  // 200 ms at 16 kHz
  private let callObserver = CXCallObserver()
  private var engine: AVAudioEngine?
  private var capture: MicCapture?  // the mic's audio on its way to Dart, made afresh on every engine (re)start
  private var sinkNode: AVAudioSinkNode?
  private var micSink: FlutterEventSink?
  private var eventSink: FlutterEventSink?
  private var playChannel: FlutterBasicMessageChannel?
  private var running = false
  private var interrupted = false
  private var callState = "idle"
  private var restartGeneration = 0
  private var synthesizer: AVSpeechSynthesizer?

  private static let frameSamples = 320
  private static let rate = 16000.0

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = VrooAudioPlugin()
    let messenger = registrar.messenger()
    registrar.addMethodCallDelegate(instance, channel: FlutterMethodChannel(name: "vroo_audio", binaryMessenger: messenger))
    FlutterEventChannel(name: "vroo_audio/mic", binaryMessenger: messenger).setStreamHandler(Sink { instance.micSink = $0 })
    FlutterEventChannel(name: "vroo_audio/events", binaryMessenger: messenger).setStreamHandler(Sink { instance.eventSink = $0 })
    let play = FlutterBasicMessageChannel(
      name: "vroo_audio/play", binaryMessenger: messenger, codec: FlutterBinaryCodec.sharedInstance())
    play.setMessageHandler { message, reply in
      if let data = message as? Data { instance.ring.write(data) }
      reply(nil)
    }
    instance.playChannel = play
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start": start(result: result)
    case "stop":
      stop()
      result(nil)
    case "restart":  // Dart saw the mic go quiet: start it afresh, whatever state it's in
      engine?.stop()
      restart()
      result(nil)
    case "synthesize": synthesize(args["text"] as? String ?? "", result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func emit(_ event: [String: Any]) { eventSink?(event) }

  // MARK: Start and stop

  private func start(result: @escaping FlutterResult) {
    if running { return result("started") }
    switch AVAudioApplication.shared.recordPermission {
    case .granted: result(startNow())
    case .undetermined:
      AVAudioApplication.requestRecordPermission { granted in
        DispatchQueue.main.async { result(granted ? self.startNow() : "micDenied") }
      }
    default: result("micDenied")
    }
  }

  private func startNow() -> String {
    // Listening before the engine starts: iOS can stop it straight away, as the route settles.
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(onInterruption), name: AVAudioSession.interruptionNotification, object: session)
    center.addObserver(self, selector: #selector(onRouteChange), name: AVAudioSession.routeChangeNotification, object: session)
    center.addObserver(
      self, selector: #selector(onMediaReset), name: AVAudioSession.mediaServicesWereResetNotification, object: session)
    center.addObserver(self, selector: #selector(onConfigurationChange), name: .AVAudioEngineConfigurationChange, object: nil)
    do {
      try configureSession()
      try startEngine()
      running = true
      callObserver.setDelegate(self, queue: .main)
      emitRoute()
      return "started"
    } catch {
      NSLog("vroo_audio: start failed: \(error)")
      stop()
      return "failed"
    }
  }

  private func stop() {
    running = false
    interrupted = false
    restartGeneration += 1
    NotificationCenter.default.removeObserver(self)
    callObserver.setDelegate(nil, queue: nil)
    engine?.stop()
    engine = nil
    sinkNode = nil
    capture?.stop()
    capture = nil
    ring.clear(primeSamples: 0)
    callState = "idle"
    try? session.setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func configureSession() throws {
    if #available(iOS 26.0, *) {
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .mixWithOthers])
    } else {
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .mixWithOthers])
    }
    try? session.setPreferredSampleRate(Self.rate)
    try? session.setPreferredIOBufferDuration(0.02)
    try session.setActive(true)
    speakerIfReceiver()
  }

  /// With no headset, voice chat plays from the earpiece; the loudspeaker is the useful last resort (VO5).
  private func speakerIfReceiver() {
    if session.currentRoute.outputs.first?.portType == .builtInReceiver { try? session.overrideOutputAudioPort(.speaker) }
  }

  // MARK: Audio in and out

  private func startEngine() throws {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    try input.setVoiceProcessingEnabled(true)  // echo and noise cancelling
    input.voiceProcessingOtherAudioDuckingConfiguration =
      AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
    let playFormat = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
    let ring = self.ring
    let source = AVAudioSourceNode(format: playFormat) { _, _, frameCount, bufferList -> OSStatus in
      let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
      if let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) { ring.read(into: out, frames: Int(frameCount)) }
      return noErr
    }
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: playFormat)
    capture?.stop()  // the old engine's capture and sink go with it
    capture = nil
    sinkNode = nil
    self.engine = engine
    try runEngine()
  }

  /// Starts the engine with a fresh mic capture in the hardware's current format. iOS stops the engine whenever that
  /// format changes (a new route, or the route settling just after a start), and a capture in the old format won't
  /// start. The mic comes through a sink node, in IO-buffer-sized pieces (about 20 ms here): a tap can't go below
  /// 100 ms, which would send voice in bursts and add delay.
  private func runEngine() throws {
    guard let engine else { return }
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,  // no input yet, mid-change
      let capture = MicCapture(rate: inputFormat.sampleRate, onFrame: { [weak self] frame in
        DispatchQueue.main.async { self?.micSink?(FlutterStandardTypedData(bytes: frame)) }
      })
    else { throw NSError(domain: "vroo_audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "no mic converter"]) }
    self.capture?.stop()
    if let old = sinkNode { engine.detach(old) }
    let sink = AVAudioSinkNode { _, frames, data -> OSStatus in
      capture.write(data, frames: frames)
      return noErr
    }
    engine.attach(sink)
    engine.connect(input, to: sink, format: inputFormat)
    self.capture = capture
    sinkNode = sink
    ring.clear(primeSamples: 640)  // 40 ms of silence
    engine.prepare()
    try engine.start()
  }

  // MARK: Interruptions, routes and calls

  @objc private func onInterruption(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    DispatchQueue.main.async {
      switch type {
      case .began:
        self.interrupted = true
        self.emit(["type": "interruption", "began": true])
        self.recoverLater()
      case .ended: self.restart()
      @unknown default: break
      }
    }
  }

  /// iOS may never send an interruption's end (after Siri, say). Outside a call, start trying to come back after 3 s:
  /// reactivating fails while the other audio still holds the session, and works once it lets go.
  private func recoverLater() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      guard let self, self.running, self.interrupted, self.callState == "idle" else { return }
      self.restart()
    }
  }

  /// Reactivates the session and the engine after an interruption, a call or a format change: every 0.5 s for 2 s,
  /// then every 2 s.
  private func restart() {
    restartGeneration += 1
    attemptRestart(generation: restartGeneration, tries: 0)
  }

  private func attemptRestart(generation: Int, tries: Int) {
    guard running, generation == restartGeneration else { return }
    do {
      try session.setActive(true)
      if engine?.isRunning != true { try runEngine() }
      speakerIfReceiver()
      if interrupted { emit(["type": "interruption", "began": false]) }
      interrupted = false
      emitRoute()
    } catch {
      DispatchQueue.main.asyncAfter(deadline: .now() + (tries < 4 ? 0.5 : 2.0)) { [weak self] in
        self?.attemptRestart(generation: generation, tries: tries + 1)
      }
    }
  }

  @objc private func onMediaReset(_ note: Notification) {
    DispatchQueue.main.async {
      guard self.running else { return }
      self.engine?.stop()
      self.engine = nil
      do {
        try self.configureSession()
        try self.startEngine()
        if self.interrupted { self.emit(["type": "interruption", "began": false]) }
        self.interrupted = false
        self.emitRoute()
      } catch {
        self.emit(["type": "failed", "message": "audio didn't come back: \(error.localizedDescription)"])
      }
    }
  }

  /// iOS stopped the engine for a format change. During an interruption the interruption's end restarts it instead.
  @objc private func onConfigurationChange(_ note: Notification) {
    DispatchQueue.main.async {
      guard self.running, !self.interrupted, let engine = self.engine, (note.object as AnyObject?) === engine else { return }
      self.restart()
    }
  }

  @objc private func onRouteChange(_ note: Notification) {
    DispatchQueue.main.async {
      guard self.running else { return }
      self.speakerIfReceiver()
      self.emitRoute()
    }
  }

  private func emitRoute() {
    let port = session.currentRoute.outputs.first
    let output: String
    switch port?.portType {
    case AVAudioSession.Port.bluetoothHFP?, AVAudioSession.Port.bluetoothLE?: output = "bluetooth"
    case AVAudioSession.Port.headphones?, AVAudioSession.Port.headsetMic?, AVAudioSession.Port.usbAudio?: output = "wired"
    case AVAudioSession.Port.builtInSpeaker?: output = "speaker"
    case AVAudioSession.Port.builtInReceiver?: output = "earpiece"
    default: output = "other"
    }
    emit(["type": "route", "output": output, "name": port?.portName ?? "", "rate": Int(session.sampleRate)])
  }

  public func callObserver(_ observer: CXCallObserver, callChanged call: CXCall) {
    let calls = observer.calls.filter { !$0.hasEnded }
    let state =
      calls.contains { $0.hasConnected || $0.isOutgoing } ? "active" : (calls.isEmpty ? "idle" : "ringing")
    guard state != callState else { return }
    callState = state
    emit(["type": "call", "state": state])
    guard state == "idle" else { return }
    // The interruption's end usually restarts the audio; if it hasn't within 1 s, restart anyway.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, self.running, self.callState == "idle", self.interrupted || self.engine?.isRunning != true
      else { return }
      self.restart()
    }
  }

  // MARK: Speech: the phone's own voice, sent back as PCM at its own rate

  private func synthesize(_ text: String, result: @escaping FlutterResult) {
    let synthesizer = self.synthesizer ?? AVSpeechSynthesizer()
    self.synthesizer = synthesizer
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-IN") ?? AVSpeechSynthesisVoice(language: "en-US")
    let speech = Speech(result: result)
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
      speech.answer(FlutterError(code: "speech", message: "no speech within 10 s", details: nil))
    }
    synthesizer.write(utterance) { buffer in
      guard let pcm = buffer as? AVAudioPCMBuffer else { return }
      if pcm.frameLength == 0 {  // the last buffer
        let (rate, data) = speech.collected()
        DispatchQueue.main.async { speech.answer(["rate": rate, "pcm": FlutterStandardTypedData(bytes: data)]) }
      } else {
        speech.append(pcm)
      }
    }
  }
}

/// One spoken message, gathered on the synthesizer's thread and answered once on the main queue.
private final class Speech {
  private let result: FlutterResult
  private let lock = OSAllocatedUnfairLock()
  private var data = Data()
  private var rate = 0
  private var answered = false

  init(result: @escaping FlutterResult) { self.result = result }

  func append(_ pcm: AVAudioPCMBuffer) {
    let n = Int(pcm.frameLength)
    var chunk = Data()
    if let channel = pcm.int16ChannelData {
      chunk = Data(bytes: channel[0], count: n * 2)
    } else if let channel = pcm.floatChannelData {
      let samples = (0..<n).map { Int16(max(-1, min(1, channel[0][$0])) * 32767) }
      chunk = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    lock.withLock {
      rate = Int(pcm.format.sampleRate)
      data.append(chunk)
    }
  }

  func collected() -> (Int, Data) { lock.withLock { (rate, data) } }

  /// Main queue only.
  func answer(_ value: Any?) {
    guard !answered else { return }
    answered = true
    result(value)
  }
}

/// The mic's audio, from the IO thread to Dart. `write` copies channel 0 on the IO thread, and a capture thread turns
/// it into 16 kHz mono 320-sample frames. Only the hand-over buffer is shared; the converter and the leftovers
/// belong to the capture thread.
private final class MicCapture {
  private let lock = OSAllocatedUnfairLock()
  private var pending: [Float]  // up to 1 s, handed over under the lock
  private var pendingCount = 0
  private var stopped = false
  private let wake = DispatchSemaphore(value: 0)
  private let rate: Double
  private let converter: AVAudioConverter
  private let input: AVAudioPCMBuffer
  private let onFrame: (Data) -> Void
  private var leftovers: [Int16] = []
  private var logged = false

  init?(rate: Double, onFrame: @escaping (Data) -> Void) {
    guard let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
      let to = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
      let converter = AVAudioConverter(from: from, to: to),
      let input = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(rate))
    else { return nil }
    self.rate = rate
    self.converter = converter
    self.input = input
    self.pending = [Float](repeating: 0, count: Int(rate))
    self.onFrame = onFrame
    let thread = Thread { [self] in run() }  // holds this capture until stop() ends the loop
    thread.name = "vroo_audio mic"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  /// On the IO thread: no allocation, one short lock. Audio that doesn't fit, if the capture thread stalls, is dropped.
  func write(_ data: UnsafePointer<AudioBufferList>, frames: AVAudioFrameCount) {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
    guard let samples = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
    lock.withLock {
      let n = min(Int(frames), pending.count - pendingCount)
      for i in 0..<n { pending[pendingCount + i] = samples[i] }
      pendingCount += n
    }
    wake.signal()
  }

  func stop() {
    lock.withLock { stopped = true }
    wake.signal()
  }

  private func run() {
    while true {
      wake.wait()
      var done = false
      lock.withLock {
        done = stopped
        let n = pendingCount
        if n > 0, let out = input.floatChannelData?[0] {
          pending.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: n) }
        }
        input.frameLength = AVAudioFrameCount(n)
        pendingCount = 0
      }
      if done { return }
      if input.frameLength > 0 { convert() }
    }
  }

  private func convert() {
    if !logged {
      logged = true
      NSLog("vroo_audio: mic in %d-frame pieces at %.0f Hz", Int(input.frameLength), rate)
    }
    let capacity = AVAudioFrameCount(Double(input.frameLength) * 16000 / rate) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
    var fed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if fed {
        status.pointee = .noDataNow
        return nil
      }
      fed = true
      status.pointee = .haveData
      return self.input
    }
    guard error == nil, let samples = out.int16ChannelData else { return }
    leftovers.append(contentsOf: UnsafeBufferPointer(start: samples[0], count: Int(out.frameLength)))
    while leftovers.count >= 320 {
      onFrame(leftovers.prefix(320).withUnsafeBufferPointer { Data(buffer: $0) })
      leftovers.removeFirst(320)
    }
  }
}

/// Up to `capacity` samples waiting to play: `write` drops the oldest on overflow, and `read` gives zeros when empty.
private final class Ring {
  private let lock = OSAllocatedUnfairLock()
  private var samples: [Float]
  private var start = 0
  private var count = 0

  init(capacity: Int) { samples = [Float](repeating: 0, count: capacity) }

  /// int16 little-endian bytes, as `play` sends them.
  func write(_ bytes: Data) {
    bytes.withUnsafeBytes { raw in
      let input = raw.bindMemory(to: Int16.self)
      lock.withLock {
        for s in input {
          if count == samples.count {
            start = (start + 1) % samples.count
            count -= 1
          }
          samples[(start + count) % samples.count] = Float(Int16(littleEndian: s)) / 32768
          count += 1
        }
      }
    }
  }

  func read(into out: UnsafeMutablePointer<Float>, frames: Int) {
    lock.withLock {
      for i in 0..<frames {
        if count > 0 {
          out[i] = samples[start]
          start = (start + 1) % samples.count
          count -= 1
        } else {
          out[i] = 0
        }
      }
    }
  }

  /// Empties it, then queues [primeSamples] of silence.
  func clear(primeSamples: Int) {
    lock.withLock {
      start = 0
      count = min(primeSamples, samples.count)
      for i in 0..<count { samples[i] = 0 }
    }
  }
}

/// Hands an event channel's sink to a closure.
private final class Sink: NSObject, FlutterStreamHandler {
  private let set: (FlutterEventSink?) -> Void

  init(_ set: @escaping (FlutterEventSink?) -> Void) { self.set = set }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    set(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    set(nil)
    return nil
  }
}
