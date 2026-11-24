// SPDX-License-Identifier: GPL-3.0-or-later
package com.getvroo.vroo_audio

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Reads the 16-bit PCM WAV files that Android's text-to-speech writes. */
internal object Wav {
    /** (sample rate, mono samples), or null unless [bytes] is a RIFF/WAVE file of 16-bit PCM. Stereo is mixed down. */
    fun parse(bytes: ByteArray): Pair<Int, ShortArray>? {
        if (bytes.size < 12 || tag(bytes, 0) != "RIFF" || tag(bytes, 8) != "WAVE") return null
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        var at = 12
        var rate = 0
        var channels = 0
        while (at + 8 <= bytes.size) {
            val size = b.getInt(at + 4)
            val start = at + 8
            if (size < 0) return null
            when (tag(bytes, at)) {
                "fmt " -> {
                    if (size < 16 || start + 16 > bytes.size) return null
                    if (b.getShort(start).toInt() != 1 || b.getShort(start + 14).toInt() != 16) return null // PCM, 16-bit
                    channels = b.getShort(start + 2).toInt()
                    rate = b.getInt(start + 4)
                    if (channels !in 1..2 || rate <= 0) return null
                }
                "data" -> {
                    if (rate == 0) return null // no fmt chunk before the data
                    val frames = minOf(size, bytes.size - start) / (2 * channels)
                    return rate to ShortArray(frames) { i ->
                        if (channels == 1) {
                            b.getShort(start + i * 2)
                        } else {
                            ((b.getShort(start + i * 4) + b.getShort(start + i * 4 + 2)) / 2).toShort()
                        }
                    }
                }
            }
            at = start + size + size % 2 // chunks are padded to an even length
        }
        return null
    }

    private fun tag(bytes: ByteArray, at: Int) = String(bytes, at, 4, Charsets.US_ASCII)
}
