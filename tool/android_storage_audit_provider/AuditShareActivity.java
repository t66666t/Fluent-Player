package com.fluentplayer.audit.documents;

import android.app.Activity;
import android.content.ClipData;
import android.content.ComponentName;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import org.json.JSONArray;
import org.json.JSONObject;

/** Explicitly targets only the isolated audit application, never the user app. */
public final class AuditShareActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        JSONObject receipt = new JSONObject();
        try {
            String mode = getIntent().getStringExtra("mode");
            if (mode == null) mode = "send";
            String selection = getIntent().getStringExtra("docs");
            if (selection == null) selection = mode.equals("multiple") ? "video,audio" : "video";
            LinkedHashSet<String> ids = new LinkedHashSet<>();
            for (String id : selection.split(",")) if (!id.trim().isEmpty()) ids.add(id.trim());
            if (ids.isEmpty() || ids.size() > 16) throw new IllegalArgumentException("Select 1–16 known fixture documents");
            ArrayList<Uri> uris = new ArrayList<>();
            for (String id : ids) uris.add(AuditContract.document(id));
            String action;
            switch (mode) {
                case "send": action = Intent.ACTION_SEND; break;
                case "multiple": action = Intent.ACTION_SEND_MULTIPLE; break;
                case "view": action = Intent.ACTION_VIEW; break;
                default: throw new IllegalArgumentException("mode must be send, multiple or view");
            }
            if (!mode.equals("multiple") && uris.size() != 1) throw new IllegalArgumentException("send/view require exactly one document");
            String mime = getContentResolver().getType(uris.get(0));
            for (Uri uri : uris) if (!java.util.Objects.equals(mime, getContentResolver().getType(uri))) mime = "*/*";
            Intent outgoing = new Intent(action).setComponent(
                new ComponentName(AuditContract.TARGET_PACKAGE, AuditContract.TARGET_ACTIVITY));
            if (mode.equals("view")) outgoing.setDataAndType(uris.get(0), mime);
            else {
                outgoing.setType(mime);
                if (mode.equals("multiple")) outgoing.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris);
                else outgoing.putExtra(Intent.EXTRA_STREAM, uris.get(0));
            }
            ClipData clip = new ClipData("Fluent audit fixtures", new String[]{mime}, new ClipData.Item(uris.get(0)));
            for (int i = 1; i < uris.size(); i++) clip.addItem(new ClipData.Item(uris.get(i)));
            outgoing.setClipData(clip);
            outgoing.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            receipt.put("target", outgoing.getComponent().flattenToString());
            receipt.put("action", action);
            JSONArray receiptUris = new JSONArray();
            for (Uri uri : uris) receiptUris.put(uri.toString());
            receipt.put("uris", receiptUris);
            receipt.put("readGrant", true);
            receipt.put("startedAtMs", System.currentTimeMillis());
            startActivity(outgoing);
            receipt.put("status", "dispatched");
            AuditContract.json(getFilesDir(), "share-last.json", receipt);
            finish();
        } catch (Exception error) {
            try {
                receipt.put("status", "error"); receipt.put("error", error.toString());
                AuditContract.json(getFilesDir(), "share-last.json", receipt);
            } catch (Exception ignored) { }
            TextView text = new TextView(this);
            text.setPadding(24, 24, 24, 24);
            text.setText("Audit share failed. Target is always the isolated sidebar_profile app.\n\n" + error);
            setContentView(text);
        }
    }
}
