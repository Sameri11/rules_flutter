# Keep rules the engine needs under R8. The engine binds native methods by name
# when its library loads, and looks up embedding classes by name from native code.
# The embedding jar ships no consumer rules, so these are carried here.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

-keep class io.flutter.** { *; }

# The package includes the Play Core split-install application, which needs
# optional Play Core classes that are not part of the embedding.
-dontwarn com.google.android.play.core.**

# androidx.window's extension and sidecar classes are optional at runtime; the
# engine's embedding references them without shipping them.
-dontwarn androidx.window.extensions.**
-dontwarn androidx.window.sidecar.**
