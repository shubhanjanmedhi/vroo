// SPDX-License-Identifier: GPL-3.0-or-later
package com.getvroo.vroo_net

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

// Run from packages/vroo_net/example/android: ./gradlew :vroo_net:testDebugUnitTest
internal class VrooNetPluginTest {
    private fun call(method: String, args: Any?): MethodChannel.Result {
        val result = Mockito.mock(MethodChannel.Result::class.java)
        VrooNetPlugin().onMethodCall(MethodCall(method, args), result)
        return result
    }

    @Test
    fun sendToBox_beforeAnyBoxIsJoined_dropsTheDatagram() {
        Mockito.verify(call("sendToBox", mapOf("port" to 47000, "data" to ByteArray(4)))).success(null)
    }

    @Test
    fun unknownMethods_areNotImplemented() {
        Mockito.verify(call("getPlatformVersion", null)).notImplemented()
    }
}
