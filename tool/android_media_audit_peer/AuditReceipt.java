package com.fluentplayer.audit.controls;

import android.content.Context;
import android.os.Build;
import android.os.SystemClock;
import android.util.Log;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Comparator;
import java.util.UUID;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

final class AuditReceipt {
    static final String TAG = "FluentMediaAuditPeer";
    final File file;
    final String id;
    private final JSONObject document;
    private final JSONArray events = new JSONArray();

    AuditReceipt(Context context, String kind) throws IOException {
        File directory = new File(context.getFilesDir(), "media-audit-peer/receipts");
        if (!directory.isDirectory() && !directory.mkdirs()) {
            throw new IOException("Cannot create the peer's private receipt directory");
        }
        String privateRoot = context.getFilesDir().getCanonicalPath() + File.separator;
        if (!directory.getCanonicalPath().startsWith(privateRoot)) {
            throw new IOException("Receipt directory escaped the peer's private storage");
        }
        File[] previous = directory.listFiles((dir, name) -> name.matches("peer-[0-9a-f-]+\\.json"));
        if (previous != null && previous.length >= 128) {
            Arrays.sort(previous, Comparator.comparingLong(File::lastModified));
            for (int i = 0; i <= previous.length - 128; i++) {
                if (!previous[i].delete()) Log.w(TAG, "Could not prune old private receipt: " + previous[i].getName());
            }
        }
        id = UUID.randomUUID().toString();
        file = new File(directory, "peer-" + id + ".json");
        document = object("receiptId", id, "kind", kind, "package", AuditPolicy.PACKAGE,
            "sdk", Build.VERSION.SDK_INT, "targetSdk", context.getApplicationInfo().targetSdkVersion,
            "createdWallTimeMs", System.currentTimeMillis(), "createdElapsedRealtimeMs", SystemClock.elapsedRealtime(),
            "syntheticAuditPeer", true, "events", events);
        write();
    }

    static JSONObject object(Object... pairs) {
        if (pairs.length % 2 != 0) throw new IllegalArgumentException("Expected key/value pairs");
        JSONObject value = new JSONObject();
        try {
            for (int i = 0; i < pairs.length; i += 2) value.put((String)pairs[i], pairs[i + 1]);
            return value;
        } catch (JSONException error) {
            throw new IllegalArgumentException("Invalid receipt value", error);
        }
    }

    synchronized void event(String name, JSONObject details) throws IOException {
        events.put(object("event", name, "wallTimeMs", System.currentTimeMillis(),
            "elapsedRealtimeMs", SystemClock.elapsedRealtime(), "details", details));
        write();
        Log.i(TAG, document.toString());
    }

    private void write() throws IOException {
        File partial = new File(file.getParentFile(), file.getName() + ".partial");
        try {
            try (FileOutputStream output = new FileOutputStream(partial)) {
                output.write(document.toString(2).getBytes(StandardCharsets.UTF_8));
                output.getFD().sync();
            }
            if (!partial.renameTo(file)) throw new IOException("Cannot publish the peer receipt");
        } catch (JSONException error) {
            throw new IOException(error);
        } finally {
            if (partial.exists() && !partial.delete()) Log.w(TAG, "Could not remove private partial receipt");
        }
    }
}
