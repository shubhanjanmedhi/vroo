// SPDX-License-Identifier: GPL-3.0-or-later
package com.getvroo.vroo_audio

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull

// Run from packages/vroo_audio/example/android: ./gradlew :vroo_audio:testDebugUnitTest
internal class WavTest {
    /** A RIFF/WAVE file holding [chunks] in order, each padded to an even length. */
    private fun wav(vararg chunks: Pair<String, ByteArray>): ByteArray {
        val body = chunks.sumOf { 8 + it.second.size + it.second.size % 2 }
        val b = ByteBuffer.allocate(12 + body).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt(4 + body).put("WAVE".toByteArray())
        for ((id, data) in chunks) {
            b.put(id.toByteArray()).putInt(data.size).put(data)
            if (data.size % 2 == 1) b.put(0)
        }
        return b.array()
    }

    private fun fmt(format: Int, channels: Int, rate: Int, bits: Int): ByteArray =
        ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(format.toShort()).putShort(channels.toShort()).putInt(rate)
            .putInt(rate * channels * bits / 8).putShort((channels * bits / 8).toShort()).putShort(bits.toShort())
            .array()

    private fun samples(vararg s: Int): ByteArray =
        ByteBuffer.allocate(s.size * 2).order(ByteOrder.LITTLE_ENDIAN).apply { s.forEach { putShort(it.toShort()) } }
            .array()

    @Test
    fun `parses 16-bit mono PCM and skips a LIST chunk`() {
        val (rate, pcm) = Wav.parse(wav("fmt " to fmt(1, 1, 22050, 16), "LIST" to ByteArray(5), "data" to samples(1, -2, 300)))!!
        assertEquals(22050, rate)
        assertContentEquals(shortArrayOf(1, -2, 300), pcm)
    }

    @Test
    fun `mixes stereo down to mono`() {
        val (_, pcm) = Wav.parse(wav("fmt " to fmt(1, 2, 16000, 16), "data" to samples(100, 300, -50, -150)))!!
        assertContentEquals(shortArrayOf(200, -100), pcm)
    }

    @Test
    fun `returns null for non-PCM data`() {
        assertNull(Wav.parse(wav("fmt " to fmt(3, 1, 16000, 32), "data" to ByteArray(8)))) // 32-bit float
        assertNull(Wav.parse(wav("data" to samples(1, 2)))) // no fmt chunk before the data
        assertNull(Wav.parse("not a wav file".toByteArray()))
    }
}
