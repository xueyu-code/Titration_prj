package com.lab.titrator_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Counterpart of lib/data/foreground_service.dart.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "titrator/foreground_service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> try {
                        TitrationService.start(this, call.argument("title"), call.argument("text"))
                        result.success(null)
                    } catch (e: RuntimeException) {
                        result.error("start_failed", e.message, null)
                    }
                    "stop" -> {
                        TitrationService.stop(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
