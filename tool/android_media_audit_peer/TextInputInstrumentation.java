package com.fluentplayer.audit.controls;

import android.app.Activity;
import android.app.Instrumentation;
import android.app.UiAutomation;
import android.content.Context;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;
import android.view.accessibility.AccessibilityNodeInfo;
import java.security.MessageDigest;

/** Explicit write entry point, separate from the read-only UiDumpInstrumentation. */
@SuppressWarnings("deprecation")
public final class TextInputInstrumentation extends Instrumentation {
    private static final long PROPAGATION_HOLD_MS = 500;
    private Bundle arguments;

    @Override public void onCreate(Bundle values) {
        super.onCreate(values);
        arguments = values == null ? new Bundle() : values;
        start();
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        AuditReceipt receipt = null;
        AccessibilityNodeInfo firstRoot = null;
        AccessibilityNodeInfo secondRoot = null;
        AccessibilityNodeInfo currentRoot = null;
        Scan first = new Scan();
        Scan second = new Scan();
        int code = Activity.RESULT_CANCELED;
        final long started = SystemClock.elapsedRealtime();
        try {
            Context context = getTargetContext();
            if (!AuditPolicy.PACKAGE.equals(context.getPackageName()) ||
                !AuditPolicy.PACKAGE.equals(getContext().getPackageName())) {
                throw new SecurityException("Instrumentation must target only its own audit helper");
            }
            Object raw = arguments.get("text");
            if (!(raw instanceof String)) throw new IllegalArgumentException("-e text must be explicitly supplied as a string");
            String text = (String)raw;
            byte[] bytes = AuditPolicy.textInputBytes(text);
            String hash = hex(MessageDigest.getInstance("SHA-256").digest(bytes));
            receipt = new AuditReceipt(context, "explicit-action-set-text");
            receipt.event("request", AuditReceipt.object("targetRootPackage", AuditPolicy.TARGET_PACKAGE,
                "requiredClass", "android.widget.EditText", "textUtf8Bytes", bytes.length,
                "textSha256", hash, "action", "ACTION_SET_TEXT", "uiDumpRemainsReadOnly", true));
            UiAutomation automation = getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
            firstRoot = automation.getRootInActiveWindow();
            requireRoot(firstRoot);
            first.visit(firstRoot, 0);
            first.requireUnique();
            secondRoot = automation.getRootInActiveWindow();
            requireRoot(secondRoot);
            second.visit(secondRoot, 0);
            second.requireUnique();
            if (firstRoot.getWindowId() != secondRoot.getWindowId() || !first.target.equals(second.target)) {
                throw new IllegalStateException("Editable target changed during validation; no action performed");
            }
            receipt.event("validated", AuditReceipt.object("matchingEditableNodes", second.matches,
                "nodesVisited", second.visited, "windowId", secondRoot.getWindowId()));
            currentRoot = automation.getRootInActiveWindow();
            requireRoot(currentRoot);
            AccessibilityNodeInfo target = second.target;
            if (currentRoot.getWindowId() != target.getWindowId() || !target.refresh()) {
                throw new IllegalStateException("Target window/node is no longer active; no action performed");
            }
            requireEditableTarget(target);
            Rect bounds = new Rect();
            target.getBoundsInScreen(bounds);
            Bundle value = new Bundle();
            value.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text);
            // The only node action in this instrumentation. No focus, selection,
            // click, keyboard, clipboard or fallback injection is performed.
            boolean applied = target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, value);
            receipt.event("action-result", AuditReceipt.object("actionSucceeded", applied,
                "accessibilityActionAccepted", applied, "appValueVerified", false,
                "package", AuditPolicy.TARGET_PACKAGE, "class", "android.widget.EditText",
                "bounds", bounds.toShortString(), "textUtf8Bytes", bytes.length, "textSha256", hash));
            long heldMs = 0;
            if (applied) {
                // Flutter may enqueue this semantic action after the provider
                // acknowledges it. Keep this automation connection alive for a
                // fixed propagation window; do not wait for idle or retry.
                long holdStarted = SystemClock.elapsedRealtime();
                SystemClock.sleep(PROPAGATION_HOLD_MS);
                heldMs = SystemClock.elapsedRealtime() - holdStarted;
                receipt.event("propagation-window-complete", AuditReceipt.object(
                    "requestedHoldMs", PROPAGATION_HOLD_MS, "actualHoldMs", heldMs,
                    "appValueVerified", false));
            }
            result.putString("status", applied ? "action-accepted-not-verified" : "action-refused");
            result.putBoolean("actionSucceeded", applied);
            result.putBoolean("accessibilityActionAccepted", applied);
            result.putBoolean("appValueVerified", false);
            result.putLong("propagationHoldMs", heldMs);
            result.putString("actionResultMeaning", "Accessibility acceptance only; rendered/application value and business outcome require separate verification");
            result.putString("targetPackage", AuditPolicy.TARGET_PACKAGE);
            result.putString("targetClass", "android.widget.EditText");
            result.putInt("matchingEditableNodes", second.matches);
            result.putInt("textUtf8Bytes", bytes.length);
            result.putString("textSha256", hash);
            code = applied ? Activity.RESULT_OK : Activity.RESULT_CANCELED;
        } catch (Exception error) {
            result.putString("status", "rejected-or-error");
            result.putString("error", error.toString());
            if (receipt != null) {
                try { receipt.event("rejected-or-error", AuditReceipt.object("error", error.toString())); }
                catch (Exception loggingError) { Log.e(AuditReceipt.TAG, "Text-input receipt failed", loggingError); }
            }
            Log.e(AuditReceipt.TAG, "Explicit text input rejected or failed", error);
        } finally {
            first.close(); second.close();
            if (firstRoot != null) firstRoot.recycle();
            if (secondRoot != null) secondRoot.recycle();
            if (currentRoot != null) currentRoot.recycle();
        }
        if (receipt != null) result.putString("receipt", receipt.file.getAbsolutePath());
        result.putLong("elapsedMs", SystemClock.elapsedRealtime() - started);
        result.putBoolean("globalInputInjected", false);
        result.putBoolean("clipboardUsed", false);
        finish(code, result);
    }

    private static void requireRoot(AccessibilityNodeInfo root) {
        if (root == null) throw new IllegalStateException("No active root; no action performed");
        AuditPolicy.requireTextInputPackage(root.getPackageName() == null ? null : root.getPackageName().toString());
    }

    private static boolean isEditableClass(AccessibilityNodeInfo node) {
        return node.isEditable() && "android.widget.EditText".contentEquals(node.getClassName() == null ? "" : node.getClassName());
    }

    private static void requireEditableTarget(AccessibilityNodeInfo node) {
        if (!isEditableClass(node) || !node.isEnabled() || !node.isVisibleToUser()) {
            throw new IllegalStateException("Unique EditText must remain editable, enabled and visible; no action performed");
        }
        AuditPolicy.requireTextInputPackage(node.getPackageName() == null ? null : node.getPackageName().toString());
    }

    private static String hex(byte[] bytes) {
        StringBuilder output = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) output.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
        return output.toString();
    }

    private static final class Scan {
        private static final int MAX_NODES = 10000;
        private long started;
        AccessibilityNodeInfo target;
        int matches;
        int visited;
        boolean truncated;

        void visit(AccessibilityNodeInfo node, int depth) {
            if (visited == 0) started = SystemClock.elapsedRealtime();
            if (visited >= MAX_NODES || depth > 80 || SystemClock.elapsedRealtime() - started >= 5000) {
                truncated = true;
                return;
            }
            visited++;
            if (isEditableClass(node)) {
                matches++;
                if (matches == 1) target = AccessibilityNodeInfo.obtain(node);
                if (matches > 1) return;
            }
            int children = node.getChildCount();
            for (int i = 0; i < children && matches < 2 && !truncated; i++) {
                AccessibilityNodeInfo child = node.getChild(i);
                if (child == null) continue;
                try { visit(child, depth + 1); }
                finally { child.recycle(); }
            }
        }

        void requireUnique() {
            if (truncated) throw new IllegalStateException("Editable scan incomplete; no action performed");
            if (matches != 1 || target == null) {
                throw new IllegalStateException("Expected exactly one editable android.widget.EditText; found " + matches);
            }
            requireEditableTarget(target);
        }

        void close() { if (target != null) target.recycle(); }
    }
}
