package com.example.att

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    private var deviceKeyPlugin: DeviceKeyPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        deviceKeyPlugin = DeviceKeyPlugin(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        deviceKeyPlugin?.dispose()
        deviceKeyPlugin = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
