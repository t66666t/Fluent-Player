package com.fluentplayer.audit.documents;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.IOException;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONArray;
import org.json.JSONObject;

/** Reads the granted bytes before finishing; intent delivery alone is no pass. */
public final class AuditReceiveActivity extends Activity {
    private static final long BATCH_LIMIT = 64L * 1024 * 1024;
    private static final long RETAINED_LIMIT = 256L * 1024 * 1024;
    private static final ExecutorService RECEIVER = Executors.newSingleThreadExecutor();

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView text = new TextView(this);
        text.setPadding(24, 24, 24, 24);
        text.setText("Fluent audit receiver is reading the complete granted content…");
        setContentView(text);
        Intent snapshot = new Intent(getIntent());
        RECEIVER.execute(() -> receive(snapshot));
    }

    private void receive(Intent intent) {
        String id = System.currentTimeMillis() + "-" + UUID.randomUUID();
        File receivedRoot = new File(getFilesDir(), "received");
        File receiptDirectory = new File(getFilesDir(), "receipts");
        File batch = new File(receivedRoot, id);
        JSONObject receipt = new JSONObject();
        JSONArray items = new JSONArray();
        boolean complete = false;
        try {
            receipt.put("receiptId", id); receipt.put("startedAtMs", System.currentTimeMillis());
            receipt.put("action", intent.getAction()); receipt.put("items", items);
            if (!Intent.ACTION_SEND.equals(intent.getAction()) && !Intent.ACTION_SEND_MULTIPLE.equals(intent.getAction())
                && !Intent.ACTION_VIEW.equals(intent.getAction()))
                throw new IllegalArgumentException("Receiver accepts SEND/SEND_MULTIPLE/VIEW only");
            // AuditContract.streams also reads Intent.data (the VIEW payload),
            // deduplicating its URI against EXTRA_STREAM and ClipData.
            ArrayList<Uri> uris = AuditContract.streams(intent);
            if (uris.isEmpty() || uris.size() > 16) throw new IllegalArgumentException("Expected 1–16 content URIs");
            long existing = retainedBytes(receivedRoot);
            if (receiptDirectory.listFiles() != null && receiptDirectory.listFiles().length >= 128)
                throw new IOException("Receipt quota reached; inspect and clear this test app explicitly");
            if (!batch.mkdirs()) throw new IOException("Cannot create received batch directory");
            long batchBytes = 0;
            for (int i = 0; i < uris.size(); i++) {
                Uri uri = uris.get(i);
                JSONObject item = new JSONObject(); items.put(item);
                item.put("uri", uri.toString()); item.put("complete", false);
                if (!AuditContract.permittedReceiveUri(uri)) throw new SecurityException("Only isolated profile/fixture providers are accepted");
                String name = "shared-" + i;
                Long declared = null;
                try (Cursor cursor = getContentResolver().query(uri,
                    new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE}, null, null, null)) {
                    if (cursor != null && cursor.moveToFirst()) {
                        int column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                        if (column >= 0 && !cursor.isNull(column)) name = cursor.getString(column);
                        column = cursor.getColumnIndex(OpenableColumns.SIZE);
                        if (column >= 0 && !cursor.isNull(column)) declared = cursor.getLong(column);
                    }
                }
                item.put("displayName", name);
                item.put("declaredSize", declared == null ? JSONObject.NULL : declared);
                item.put("mimeType", getContentResolver().getType(uri));
                String safeName = name.replaceAll("[^\\p{L}\\p{N}._-]", "_");
                safeName = safeName.substring(0, Math.min(safeName.length(), 100));
                File output = new File(batch, i + "-" + safeName);
                File partial = new File(batch, i + ".partial");
                MessageDigest digest = MessageDigest.getInstance("SHA-256");
                long size = 0;
                try (InputStream input = getContentResolver().openInputStream(uri);
                     FileOutputStream stream = new FileOutputStream(partial)) {
                    if (input == null) throw new IOException("Provider returned no stream");
                    byte[] buffer = new byte[16384]; int count;
                    while ((count = input.read(buffer)) != -1) {
                        size += count; batchBytes += count;
                        if (batchBytes > BATCH_LIMIT || existing + batchBytes > RETAINED_LIMIT)
                            throw new IOException("Receiver test-data budget exceeded");
                        digest.update(buffer, 0, count); stream.write(buffer, 0, count);
                    }
                    stream.getFD().sync();
                }
                item.put("bytes", size); item.put("sha256", AuditContract.hex(digest.digest()));
                if (declared != null && declared >= 0 && declared != size) throw new IOException("Declared length differs from complete stream");
                if (!partial.renameTo(output)) throw new IOException("Cannot publish received file");
                item.put("storedPath", "received/" + id + "/" + output.getName()); item.put("complete", true);
            }
            complete = true; receipt.put("status", "complete");
        } catch (Exception error) {
            try { receipt.put("status", "error"); receipt.put("error", error.toString()); } catch (Exception ignored) { }
        } finally {
            if (!complete) {
                File[] files = batch.listFiles();
                if (files != null) for (File file : files) file.delete();
                batch.delete();
                // Completed item hashes remain diagnostic; no failed batch is retained.
                try { receipt.put("failedBatchRetained", false); } catch (Exception ignored) { }
            }
            try {
                receipt.put("finishedAtMs", System.currentTimeMillis());
                String receiptName = receiptDirectory.listFiles() != null && receiptDirectory.listFiles().length >= 128
                    ? "quota-last-error.json" : id + ".json";
                AuditContract.json(receiptDirectory, receiptName, receipt);
                AuditContract.json(getFilesDir(), "receive-last.json", receipt);
            } catch (Exception error) { android.util.Log.e("FluentAuditReceiver", "Could not write receipt", error); }
            runOnUiThread(this::finish);
        }
    }

    private long retainedBytes(File directory) {
        long size = 0; File[] entries = directory.listFiles();
        if (entries != null) for (File entry : entries) size += entry.isDirectory() ? retainedBytes(entry) : entry.length();
        return size;
    }
}
