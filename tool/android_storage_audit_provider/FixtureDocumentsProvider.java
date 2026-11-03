package com.fluentplayer.audit.documents;

import android.database.Cursor;
import android.database.MatrixCursor;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract.Document;
import android.provider.DocumentsContract.Root;
import android.provider.DocumentsProvider;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import org.json.JSONArray;
import org.json.JSONObject;

public final class FixtureDocumentsProvider extends DocumentsProvider {
    private static final String ROOT = "root";
    private static final String[] ROOT_COLUMNS = {Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID,
        Root.COLUMN_TITLE, Root.COLUMN_SUMMARY, Root.COLUMN_FLAGS, Root.COLUMN_MIME_TYPES, Root.COLUMN_AVAILABLE_BYTES};
    private static final String[] DOCUMENT_COLUMNS = {Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
        Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE, Document.COLUMN_FLAGS, Document.COLUMN_LAST_MODIFIED};
    private File fixtureDirectory;

    @Override public boolean onCreate() {
        fixtureDirectory = new File(getContext().getFilesDir(), "fixtures");
        try {
            if (!fixtureDirectory.isDirectory() && !fixtureDirectory.mkdirs()) return false;
            JSONObject metadata;
            try (InputStream input = getContext().getAssets().open("fixture-metadata.json")) {
                java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
                byte[] buffer = new byte[8192]; int count;
                while ((count = input.read(buffer)) != -1) bytes.write(buffer, 0, count);
                metadata = new JSONObject(bytes.toString("UTF-8"));
            }
            JSONArray files = metadata.getJSONArray("files");
            for (int i = 0; i < files.length(); i++) {
                JSONObject entry = files.getJSONObject(i);
                String name = entry.getString("file");
                if (!new File(name).getName().equals(name)) throw new IOException("Invalid fixture name");
                File output = new File(fixtureDirectory, name);
                if (output.isFile() && sha(output).equals(entry.getString("sha256"))) continue;
                File partial = new File(fixtureDirectory, name + ".partial");
                try (InputStream input = getContext().getAssets().open("fixtures/" + name);
                     FileOutputStream stream = new FileOutputStream(partial)) {
                    byte[] buffer = new byte[16384]; int count;
                    while ((count = input.read(buffer)) != -1) stream.write(buffer, 0, count);
                    stream.getFD().sync();
                }
                if (!sha(partial).equals(entry.getString("sha256"))) throw new IOException("Fixture SHA mismatch");
                if (!partial.renameTo(output)) throw new IOException("Cannot publish fixture");
            }
            return true;
        } catch (Exception error) { android.util.Log.e("FluentAuditProvider", "Fixture preparation failed", error); return false; }
    }

