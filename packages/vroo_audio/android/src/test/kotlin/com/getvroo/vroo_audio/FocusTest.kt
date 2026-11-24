// SPDX-License-Identifier: GPL-3.0-or-later
package com.getvroo.vroo_audio

import android.media.AudioManager
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

// Run from packages/vroo_audio/example/android: ./gradlew :vroo_audio:testDebugUnitTest
internal class FocusTest {
    @Test
    fun aNavigationPromptPlaysOverTheGroup() =
        assertNull(interruptionFor(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)) // spec OA1

    @Test
    fun aCallOrAnAssistantInterrupts() = assertEquals(true, interruptionFor(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT))

    @Test
    fun gettingTheAudioBackEndsTheInterruption() = assertEquals(false, interruptionFor(AudioManager.AUDIOFOCUS_GAIN))

    @Test
    fun aMusicAppTakingTheAudioForGoodIsIgnored() = assertNull(interruptionFor(AudioManager.AUDIOFOCUS_LOSS))
}
