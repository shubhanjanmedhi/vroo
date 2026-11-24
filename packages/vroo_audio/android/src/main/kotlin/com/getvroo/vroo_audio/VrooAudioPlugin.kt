// SPDX-License-Identifier: GPL-3.0-or-later
package com.getvroo.vroo_audio

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.telephony.PhoneStateListener
import android.telephony.TelephonyManager
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

private const val TAG = "vroo_audio"
private const val RATE = 16000
private const val FRAME = 320 // 20 ms
private const val SCO_WAIT_MS = 3000L
private const val SPEECH_TIMEOUT_MS = 10_000L

/**
 * Android side of vroo_audio; the channel contract is in lib/src/channel_vroo_audio.dart. Voice runs as a call-style
 * stream (MODE_IN_COMMUNICATION, routed to the intercom's SCO link), so the phone's own calls still ring and take
 * over as usual; the group is never registered as a call (D7). Method calls, callbacks and events run on the main
 * thread; only the mic reader has its own.
 */
class VrooAudioPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var audio: AudioManager
    private var methods: MethodChannel? = null
    private var micChannel: EventChannel? = null
    private var eventChannel: EventChannel? = null
    private var playChannel: BasicMessageChannel<ByteBuffer>? = null
    private var micSink: EventChannel.EventSink? = null
    private var eventSink: EventChannel.EventSink? = null
    private val main by lazy { Handler(Looper.getMainLooper()) }

    @Volatile private var running = false
    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    private var reader: Thread? = null
    private val effects = mutableListOf<AudioEffect>()
    private var focus: AudioFocusRequest? = null
    private var callState = "idle"
    private var scoWaiting = false
    private var scoReceiverRegistered = false
    private var resumeTries = 0

    private var tts: TextToSpeech? = null
    private var ttsReady: Boolean? = null // null until the engine has started
    private val waitingForTts = mutableListOf<() -> Unit>()
    private val speechDone = ConcurrentHashMap<String, (Boolean) -> Unit>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        audio = context.getSystemService(AudioManager::class.java)
        val messenger = binding.binaryMessenger
        methods = MethodChannel(messenger, "vroo_audio").apply { setMethodCallHandler(this@VrooAudioPlugin) }
        micChannel = EventChannel(messenger, "vroo_audio/mic").apply { setStreamHandler(sinkFor { micSink = it }) }
        eventChannel = EventChannel(messenger, "vroo_audio/events").apply { setStreamHandler(sinkFor { eventSink = it }) }
        playChannel = BasicMessageChannel(messenger, "vroo_audio/play", BinaryCodec.INSTANCE).apply {
            setMessageHandler { message, reply ->
                message?.let(::play)
                reply.reply(null)
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        tts?.shutdown()
        tts = null
        methods?.setMethodCallHandler(null)
        micChannel?.setStreamHandler(null)
        eventChannel?.setStreamHandler(null)
        playChannel?.setMessageHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> result.success(start(call.argument<String>("notificationText") ?: "Riding"))
            "stop" -> {
                stop()
                result.success(null)
            }
            "restart" -> {
                restartStreams()
                result.success(null)
            }
            "synthesize" -> synthesize(call.argument<String>("text") ?: "", result)
            else -> result.notImplemented()
        }
    }

    private fun sinkFor(set: (EventChannel.EventSink?) -> Unit) = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) = set(events)
        override fun onCancel(arguments: Any?) = set(null)
    }

    private fun emit(event: Map<String, Any>) = eventSink?.success(event)

    // ---- Start and stop ----

    private fun start(notificationText: String): String {
        if (running) return "started"
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return "micDenied"
        }
        return try {
            requestFocus()
            audio.mode = AudioManager.MODE_IN_COMMUNICATION
            listenForCalls()
            audio.registerAudioDeviceCallback(deviceCallback, main)
            if (Build.VERSION.SDK_INT >= 31) {
                audio.addOnCommunicationDeviceChangedListener(context.mainExecutor, communicationDeviceListener)
            } else {
                context.registerReceiver(scoReceiver, IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED))
                scoReceiverRegistered = true
            }
            startStreams()
            route()
            // Last: once the service is asked to start it must reach startForeground, and a stop before that crashes
            // the app. The app is in the foreground here, so the mic may open first.
            RideService.start(context, notificationText)
            "started"
        } catch (e: Exception) {
            Log.e(TAG, "start failed", e)
            stop()
            "failed"
        }
    }

    private fun stop() {
        stopStreams()
        focus?.let { audio.abandonAudioFocusRequest(it) }
        focus = null
        stopListeningForCalls()
        runCatching { audio.unregisterAudioDeviceCallback(deviceCallback) }
        if (Build.VERSION.SDK_INT >= 31) {
            runCatching { audio.removeOnCommunicationDeviceChangedListener(communicationDeviceListener) }
            audio.clearCommunicationDevice()
        } else {
            stopLegacyRouting()
        }
        main.removeCallbacks(resume)
        audio.mode = AudioManager.MODE_NORMAL
        callState = "idle"
        RideService.stop(context)
    }

    // ---- Audio in and out ----

    /** Dart saw the mic go quiet: new mic and playback streams, keeping the service, focus and routing. */
    private fun restartStreams() {
        if (!running) return
        stopStreams()
        try {
            startStreams()
            route()
        } catch (e: Exception) {
            Log.w(TAG, "restart failed", e)
            emit(mapOf("type" to "failed", "message" to "the microphone didn't come back"))
        }
    }

    private fun stopStreams() {
        running = false
        record?.let { r -> runCatching { r.stop() } }
        reader?.join(500)
        reader = null
        record?.release()
        record = null
        track?.let { t -> runCatching { t.stop() }; t.release() }
        track = null
        effects.forEach { it.release() }
        effects.clear()
    }

    private fun startStreams() {
        val minRecord = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minRecord, FRAME * 2 * 4),
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IllegalStateException("the microphone didn't open")
        }
        if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(rec.audioSessionId)?.let { it.enabled = true; effects += it }
        if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(rec.audioSessionId)?.let { it.enabled = true; effects += it }
        val minTrack = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val trk = AudioTrack.Builder()
            .setAudioAttributes(voiceAttributes())
            .setAudioFormat(
                AudioFormat.Builder().setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build(),
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(maxOf(minTrack, RATE * 2 / 5)) // 200 ms
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
        trk.write(ShortArray(FRAME * 2), 0, FRAME * 2, AudioTrack.WRITE_NON_BLOCKING) // 40 ms of silence
        trk.play()
        rec.startRecording()
        record = rec
        track = trk
        running = true
        reader = thread(name = "vroo_audio mic") {
            val frame = ShortArray(FRAME)
            while (running) {
                var got = 0
                while (got < FRAME && running) {
                    val n = rec.read(frame, got, FRAME - got)
                    if (n < 0) break // stopped, or the mic was taken away
                    got += n
                }
                if (got == FRAME) {
                    val bytes = bytesOf(frame)
                    main.post { micSink?.success(bytes) }
                } else if (running) {
                    Thread.sleep(20)
                }
            }
        }
    }

    /** Whatever doesn't fit in the track's buffer is dropped, so playback never falls behind. */
    private fun play(message: ByteBuffer) {
        val trk = track ?: return
        val samples = ShortArray(message.remaining() / 2)
        message.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(samples)
        trk.write(samples, 0, samples.size, AudioTrack.WRITE_NON_BLOCKING)
    }

    private fun voiceAttributes() = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    private fun requestFocus() {
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(voiceAttributes())
            .setOnAudioFocusChangeListener(focusListener, main)
            .build()
        audio.requestAudioFocus(request)
        focus = request
    }

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        interruptionFor(change)?.let { emit(mapOf("type" to "interruption", "began" to it)) }
    }

    // ---- Routing: the intercom first, then a wired headset, then the loudspeaker (VO5) ----

    private fun route() {
        if (!running) return
        if (Build.VERSION.SDK_INT >= 31) {
            val available = audio.availableCommunicationDevices
            val pick = listOf(
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                AudioDeviceInfo.TYPE_BLE_HEADSET,
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_USB_HEADSET,
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            ).firstNotNullOfOrNull { type -> available.firstOrNull { it.type == type } }
            if (pick != null && audio.communicationDevice?.id != pick.id) audio.setCommunicationDevice(pick)
            emitRoute()
        } else {
            routeLegacy()
        }
    }

    @Suppress("DEPRECATION")
    private fun routeLegacy() {
        if (hasOutput(AudioDeviceInfo.TYPE_BLUETOOTH_SCO) && audio.isBluetoothScoAvailableOffCall) {
            if (audio.isBluetoothScoOn) return emitRoute()
            if (!scoWaiting) {
                scoWaiting = true
                audio.isSpeakerphoneOn = false
                audio.startBluetoothSco()
                main.postDelayed(scoTimeout, SCO_WAIT_MS)
            }
        } else {
            useSpeakerUnlessWired()
        }
    }

    @Suppress("DEPRECATION")
    private fun useSpeakerUnlessWired() {
        audio.isSpeakerphoneOn = !hasOutput(
            AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET,
        )
        emitRoute()
    }

    private val scoTimeout = Runnable {
        scoWaiting = false
        useSpeakerUnlessWired()
    }

    @Suppress("DEPRECATION")
    private val scoReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            when (intent.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, -1)) {
                AudioManager.SCO_AUDIO_STATE_CONNECTED -> {
                    scoWaiting = false
                    main.removeCallbacks(scoTimeout)
                    audio.isBluetoothScoOn = true
                    emitRoute()
                }
                AudioManager.SCO_AUDIO_STATE_DISCONNECTED -> if (!scoWaiting && running) route()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun stopLegacyRouting() {
        scoWaiting = false
        main.removeCallbacks(scoTimeout)
        if (scoReceiverRegistered) runCatching { context.unregisterReceiver(scoReceiver) }
        scoReceiverRegistered = false
        audio.stopBluetoothSco()
        audio.isBluetoothScoOn = false
        audio.isSpeakerphoneOn = false
    }

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = route()
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = route()
    }

    private val communicationDeviceListener by lazy {
        AudioManager.OnCommunicationDeviceChangedListener { emitRoute() }
    }

    private fun hasOutput(vararg types: Int) =
        audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in types }

    /** Android doesn't say which rate the SCO link runs at, so the route's rate is 0 (unknown). */
    @Suppress("DEPRECATION")
    private fun emitRoute() {
        val device = if (Build.VERSION.SDK_INT >= 31) audio.communicationDevice else null
        val output = when {
            device != null -> outputName(device.type)
            audio.isBluetoothScoOn -> "bluetooth"
            hasOutput(AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES) -> "wired"
            audio.isSpeakerphoneOn -> "speaker"
            else -> "earpiece"
        }
        val name = device?.productName?.toString()
            ?: audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { outputName(it.type) == output }
                ?.productName?.toString()
            ?: ""
        emit(mapOf("type" to "route", "output" to output, "name" to name, "rate" to 0))
    }

    private fun outputName(type: Int) = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET -> "bluetooth"
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET -> "wired"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        else -> "other"
    }

    // ---- The phone's own calls ----

    private val modeListener by lazy {
        AudioManager.OnModeChangedListener { mode ->
            when (mode) {
                AudioManager.MODE_RINGTONE -> onCall("ringing")
                AudioManager.MODE_IN_CALL, AudioManager.MODE_CALL_SCREENING, AudioManager.MODE_CALL_REDIRECT ->
                    onCall("active")
                else -> if (callState != "idle") onCall("idle")
            }
        }
    }

    @Suppress("DEPRECATION")
    private val phoneListener by lazy {
        object : PhoneStateListener() {
            @Deprecated("Android 10 and 11 only")
            override fun onCallStateChanged(state: Int, phoneNumber: String?) = onCall(
                when (state) {
                    TelephonyManager.CALL_STATE_RINGING -> "ringing"
                    TelephonyManager.CALL_STATE_OFFHOOK -> "active"
                    else -> "idle"
                },
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun listenForCalls() {
        if (Build.VERSION.SDK_INT >= 31) {
            audio.addOnModeChangedListener(context.mainExecutor, modeListener)
        } else {
            try {
                context.getSystemService(TelephonyManager::class.java).listen(phoneListener, PhoneStateListener.LISTEN_CALL_STATE)
            } catch (e: SecurityException) {
                Log.w(TAG, "call detection needs the phone permission", e)
                emit(mapOf("type" to "failed", "message" to "call detection needs the phone permission"))
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun stopListeningForCalls() {
        if (Build.VERSION.SDK_INT >= 31) {
            runCatching { audio.removeOnModeChangedListener(modeListener) }
        } else {
            runCatching {
                context.getSystemService(TelephonyManager::class.java).listen(phoneListener, PhoneStateListener.LISTEN_NONE)
            }
        }
    }

    private fun onCall(state: String) {
        if (state == callState) return
        val endedCall = state == "idle"
        callState = state
        emit(mapOf("type" to "call", "state" to state))
        if (endedCall && running) {
            resumeTries = 0
            main.removeCallbacks(resume)
            main.post(resume)
        }
    }

    /** After a call: our mode and route again, and the streams if the call stopped them. Every 500 ms for 2 s, then every 2 s. */
    private val resume: Runnable = object : Runnable {
        override fun run() {
            if (!running || callState != "idle") return
            try {
                if (audio.mode != AudioManager.MODE_IN_COMMUNICATION) audio.mode = AudioManager.MODE_IN_COMMUNICATION
                route()
                record?.let { if (it.recordingState != AudioRecord.RECORDSTATE_RECORDING) it.startRecording() }
                track?.let { if (it.playState != AudioTrack.PLAYSTATE_PLAYING) it.play() }
                if (audio.mode == AudioManager.MODE_IN_COMMUNICATION &&
                    record?.recordingState == AudioRecord.RECORDSTATE_RECORDING
                ) {
                    return
                }
            } catch (e: Exception) {
                Log.w(TAG, "resume after the call", e)
            }
            resumeTries++
            main.postDelayed(this, if (resumeTries < 4) 500 else 2000)
        }
    }

    // ---- Speech: the phone's own voice, written to a WAV file and sent back as PCM ----

    private fun synthesize(text: String, result: MethodChannel.Result) {
        val job = { speakToFile(text, result) }
        when (ttsReady) {
            true, false -> job()
            null -> {
                waitingForTts += job
                if (tts == null) {
                    tts = TextToSpeech(context) { status -> main.post { onTtsStarted(status == TextToSpeech.SUCCESS) } }
                }
            }
        }
    }

    private fun onTtsStarted(ok: Boolean) {
        val engine = tts
        ttsReady = ok && engine != null
        if (ttsReady == true && engine != null) {
            val india = Locale.forLanguageTag("en-IN")
            engine.language = if (engine.isLanguageAvailable(india) >= TextToSpeech.LANG_AVAILABLE) india else Locale.ENGLISH
            engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String) {}
                override fun onDone(utteranceId: String) {
                    speechDone.remove(utteranceId)?.invoke(true)
                }
                @Deprecated("Deprecated in Android")
                override fun onError(utteranceId: String) {
                    speechDone.remove(utteranceId)?.invoke(false)
                }
                override fun onError(utteranceId: String, errorCode: Int) {
                    speechDone.remove(utteranceId)?.invoke(false)
                }
            })
        }
        waitingForTts.toList().forEach { it() }
        waitingForTts.clear()
    }

    private fun speakToFile(text: String, result: MethodChannel.Result) {
        val engine = tts
        if (ttsReady != true || engine == null) return result.error("speech", "no speech engine", null)
        val id = "vroo-${System.nanoTime()}"
        val file = File(context.cacheDir, "$id.wav")
        var answered = false
        fun answer(block: () -> Unit) {
            if (!answered) {
                answered = true
                block()
            }
        }
        val timeout = Runnable {
            speechDone.remove(id)
            answer { result.error("speech", "no speech within 10 s", null) }
            file.delete()
        }
        speechDone[id] = { ok ->
            main.post {
                main.removeCallbacks(timeout)
                val wav = if (ok && file.exists()) Wav.parse(file.readBytes()) else null
                file.delete()
                answer {
                    if (wav == null) {
                        result.error("speech", "the speech engine failed", null)
                    } else {
                        result.success(mapOf("rate" to wav.first, "pcm" to bytesOf(wav.second)))
                    }
                }
            }
        }
        main.postDelayed(timeout, SPEECH_TIMEOUT_MS)
        if (engine.synthesizeToFile(text, null, file, id) != TextToSpeech.SUCCESS) {
            speechDone.remove(id)
            main.removeCallbacks(timeout)
            answer { result.error("speech", "the speech engine refused", null) }
        }
    }

    private fun bytesOf(samples: ShortArray): ByteArray {
        val b = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        b.asShortBuffer().put(samples)
        return b.array()
    }
}

/**
 * What an audio-focus change means for the ride: true begins an interruption, false ends it, null changes nothing.
 * A call or an assistant takes the audio for a while. A ducking request is a navigation prompt: Android doesn't duck
 * speech for us, so the prompt plays over the group (spec OA1). A permanent loss (a music app) is ignored.
 */
internal fun interruptionFor(change: Int): Boolean? = when (change) {
    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> true
    AudioManager.AUDIOFOCUS_GAIN -> false
    else -> null
}
