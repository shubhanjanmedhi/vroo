// SPDX-License-Identifier: GPL-3.0-or-later
package com.getvroo.vroo_net

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Handler
import android.os.Looper
import android.os.PatternMatcher
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.Executors
import kotlin.concurrent.thread

private const val TAG = "vroo_net"
private const val BOX_IP = "192.168.4.1"
private const val JOIN_TIMEOUT_MS = 60_000

/**
 * Android side of vroo_net; the channel contract is in lib/src/channel_vroo_net.dart. The box's Wi-Fi is
 * requested with a WifiNetworkSpecifier, so it never becomes the default network: box datagrams go over a
 * socket bound to it, and everything else, internet included, stays on mobile data.
 * Network callbacks and method calls both run on the main thread.
 */
class VrooNetPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var connectivity: ConnectivityManager
    private var methods: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private val main by lazy { Handler(Looper.getMainLooper()) }
    private val sender = Executors.newSingleThreadExecutor()
    private val boxAddress: InetAddress by lazy { InetAddress.getByName(BOX_IP) }

    private var callback: ConnectivityManager.NetworkCallback? = null
    private var failPendingJoin: (() -> Unit)? = null
    private var socket: DatagramSocket? = null
    private var joinedSsid: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        connectivity = binding.applicationContext.getSystemService(ConnectivityManager::class.java)
        methods = MethodChannel(binding.binaryMessenger, "vroo_net").apply { setMethodCallHandler(this@VrooNetPlugin) }
        eventChannel = EventChannel(binding.binaryMessenger, "vroo_net/events").apply { setStreamHandler(this@VrooNetPlugin) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        leave()
        methods?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        sender.shutdown()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(event: Map<String, Any>) {
        main.post { sink?.success(event) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "joinBox" -> {
                val ssid = call.argument<String>("ssid")!!
                if (ssid == joinedSsid && socket != null) {
                    // Already on it: a new request would make Android prompt the rider again.
                    emit(mapOf("kind" to "boxNetwork", "available" to true))
                    result.success("joined")
                    return
                }
                val spec = WifiNetworkSpecifier.Builder().setSsid(ssid)
                call.argument<String>("password")?.let { spec.setWpa2Passphrase(it) }
                join(spec.build(), result, ssid)
            }
            "joinSetupNetwork" -> join(
                WifiNetworkSpecifier.Builder()
                    .setSsidPattern(PatternMatcher("Vroo-setup-", PatternMatcher.PATTERN_PREFIX))
                    .build(),
                result,
                null,
            )
            "leaveBox" -> {
                leave()
                result.success(null)
            }
            "sendToBox" -> sendToBox(call.argument<Int>("port")!!, call.argument<ByteArray>("data")!!, result)
            else -> result.notImplemented()
        }
    }

    private fun join(specifier: WifiNetworkSpecifier, result: MethodChannel.Result, ssid: String?) {
        leave()
        joinedSsid = ssid
        var answered = false
        val answer = { outcome: String ->
            if (!answered) {
                answered = true
                result.success(outcome)
            }
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val s = runCatching { DatagramSocket(0) }.getOrNull()
                if (s == null || runCatching { network.bindSocket(s) }.isFailure) {
                    s?.close()
                    answer("failed")
                    return
                }
                socket?.close()
                socket = s
                read(s)
                emit(mapOf("kind" to "boxNetwork", "available" to true))
                answer("joined")
            }

            override fun onUnavailable() = answer("denied") // the rider declined, or 60 s passed

            override fun onLost(network: Network) {
                socket?.close()
                socket = null
                emit(mapOf("kind" to "boxNetwork", "available" to false))
            }
        }
        callback = cb
        failPendingJoin = { answer("failed") }
        connectivity.requestNetwork(request, cb, main, JOIN_TIMEOUT_MS)
    }

    private fun leave() {
        failPendingJoin?.invoke()
        failPendingJoin = null
        callback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        callback = null
        joinedSsid = null
        if (socket != null) emit(mapOf("kind" to "boxNetwork", "available" to false))
        socket?.close()
        socket = null
    }

    private fun read(s: DatagramSocket) {
        thread(name = "vroo_net box", isDaemon = true) {
            val buf = ByteArray(2048)
            while (true) {
                val p = DatagramPacket(buf, buf.size)
                try {
                    s.receive(p)
                } catch (e: IOException) {
                    break // the socket was closed
                }
                if (p.address == boxAddress) emit(mapOf("kind" to "box", "fromPort" to p.port, "data" to buf.copyOf(p.length)))
            }
        }
    }

    // Fire and forget, like any UDP send: with no box joined, or if the send fails, the datagram is lost.
    private fun sendToBox(port: Int, data: ByteArray, result: MethodChannel.Result) {
        result.success(null)
        val s = socket ?: return
        sender.execute {
            runCatching { s.send(DatagramPacket(data, data.size, boxAddress, port)) }
                .onFailure { Log.w(TAG, "box send failed: ${it.message}") }
        }
    }
}
