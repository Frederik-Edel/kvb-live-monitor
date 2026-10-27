package com.example.kvb_live_monitor

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.kvb_live_monitor/widget",
        ).setMethodCallHandler { call, result ->
            if (call.method != "updateWidget") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val stationName = call.argument<String>("stationName")
                ?: "KVB Abfahrten"
            val departures = call.argument<List<Map<String, Any>>>("departures")
                ?: emptyList()
            KvbDeparturesWidgetProvider.update(this, stationName, departures)
            result.success(null)
        }
    }
}
