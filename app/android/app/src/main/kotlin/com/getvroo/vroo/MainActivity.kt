// SPDX-License-Identifier: GPL-3.0-or-later
package com.getvroo.vroo

import io.flutter.embedding.android.FlutterActivity

/** Uses the engine VrooApplication keeps, which outlives this activity. */
class MainActivity : FlutterActivity() {
    override fun getCachedEngineId(): String = VrooApplication.ENGINE_ID
}