    private static String sha(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[16384]; int count;
            while ((count = input.read(buffer)) != -1) digest.update(buffer, 0, count);
        }
        return AuditContract.hex(digest.digest());
    }

    @Override public Cursor queryRoots(String[] projection) {
        String[] columns = projection == null ? ROOT_COLUMNS : projection;
        MatrixCursor cursor = new MatrixCursor(columns);
        MatrixCursor.RowBuilder row = cursor.newRow();
        for (String column : columns) {
            Object value = null;
            if (column.equals(Root.COLUMN_ROOT_ID) || column.equals(Root.COLUMN_DOCUMENT_ID)) value = ROOT;
            else if (column.equals(Root.COLUMN_TITLE)) value = "Fluent audit fixtures";
            else if (column.equals(Root.COLUMN_SUMMARY)) value = "Synthetic files · read only · no _data";
            else if (column.equals(Root.COLUMN_FLAGS)) value = Root.FLAG_LOCAL_ONLY | Root.FLAG_SUPPORTS_IS_CHILD;
            else if (column.equals(Root.COLUMN_MIME_TYPES)) value = "video/*\naudio/*\ntext/plain\napplication/x-subrip";
            else if (column.equals(Root.COLUMN_AVAILABLE_BYTES)) value = 0L;
            row.add(value);
        }
        return cursor;
    }

    private MatrixCursor cursor(String[] projection) {
        String[] columns = projection == null ? DOCUMENT_COLUMNS : projection;
        for (String column : columns) if ("_data".equals(column))
            throw new IllegalArgumentException("This provider exposes no raw filesystem path");
        return new MatrixCursor(columns);
    }

    @Override public Cursor queryDocument(String documentId, String[] projection) throws FileNotFoundException {
        MatrixCursor cursor = cursor(projection); add(cursor, documentId); return cursor;
    }

    @Override public Cursor queryChildDocuments(String parentId, String[] projection, String sortOrder) throws FileNotFoundException {
        if (!ROOT.equals(parentId)) throw new FileNotFoundException("Not a directory");
        MatrixCursor cursor = cursor(projection);
        for (String id : AuditContract.DOCUMENT_IDS) add(cursor, id);
        return cursor;
    }

    @Override public boolean isChildDocument(String parent, String child) {
        return ROOT.equals(parent) && AuditContract.DOCUMENT_IDS.contains(child);
    }

    private File source(String id) throws FileNotFoundException {
        if (!AuditContract.DOCUMENT_IDS.contains(id)) throw new FileNotFoundException("Unknown audit document");
        return new File(fixtureDirectory, id.equals("audio") ? "audio.mp3" : id.equals("subtitles") ? "subtitles.srt"
            : id.equals("duplicate-b") ? "video-b.mp4" : "video.mp4");
    }

    private void add(MatrixCursor cursor, String id) throws FileNotFoundException {
        boolean root = ROOT.equals(id);
        File file = root ? null : source(id);
        String name = root ? "Fluent audit fixtures" : id.startsWith("duplicate-") ? "同名视频.mp4"
            : id.equals("audio") ? "测试音频.mp3" : id.equals("subtitles") ? "测试字幕.srt" : id + ".mp4";
        MatrixCursor.RowBuilder row = cursor.newRow();
        for (String column : cursor.getColumnNames()) {
            Object value = null;
            if (column.equals(Document.COLUMN_DOCUMENT_ID)) value = id;
            else if (column.equals(Document.COLUMN_DISPLAY_NAME)) value = name;
            else if (column.equals(Document.COLUMN_MIME_TYPE)) value = root ? Document.MIME_TYPE_DIR
                : id.equals("audio") ? "audio/mpeg" : id.equals("subtitles") ? "application/x-subrip" : "video/mp4";
            else if (column.equals(Document.COLUMN_SIZE)) value = root ? null : file.length() + (id.equals("truncated") ? 4096L : 0L);
            else if (column.equals(Document.COLUMN_FLAGS)) value = 0;
            else if (column.equals(Document.COLUMN_LAST_MODIFIED)) value = 1700000000000L;
            row.add(value);
        }
    }

    @Override public ParcelFileDescriptor openDocument(String id, String mode, CancellationSignal signal) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new FileNotFoundException("Audit fixtures are read only");
        if (signal != null) signal.throwIfCanceled();
        File file = source(id);
        if (id.equals("denied")) throw new SecurityException("Intentional fixture read denial");
        if (!id.equals("error") && !id.equals("slow")) return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
        try {
            final ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createReliablePipe();
            Thread thread = new Thread(() -> {
                try (InputStream input = new FileInputStream(file);
                     ParcelFileDescriptor.AutoCloseOutputStream output = new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) {
                    byte[] buffer = new byte[id.equals("error") ? 32 : Math.max(1, (int) (file.length() / 20))];
                    int count;
                    while ((count = input.read(buffer)) != -1) {
                        if (signal != null) signal.throwIfCanceled();
                        output.write(buffer, 0, count); output.flush();
                        if (id.equals("error")) { pipe[1].closeWithError("Intentional provider stream failure"); return; }
                        Thread.sleep(350);
                    }
                } catch (Exception error) {
                    try { pipe[1].closeWithError("Audit stream stopped: " + error.getClass().getSimpleName()); } catch (IOException ignored) { }
                }
            }, "audit-provider-" + id);
            thread.start();
            return pipe[0];
        } catch (IOException error) { throw new FileNotFoundException(error.toString()); }
    }
}
