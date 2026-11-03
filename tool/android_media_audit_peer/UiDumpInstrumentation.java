package com.fluentplayer.audit.controls;

import android.app.Activity;
import android.app.Instrumentation;
import android.app.UiAutomation;
import android.content.Context;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;
import android.util.Xml;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityNodeInfo;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import org.xmlpull.v1.XmlSerializer;

/** Read-only snapshot. No idle wait, action, input injection or Activity launch. */
@SuppressWarnings("deprecation")
public final class UiDumpInstrumentation extends Instrumentation {
    private static final int MAX_NODES = 10000;
    private static final int MAX_DEPTH = 80;
    private static final long TRAVERSAL_BUDGET_MS = 5000;
    private Bundle arguments;
    private int nodes;
    private boolean truncated;
    private long traversalStarted;

    @Override public void onCreate(Bundle values) {
        super.onCreate(values);
        arguments = values == null ? new Bundle() : values;
        start();
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        AccessibilityNodeInfo root = null;
        File partial = null;
        final long started = SystemClock.elapsedRealtime();
        try {
            Context context = getTargetContext();
            if (!AuditPolicy.PACKAGE.equals(context.getPackageName()) ||
                !AuditPolicy.PACKAGE.equals(getContext().getPackageName())) {
                throw new SecurityException("Instrumentation must target only its own audit helper");
            }
            String requested = null;
            if (arguments.containsKey("filename")) {
                Object value = arguments.get("filename");
                if (!(value instanceof String)) throw new IllegalArgumentException("filename must be a string");
                requested = (String)value;
            }
            String filename = AuditPolicy.uiDumpFilename(requested);
            File files = context.getFilesDir().getCanonicalFile();
            File directory = new File(files, "ui").getCanonicalFile();
            if (!directory.getPath().startsWith(files.getPath() + File.separator)) {
                throw new SecurityException("UI directory escaped helper private storage");
            }
            if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("Cannot create private UI directory");
            File target = new File(directory, filename);
            partial = new File(directory, filename + ".partial");
            if (!target.getCanonicalFile().getParentFile().equals(directory) ||
                !partial.getCanonicalFile().getParentFile().equals(directory)) {
                throw new SecurityException("Snapshot path escaped helper private UI directory");
            }
            // Preserve existing accessibility services. Do not wait for idle:
            // Flutter playback can keep emitting events for the entire track.
            UiAutomation automation = getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
            root = automation.getRootInActiveWindow();
            traversalStarted = SystemClock.elapsedRealtime();
            nodes = 0;
            truncated = false;
            WindowManager windows = (WindowManager)context.getSystemService(Context.WINDOW_SERVICE);
            int rotation = windows == null ? 0 : windows.getDefaultDisplay().getRotation();
            try (FileOutputStream output = new FileOutputStream(partial)) {
                XmlSerializer xml = Xml.newSerializer();
                xml.setOutput(output, "UTF-8");
                xml.startDocument("UTF-8", true);
                xml.startTag(null, "hierarchy");
                xml.attribute(null, "rotation", Integer.toString(rotation));
                if (root != null) writeNode(xml, root, 0, 0);
                xml.endTag(null, "hierarchy");
                xml.endDocument();
                xml.flush();
                output.getFD().sync();
            }
            if (!partial.renameTo(target)) throw new IOException("Cannot publish private UI snapshot");
            result.putString("status", root == null ? "empty-root" : "dumped");
            result.putString("filename", filename);
            result.putString("path", target.getAbsolutePath());
            result.putInt("nodes", nodes);
            result.putBoolean("truncated", truncated);
            result.putLong("bytes", target.length());
            result.putLong("elapsedMs", SystemClock.elapsedRealtime() - started);
            result.putBoolean("waitForIdleUsed", false);
            result.putBoolean("inputInjected", false);
            finish(Activity.RESULT_OK, result);
        } catch (Exception error) {
            Log.e(AuditReceipt.TAG, "Read-only immediate UI snapshot failed", error);
            result.putString("status", "error");
            result.putString("error", error.toString());
            result.putLong("elapsedMs", SystemClock.elapsedRealtime() - started);
            finish(Activity.RESULT_CANCELED, result);
        } finally {
            if (root != null) root.recycle();
            if (partial != null && partial.exists() && !partial.delete()) {
                Log.w(AuditReceipt.TAG, "Could not remove helper-private partial XML");
            }
        }
    }

    private void writeNode(XmlSerializer xml, AccessibilityNodeInfo node, int index, int depth) throws IOException {
        if (nodes >= MAX_NODES || depth > MAX_DEPTH ||
            SystemClock.elapsedRealtime() - traversalStarted >= TRAVERSAL_BUDGET_MS) {
            truncated = true;
            return;
        }
        nodes++;
        Rect bounds = new Rect();
        node.getBoundsInScreen(bounds);
        xml.startTag(null, "node");
        xml.attribute(null, "index", Integer.toString(index));
        xml.attribute(null, "text", xmlText(node.getText()));
        xml.attribute(null, "resource-id", xmlText(node.getViewIdResourceName()));
        xml.attribute(null, "class", xmlText(node.getClassName()));
        xml.attribute(null, "package", xmlText(node.getPackageName()));
        xml.attribute(null, "content-desc", xmlText(node.getContentDescription()));
        xml.attribute(null, "checkable", Boolean.toString(node.isCheckable()));
        xml.attribute(null, "checked", Boolean.toString(node.isChecked()));
        xml.attribute(null, "clickable", Boolean.toString(node.isClickable()));
        xml.attribute(null, "enabled", Boolean.toString(node.isEnabled()));
        xml.attribute(null, "focusable", Boolean.toString(node.isFocusable()));
        xml.attribute(null, "focused", Boolean.toString(node.isFocused()));
        xml.attribute(null, "scrollable", Boolean.toString(node.isScrollable()));
        xml.attribute(null, "long-clickable", Boolean.toString(node.isLongClickable()));
        xml.attribute(null, "password", Boolean.toString(node.isPassword()));
        xml.attribute(null, "selected", Boolean.toString(node.isSelected()));
        xml.attribute(null, "bounds", "[" + bounds.left + "," + bounds.top + "][" + bounds.right + "," + bounds.bottom + "]");
        int children = node.getChildCount();
        for (int i = 0; i < children; i++) {
            if (nodes >= MAX_NODES || SystemClock.elapsedRealtime() - traversalStarted >= TRAVERSAL_BUDGET_MS) {
                truncated = true;
                break;
            }
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            try { writeNode(xml, child, i, depth + 1); }
            finally { child.recycle(); }
        }
        xml.endTag(null, "node");
    }

    private static String xmlText(CharSequence text) {
        if (text == null) return "";
        String source = text.toString();
        StringBuilder clean = new StringBuilder(source.length());
        for (int index = 0; index < source.length();) {
            int codePoint = source.codePointAt(index);
            index += Character.charCount(codePoint);
            if (codePoint == 9 || codePoint == 10 || codePoint == 13 ||
                codePoint >= 0x20 && codePoint <= 0xD7FF ||
                codePoint >= 0xE000 && codePoint <= 0xFFFD ||
                codePoint >= 0x10000 && codePoint <= 0x10FFFF) {
                clean.appendCodePoint(codePoint);
            } else clean.append('\uFFFD');
        }
        return clean.toString();
    }
}
