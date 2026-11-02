package com.example.fake_plugin

import androidx.annotation.experimental.Experimental
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Minimal plugin fixture for consumer shrink-rule runtime coverage. */
class FakePlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "fake_plugin").also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                if (call.method != "ping") {
                    result.notImplemented()
                } else {
                    val className = call.arguments as? String
                    if (className == null) {
                        result.error("missing-class-name", "Expected a class name", null)
                    } else {
                        try {
                            val probe = Class.forName(className).getDeclaredConstructor().newInstance()
                            val message = probe.javaClass.getMethod("message").invoke(probe) as String
                            result.success(message)
                        } catch (error: ReflectiveOperationException) {
                            result.error("missing-consumer-rule", error.message, null)
                        }
                    }
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
