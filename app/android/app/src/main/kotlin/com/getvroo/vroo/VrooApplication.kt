// SPDX-License-Identifier: GPL-3.0-or-later
package com.getvroo.vroo

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Starts the app's FlutterEngine with the process and keeps it in the cache. The activity then borrows it instead
 * of owning it, so swiping the app away from recents doesn't end a ride: the engine, and the ride with it, carries
 * on under vroo_audio's foreground service (architecture §4.1).
 */
class VrooApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }

    companion object {
        const val ENGINE_ID = "main"
    }
}
