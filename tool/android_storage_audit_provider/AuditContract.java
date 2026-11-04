package com.fluentplayer.audit.documents;

import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.os.Parcelable;
import android.provider.DocumentsContract;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import org.json.JSONObject;

final class AuditContract {
    static final String AUTHORITY = "com.fluentplayer.audit.documents";
    static final String TARGET_PACKAGE = "com.example.video_player_app.sidebar_profile";
    static final String TARGET_ACTIVITY = "com.example.video_player_app.MainActivity";
    static final List<String> DOCUMENT_IDS = Arrays.asList(
        "video", "audio", "subtitles", "duplicate-a", "duplicate-b", "denied", "truncated", "error", "slow");

    static Uri document(String id) {
        if (!DOCUMENT_IDS.contains(id)) throw new IllegalArgumentException("Unknown fixture document: " + id);
        return DocumentsContract.buildDocumentUri(AUTHORITY, id);
    }

    // Legacy overloads intentionally keep this fixture runnable from API24.
    @SuppressWarnings("deprecation")
    static ArrayList<Uri> streams(Intent intent) {
        LinkedHashSet<Uri> found = new LinkedHashSet<>();
        if (Intent.ACTION_SEND_MULTIPLE.equals(intent.getAction())) {
            ArrayList<Parcelable> values = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
            if (values != null) for (Parcelable value : values) if (value instanceof Uri) found.add((Uri) value);
        } else {
            Parcelable value = intent.getParcelableExtra(Intent.EXTRA_STREAM);
            if (value instanceof Uri) found.add((Uri) value);
        }
        if (intent.getData() != null) found.add(intent.getData());
        ClipData clip = intent.getClipData();
        if (clip != null) for (int i = 0; i < clip.getItemCount(); i++) {
            Uri uri = clip.getItemAt(i).getUri();
            if (uri != null) found.add(uri);
        }
        return new ArrayList<>(found);
    }

    static boolean permittedReceiveUri(Uri uri) {
        String authority = uri.getAuthority();
        return "content".equals(uri.getScheme()) && authority != null
            && (authority.equals(AUTHORITY) || authority.startsWith(TARGET_PACKAGE + "."));
    }

    static void json(File directory, String name, JSONObject value) throws IOException {
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("Cannot create receipt directory");
        File output = new File(directory, name);
        File partial = new File(directory, name + ".partial");
        try {
            try (FileOutputStream stream = new FileOutputStream(partial)) {
                stream.write(value.toString(2).getBytes(StandardCharsets.UTF_8));
                stream.getFD().sync();
            }
            if (!partial.renameTo(output)) throw new IOException("Cannot publish receipt");
        } catch (org.json.JSONException error) {
            throw new IOException(error);
        } finally { partial.delete(); }
    }

    static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) result.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
        return result.toString();
    }
}
