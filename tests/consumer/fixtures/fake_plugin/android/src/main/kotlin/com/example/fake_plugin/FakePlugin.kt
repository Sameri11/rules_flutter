package com.example.fake_plugin

import androidx.annotation.experimental.Experimental
import io.flutter.embedding.engine.plugins.FlutterPlugin

/** Minimal plugin fixture: registers and does nothing else. */
class FakePlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}

// Use the annotation so the Maven dependency reaches compilation.
@Experimental
annotation class FakeExperimentalMarker
