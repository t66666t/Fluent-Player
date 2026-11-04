package com.fluentplayer.audit.controls;

import android.app.Activity;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.widget.TextView;
import java.io.IOException;
import org.json.JSONObject;

/** A visible, silent focus peer: no player, FGS, network, global keys or app kills. */
public final class AuditFocusActivity extends Activity {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final AudioManager.OnAudioFocusChangeListener listener = change ->
        record("peer-focus-change", AuditReceipt.object("change", change));
    private TextView output;
    private AuditReceipt receipt;
    private AudioManager audio;
    // Keep API26 types in the guarded helper so the API24 Activity has no newer
    // framework type in its fields or method signatures.
    private Object request;
    private boolean attempted;
    private boolean ended;
    private int gain;
    private int seconds;
    private long requestedAt;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        output = new TextView(this);
        output.setPadding(24, 36, 24, 24);
        setContentView(output);
        try {
            receipt = new AuditReceipt(this, "foreground-audio-focus");
            if (state != null) throw new IllegalArgumentException("Restored Activity must not replay a focus request");
            Intent intent = getIntent();
            String mode = intent.hasExtra("mode") ? intent.getStringExtra("mode") : "transient";
            gain = AuditPolicy.focusGain(mode);
            seconds = AuditPolicy.holdSeconds(readHoldSeconds(intent));
            if (!record("prepared", AuditReceipt.object("mode", mode, "gain", gain, "holdSeconds", seconds,
                    "silent", true, "finishOnCompletion", true))) {
                ended = true;
                finish();
                return;
            }
            output.setText("Waiting for the audit window to become foreground.\nMode: " + mode +
                "\nHold: " + seconds + " seconds\nSilent peer; no audio or foreground service.\nReceipt: " + receipt.file);
        } catch (Exception error) {
            record("rejected", AuditReceipt.object("error", error.toString()));
            Log.e(AuditReceipt.TAG, "Focus request rejected", error);
            ended = true;
            finish();
        }
    }

    @Override public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus && !attempted && !ended) requestFocus();
    }

    @SuppressWarnings("deprecation")
    private static int readHoldSeconds(Intent intent) {
        if (!intent.hasExtra("hold_seconds")) return AuditPolicy.DEFAULT_HOLD_SECONDS;
        Object value = intent.getExtras().get("hold_seconds");
        if (!(value instanceof Integer)) throw new IllegalArgumentException("hold_seconds must be an integer");
        return (Integer)value;
    }

    @SuppressWarnings("deprecation")
    private void requestFocus() {
        try {
            if (!record("request-start", AuditReceipt.object("windowHasFocus", hasWindowFocus(), "gain", gain))) {
                finishAudit("receipt-failed-before-request", true);
                return;
            }
            audio = (AudioManager)getSystemService(AUDIO_SERVICE);
            requestedAt = SystemClock.elapsedRealtime();
            attempted = true;
            int result;
            if (Build.VERSION.SDK_INT >= 26) {
                request = Api26.create(gain, listener, handler);
                result = Api26.request(audio, request);
            } else {
                result = audio.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, gain);
            }
            boolean granted = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
            if (!record("request-result", AuditReceipt.object("result", result, "granted", granted,
                    "holdSeconds", seconds, "deadlineElapsedRealtimeMs", requestedAt + seconds * 1000L))) {
                finishAudit("receipt-failed-after-request", true);
                return;
            }
            if (!granted) {
                finishAudit("request-not-granted", true);
                return;
            }
            output.setText("Silent audit peer holds focus for " + seconds + " seconds.\nReceipt: " + receipt.file);
            handler.postDelayed(() -> finishAudit("hold-completed", true), seconds * 1000L);
        } catch (Exception error) {
            record("request-error", AuditReceipt.object("error", error.toString()));
            Log.e(AuditReceipt.TAG, "Focus request failed", error);
            finishAudit("request-error", true);
        }
    }

    @SuppressWarnings("deprecation")
    private void finishAudit(String reason, boolean closeActivity) {
        if (ended) return;
        ended = true;
        handler.removeCallbacksAndMessages(null);
        if (attempted && audio != null) {
            try {
                int result = Build.VERSION.SDK_INT >= 26 && request != null
                    ? Api26.abandon(audio, request) : audio.abandonAudioFocus(listener);
                record("abandon-result", AuditReceipt.object("result", result));
            } catch (Exception error) {
                record("abandon-error", AuditReceipt.object("error", error.toString()));
                Log.e(AuditReceipt.TAG, "Focus abandonment failed", error);
            }
        }
        record("completed", AuditReceipt.object("reason", reason, "attempted", attempted,
            "elapsedSinceRequestMs", attempted ? SystemClock.elapsedRealtime() - requestedAt : 0));
        if (closeActivity) finish();
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        record("additional-intent-ignored", AuditReceipt.object("reason", "existing bounded audit remains owner"));
    }

    @Override protected void onStop() {
        super.onStop();
        if (!ended) finishAudit("activity-stopped-early", true);
    }

    @Override protected void onDestroy() {
        if (!ended) finishAudit("activity-destroyed-early", false);
        super.onDestroy();
    }

    private boolean record(String name, JSONObject details) {
        if (receipt == null) return false;
        try {
            receipt.event(name, details);
            return true;
        } catch (IOException error) {
            Log.e(AuditReceipt.TAG, "Private receipt write failed", error);
            return false;
        }
    }

    private static final class Api26 {
        static Object create(int gain, AudioManager.OnAudioFocusChangeListener listener, Handler handler) {
            return new AudioFocusRequest.Builder(gain)
                .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setAcceptsDelayedFocusGain(false).setWillPauseWhenDucked(false)
                .setOnAudioFocusChangeListener(listener, handler).build();
        }
        static int request(AudioManager manager, Object request) {
            return manager.requestAudioFocus((AudioFocusRequest)request);
        }
        static int abandon(AudioManager manager, Object request) {
            return manager.abandonAudioFocusRequest((AudioFocusRequest)request);
        }
    }
}
