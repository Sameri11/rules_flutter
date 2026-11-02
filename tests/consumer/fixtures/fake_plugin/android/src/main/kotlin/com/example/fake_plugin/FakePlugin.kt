package com.example.fake_plugin

import androidx.annotation.experimental.Experimental
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Minimal plugin fixture with one runtime method for consumer shrink tests. */
class FakePlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "fake_plugin").also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                if (call.method == "ping") {
                    result.success("plugin-runtime-ok")
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}

// Use the annotation so the Maven dependency reaches compilation.
@Experimental
annotation class FakeExperimentalMarker
