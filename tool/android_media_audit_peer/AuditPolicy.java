package com.fluentplayer.audit.controls;

import android.media.AudioManager;
import android.view.KeyEvent;
import java.nio.charset.StandardCharsets;

/** Pure constraints, also executed on the build machine without an Android device. */
final class AuditPolicy {
    static final String PACKAGE = "com.fluentplayer.audit.controls";
    static final String TARGET_PACKAGE = "com.example.video_player_app.sidebar_profile";
    static final String TARGET_RECEIVER = "com.ryanheise.audioservice.MediaButtonReceiver";
    static final String TARGET = TARGET_PACKAGE + "/" + TARGET_RECEIVER;
    static final int DEFAULT_HOLD_SECONDS = 5;
    static final int MAX_HOLD_SECONDS = 30;
    static final int MAX_TEXT_UTF8_BYTES = 64 * 1024;

    private AuditPolicy() {}

    static void requireTarget(String component, String packageName, String receiver) {
        if ((component != null && !TARGET.equals(component)) ||
            (packageName != null && !TARGET_PACKAGE.equals(packageName)) ||
            (receiver != null && !TARGET_RECEIVER.equals(receiver))) {
            throw new IllegalArgumentException("Only the isolated sidebar_profile receiver is permitted");
        }
    }

    static int mediaKey(String command) {
        if (command == null) throw new IllegalArgumentException("command is required");
        switch (command) {
            case "play": return KeyEvent.KEYCODE_MEDIA_PLAY;
            case "pause": return KeyEvent.KEYCODE_MEDIA_PAUSE;
            case "next": return KeyEvent.KEYCODE_MEDIA_NEXT;
            case "previous": return KeyEvent.KEYCODE_MEDIA_PREVIOUS;
            case "play_pause": return KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE;
            default: throw new IllegalArgumentException("Unsupported command: " + command);
        }
    }

    static int focusGain(String mode) {
        if ("transient".equals(mode)) return AudioManager.AUDIOFOCUS_GAIN_TRANSIENT;
        if ("gain".equals(mode)) return AudioManager.AUDIOFOCUS_GAIN;
        throw new IllegalArgumentException("mode must be transient or gain");
    }

    static int holdSeconds(int seconds) {
        if (seconds < 1 || seconds > MAX_HOLD_SECONDS) {
            throw new IllegalArgumentException("hold_seconds must be between 1 and 30");
        }
        return seconds;
    }

    static String uiDumpFilename(String filename) {
        if (filename == null) return "latest.xml";
        if (!filename.matches("[A-Za-z0-9]{1,64}\\.xml")) {
            throw new IllegalArgumentException("filename must be an ASCII alphanumeric basename ending in .xml");
        }
        return filename;
    }

    static byte[] textInputBytes(String text) {
        if (text == null) throw new IllegalArgumentException("text is required");
        if (text.length() > MAX_TEXT_UTF8_BYTES) throw new IllegalArgumentException("text exceeds the 64KiB UTF-8 limit");
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        if (bytes.length > MAX_TEXT_UTF8_BYTES) throw new IllegalArgumentException("text exceeds the 64KiB UTF-8 limit");
        return bytes;
    }

    static void requireTextInputPackage(String packageName) {
        if (!TARGET_PACKAGE.equals(packageName)) {
            throw new IllegalArgumentException("Active root must be exactly " + TARGET_PACKAGE);
        }
    }
}
