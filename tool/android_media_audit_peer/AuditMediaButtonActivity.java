package com.fluentplayer.audit.controls;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;
import android.view.KeyEvent;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.IOException;
import org.json.JSONObject;

/** Sends only one explicit DOWN/UP pair to the hard-coded isolated receiver. */
public final class AuditMediaButtonActivity extends Activity {
    private TextView output;
    private AuditReceipt receipt;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(24, 36, 24, 24);
        output = new TextView(this);
        layout.addView(output);
        Button close = new Button(this);
        close.setText("Close audit peer");
        close.setOnClickListener(view -> finish());
        layout.addView(close);
        setContentView(layout);
        if (state != null) {
            output.setText("Activity restored; no command replayed. Launch with a new explicit intent to send another command.");
            return;
        }
        dispatch(getIntent());
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        dispatch(intent);
    }

    private void dispatch(Intent intent) {
        try {
            receipt = new AuditReceipt(this, "explicit-media-button");
            AuditPolicy.requireTarget(stringExtra(intent, "target"), stringExtra(intent, "target_package"),
                stringExtra(intent, "target_receiver"));
            String command = stringExtra(intent, "command");
            int keyCode = AuditPolicy.mediaKey(command);
            if (!record("dispatch-start", AuditReceipt.object("command", command, "keyCode", keyCode,
                    "target", AuditPolicy.TARGET, "deliveryAcknowledged", false,
                    "playPauseSemantics", "Raw PLAY and PAUSE keys both map to audio_service's media toggle; not idempotent transport commands"))) return;
            long downTime = SystemClock.uptimeMillis();
            sendKey(downTime, KeyEvent.ACTION_DOWN, keyCode);
            boolean completeReceipt = record("down-dispatched", AuditReceipt.object("keyCode", keyCode));
            sendKey(downTime, KeyEvent.ACTION_UP, keyCode);
            completeReceipt &= record("up-dispatched", AuditReceipt.object("keyCode", keyCode));
            completeReceipt &= record("completed", AuditReceipt.object("status", "broadcast-dispatched-unacknowledged",
                "command", command, "target", AuditPolicy.TARGET));
            output.setText((completeReceipt ? "Sent " : "Receipt incomplete after dispatching ") + command +
                " to the isolated receiver.\n\nReceipt: " + receipt.file +
                "\n\nThis is dispatch evidence only. It does not prove playback, physical headphones, Bluetooth routing or receiver handling." +
                "\n\nThis Activity stays visible so it does not bring the player back to the foreground automatically.");
        } catch (Exception error) {
            record("rejected-or-failed", AuditReceipt.object("error", error.toString()));
            output.setText("No further command sent.\n" + error +
                (receipt == null ? "" : "\nReceipt: " + receipt.file));
            Log.e(AuditReceipt.TAG, "Media button rejected or failed", error);
        }
    }

    private void sendKey(long downTime, int action, int keyCode) {
        Intent broadcast = new Intent(Intent.ACTION_MEDIA_BUTTON);
        broadcast.setComponent(new ComponentName(AuditPolicy.TARGET_PACKAGE, AuditPolicy.TARGET_RECEIVER));
        broadcast.putExtra(Intent.EXTRA_KEY_EVENT,
            new KeyEvent(downTime, SystemClock.uptimeMillis(), action, keyCode, 0));
        sendBroadcast(broadcast);
    }

    @SuppressWarnings("deprecation")
    private static String stringExtra(Intent intent, String key) {
        if (!intent.hasExtra(key)) return null;
        Object value = intent.getExtras().get(key);
        if (!(value instanceof String)) throw new IllegalArgumentException(key + " must be a string");
        return (String)value;
    }

    private boolean record(String name, JSONObject details) {
        if (receipt == null) return false;
        try {
            receipt.event(name, details);
            return true;
        } catch (IOException error) {
            Log.e(AuditReceipt.TAG, "Private receipt write failed", error);
            output.setText("Private receipt write failed; audit is incomplete. " + error);
            return false;
        }
    }
}
