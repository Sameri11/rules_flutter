package com.example.recipe_plugin

import io.flutter.embedding.engine.plugins.FlutterPlugin

@androidx.annotation.RequiresOptIn
private annotation class ExperimentalRecipeApi

@ExperimentalRecipeApi
class RecipePlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
