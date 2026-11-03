# The public Flutter framework and plugin registrant are not proprietary app
# logic. Preserve their dynamic engine/plugin entry points.
-keep class io.flutter.**  { *; }

# FFmpegKit
-keep class com.arthenica.ffmpegkit.** { *; }
-keep class com.arthenica.smartexception.** { *; }

# MediaNotificationGate accesses these exact names via reflection. Keeping
# only the manifest class would not retain the privately reflected fields.
-keep class com.ryanheise.audioservice.AudioService {
    static com.ryanheise.audioservice.AudioService instance;
    boolean playing;
    boolean notificationCreated;
    android.support.v4.media.session.MediaSessionCompat mediaSession;
}

# Chaquopy invokes these callbacks by name from Python, outside R8's call graph.
# Class names may still be obfuscated, but the Python-facing methods may not.
-keepclassmembers class com.example.video_player_app.** {
    public void onOutputLine(java.lang.String);
    public void onProgress(java.lang.String);
    public boolean isCancelled();
}

# The ASR JNI implementation exports this class/method name directly.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}


# Google Play Core (Flutter Deferred Components)
# Fixes R8: Missing class com.google.android.play.core.splitcompat.SplitCompatApplication etc.
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
