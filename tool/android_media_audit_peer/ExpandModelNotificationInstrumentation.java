package com.fluentplayer.audit.controls;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.Activity;
import android.app.Instrumentation;
import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import java.util.ArrayList;
import java.util.List;
import static com.fluentplayer.audit.controls.NotificationExpandDiagnostics.Counter.*;
import static com.fluentplayer.audit.controls.NotificationExpandDiagnostics.Reason.*;

/** One explicit SystemUI expansion, never a service command or notification action click. */
@SuppressWarnings("deprecation")
public final class ExpandModelNotificationInstrumentation extends Instrumentation {
    private Bundle arguments;
    private final NotificationExpandDiagnostics diagnostic = new NotificationExpandDiagnostics();

    @Override public void onCreate(Bundle values) {
        super.onCreate(values);
        arguments = values == null ? new Bundle() : values;
        start();
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        AuditReceipt receipt = null;
        int code = Activity.RESULT_CANCELED;
        boolean gestureAttempted = false;
        boolean expandAttempted = false;
        long started = SystemClock.elapsedRealtime();
        try {
            if (!AuditPolicy.PACKAGE.equals(getTargetContext().getPackageName())
                    || !AuditPolicy.PACKAGE.equals(getContext().getPackageName())) {
                throw NotificationExpandDiagnostics.reject(HELPER_IDENTITY_REFUSED);
            }
            diagnostic.stage = NotificationExpandDiagnostics.Stage.ARGUMENTS;
            boolean inspectOnly = false;
            for (String key : arguments.keySet()) {
                if (!"inspect_only".equals(key)) throw NotificationExpandDiagnostics.reject(ARGUMENTS_REFUSED);
            }
            if (arguments.containsKey("inspect_only")) {
                Object value = arguments.get("inspect_only");
                if (!(value instanceof String) || !("true".equals(value) || "false".equals(value))) {
                    throw NotificationExpandDiagnostics.reject(ARGUMENTS_REFUSED);
                }
                inspectOnly = "true".equals(value);
            }
            receipt = new AuditReceipt(getTargetContext(), "expand-known-model-notification");
            diagnostic.stage = NotificationExpandDiagnostics.Stage.AUTOMATION;
            UiAutomation automation = getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
            AccessibilityServiceInfo info = automation.getServiceInfo();
            if (info == null) throw NotificationExpandDiagnostics.reject(AUTOMATION_UNAVAILABLE);
            // Only this temporary automation connection is configured; existing services are preserved.
            info.flags |= AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS;
            automation.setServiceInfo(info);
            try (Snapshot first = Snapshot.capture(automation, diagnostic); Snapshot second = Snapshot.capture(automation, diagnostic)) {
                first.requireSame(second);
                receipt.event("validated-own-card", AuditReceipt.object(
                    "knownTitle", NotificationExpandPolicy.TITLE, "windowId", second.root.getWindowId(),
                    "rowBounds", second.bounds.toShortString(), "rowSelection", second.selection,
                    "contentContainers", second.counts.contents, "titleFields", second.counts.titles,
                    "nestedRows", second.counts.nestedRows, "advertisedActionIds", second.actionIds().toString(),
                    "inspectOnly", inspectOnly, "titleFieldsComparedInRam", true,
                    "otherNotificationTitleTextSaved", false));
                second.requireFresh(automation);
                diagnostic.stage = NotificationExpandDiagnostics.Stage.ACTION_INSPECT;
                boolean supportsExpand = second.supportsExpand();
                result.putBoolean("advertisedExpand", supportsExpand);
                result.putString("advertisedActionIds", second.actionIds().toString());
                result.putString("rowBounds", second.bounds.toShortString());
                result.putString("rowSelection", second.selection);
                if (inspectOnly) {
                    result.putString("status", "inspected-no-action");
                    code = Activity.RESULT_OK;
                } else if (supportsExpand) {
                    diagnostic.stage = NotificationExpandDiagnostics.Stage.ACTION_EXPAND;
                    expandAttempted = true;
                    // If an advertised action refuses, stop. Do not add an ambiguous second action.
                    boolean accepted = second.row.performAction(AccessibilityNodeInfo.ACTION_EXPAND);
                    if (!accepted) diagnostic.reason = EXPAND_ACTION_REFUSED;
                    result.putBoolean("actionAccepted", accepted);
                    result.putString("status", accepted ? "expand-accepted-not-verified" : "expand-refused-no-fallback");
                    receipt.event("expand-result", AuditReceipt.object("accepted", accepted,
                        "expandedUiVerified", false, "gestureFallback", false));
                    code = accepted ? Activity.RESULT_OK : Activity.RESULT_CANCELED;
                } else {
                    diagnostic.stage = NotificationExpandDiagnostics.Stage.GESTURE_PLAN;
                    NotificationExpandPolicy.Plan plan = NotificationExpandPolicy.plan(box(second.bounds),
                        box(second.titleBounds), box(second.windowBounds));
                    receipt.event("planned-two-finger-drag", AuditReceipt.object(
                        "x0", plan.x0, "x1", plan.x1, "startY", plan.startY, "endY", plan.endY,
                        "distancePx", plan.distance(), "bothDownInsideOwnRow", true,
                        "pathMayExtendBelowOriginalRow", plan.endY >= second.bounds.bottom,
                        "allPointsInsideActiveSystemUiWindow", true, "retries", 0));
                    // Revalidate after the receipt fsync, immediately before the first injected DOWN.
                    second.requireFresh(automation);
                    gestureAttempted = true;
                    diagnostic.stage = NotificationExpandDiagnostics.Stage.GESTURE_INJECT;
                    injectOneTwoFingerDrag(automation, plan, second.checkedAt);
                    receipt.event("gesture-injected", AuditReceipt.object("expandedUiVerified", false,
                        "notificationActionClicked", false, "serviceCommandSent", false));
                    result.putString("status", "two-finger-drag-injected-not-verified");
                    result.putInt("distancePx", plan.distance());
                    code = Activity.RESULT_OK;
                }
            }
            diagnostic.stage = NotificationExpandDiagnostics.Stage.COMPLETE;
        } catch (Exception error) {
            diagnostic.failure(error);
            result.putString("status", "rejected-or-error");
            result.putString("errorType", error.getClass().getSimpleName());
            // Framework exception messages are not under this helper's privacy control.
            result.putString("error", "Known-notification validation/action failed; no retry performed");
            if (receipt != null) {
                try { receipt.event("rejected-or-error", AuditReceipt.object("errorType", error.getClass().getSimpleName(),
                    "stage", diagnostic.stage.name(), "reasonCode", diagnostic.reason.name(),
                    "numericMetadata", diagnostic.numericMetadata(),
                    "error", "Known-notification validation/action failed; no retry performed", "gestureAttempted", gestureAttempted)); }
                catch (Exception ignored) { /* No private notification content is logged on failures. */ }
            }
        }
        result.putBoolean("gestureAttempted", gestureAttempted);
        result.putString("stage", diagnostic.stage.name());
        result.putString("reasonCode", diagnostic.reason.name());
        result.putString("numericMetadata", diagnostic.numericMetadata());
        result.putBoolean("expandAttempted", expandAttempted);
        result.putBoolean("notificationActionClicked", false);
        result.putBoolean("serviceCommandSent", false);
        result.putBoolean("expandedUiVerified", false);
        result.putString("titleFieldComparisonPolicy", "RAM-only exact comparison; nonmatching titles are not retained or saved");
        result.putBoolean("otherNotificationTitleTextSaved", false);
        result.putLong("elapsedMs", SystemClock.elapsedRealtime() - started);
        if (receipt != null) result.putString("receipt", receipt.file.getAbsolutePath());
        finish(code, result);
    }

    private static NotificationExpandPolicy.Box box(Rect value) {
        return new NotificationExpandPolicy.Box(value.left, value.top, value.right, value.bottom);
    }

    private static String packageName(AccessibilityNodeInfo node) {
        return node.getPackageName() == null ? null : node.getPackageName().toString();
    }

    private static boolean explicitRow(AccessibilityNodeInfo node) {
        return NotificationExpandPolicy.isExplicitRow(node.getClassName() == null ? null : node.getClassName().toString(), node.getViewIdResourceName());
    }

    private static boolean knownVisibleTitle(AccessibilityNodeInfo node) {
        if (!NotificationExpandPolicy.isTitleId(node.getViewIdResourceName())
                || !NotificationExpandPolicy.SYSTEM_UI.equals(packageName(node)) || !node.isVisibleToUser()) return false;
        CharSequence text = node.getText();
        return text != null && NotificationExpandPolicy.TITLE.contentEquals(text);
    }

    private static final NotificationTitleSearch.Tree<AccessibilityNodeInfo> TITLE_TREE =
        new NotificationTitleSearch.Tree<AccessibilityNodeInfo>() {
            public long now() { return SystemClock.uptimeMillis(); }
            public String viewId(AccessibilityNodeInfo node) { return node.getViewIdResourceName(); }
            public String packageName(AccessibilityNodeInfo node) { return ExpandModelNotificationInstrumentation.packageName(node); }
            public boolean visible(AccessibilityNodeInfo node) { return node.isVisibleToUser(); }
            public boolean refresh(AccessibilityNodeInfo node) { return node.refresh(); }
            public CharSequence text(AccessibilityNodeInfo node) { return node.getText(); }
            public int childCount(AccessibilityNodeInfo node) { return node.getChildCount(); }
            public AccessibilityNodeInfo child(AccessibilityNodeInfo node, int index) { return node.getChild(index); }
            public AccessibilityNodeInfo retain(AccessibilityNodeInfo node) { return AccessibilityNodeInfo.obtain(node); }
            public void release(AccessibilityNodeInfo node) { node.recycle(); }
        };

    private static final class Counts {
        int visited, titles, contents, nestedRows;
        boolean complete = true;
        final long started = SystemClock.uptimeMillis();
        void visit(AccessibilityNodeInfo node, int depth) {
            if (++visited > 1200 || depth > 40 || SystemClock.uptimeMillis() - started > 1500) {
                complete = false;
                return;
            }
            // Structural metadata only. Never fetch getText()/contentDescription from this traversal.
            String id = node.getViewIdResourceName();
            if (NotificationExpandPolicy.isTitleId(id)) titles++;
            if (NotificationExpandPolicy.isContentId(id)) contents++;
            if (depth > 0 && explicitRow(node)) nestedRows++;
            for (int index = 0; index < node.getChildCount() && complete; index++) {
                AccessibilityNodeInfo child = node.getChild(index);
                if (child == null) { complete = false; break; }
                try { visit(child, depth + 1); }
                finally { child.recycle(); }
            }
        }
        void requireSingle() {
            NotificationExpandPolicy.requireSingleCard(1, titles, contents, nestedRows, complete);
        }
    }

    private static final class Snapshot implements AutoCloseable {
        final NotificationExpandDiagnostics diagnostic;
        AccessibilityNodeInfo root, title, row;
        final Rect bounds = new Rect(), titleBounds = new Rect(), windowBounds = new Rect();
        String selection;
        Counts counts;
        // Measured from capture entry, not its end: slow Binder/traversal work must expire.
        long checkedAt = SystemClock.uptimeMillis();
        Snapshot(NotificationExpandDiagnostics diagnostic) { this.diagnostic = diagnostic; }

        static Snapshot capture(UiAutomation automation, NotificationExpandDiagnostics diagnostic) {
            Snapshot snapshot = new Snapshot(diagnostic);
            try {
                diagnostic.number(CAPTURE_ROUND, diagnostic.number(CAPTURE_ROUND) + 1);
                diagnostic.stage = NotificationExpandDiagnostics.Stage.ROOT_FETCH;
                snapshot.root = automation.getRootInActiveWindow();
                if (snapshot.root == null) throw NotificationExpandDiagnostics.reject(ROOT_ABSENT);
                diagnostic.stage = NotificationExpandDiagnostics.Stage.ROOT_REFRESH;
                boolean refreshed = snapshot.root.refresh(); diagnostic.number(ROOT_REFRESH_OK, refreshed ? 1 : 0);
                if (!refreshed) throw NotificationExpandDiagnostics.reject(ROOT_REFRESH_FAILED);
                diagnostic.stage = NotificationExpandDiagnostics.Stage.ROOT_IDENTITY;
                if (!NotificationExpandPolicy.SYSTEM_UI.equals(packageName(snapshot.root))) throw NotificationExpandDiagnostics.reject(ROOT_NOT_SYSTEM_UI);
                diagnostic.number(WINDOW_ID, snapshot.root.getWindowId());
                if (snapshot.root.getWindowId() < 0) throw NotificationExpandDiagnostics.reject(WINDOW_ID_UNAVAILABLE);
                diagnostic.stage = NotificationExpandDiagnostics.Stage.TITLE_QUERY;
                // Kept only as a numeric diagnostic: HyperOS can return zero despite an exposed title node.
                try {
                    List<AccessibilityNodeInfo> query = snapshot.root.findAccessibilityNodeInfosByText(NotificationExpandPolicy.TITLE);
                    diagnostic.number(QUERY_RESULTS, query.size()); diagnostic.number(QUERY_FAILED, 0);
                    for (AccessibilityNodeInfo node : query) node.recycle();
                } catch (RuntimeException ignored) {
                    diagnostic.number(QUERY_RESULTS, -1); diagnostic.number(QUERY_FAILED, 1);
                }
                diagnostic.stage = NotificationExpandDiagnostics.Stage.TITLE_TREE_SCAN;
                NotificationTitleSearch.Result<AccessibilityNodeInfo> match = NotificationTitleSearch.find(TITLE_TREE, snapshot.root);
                try {
                    diagnostic.number(TREE_VISITED_NODES, match.visited); diagnostic.number(TREE_SCAN_COMPLETE, match.complete ? 1 : 0);
                    diagnostic.number(TITLE_ID_MATCHES, match.titleFields); diagnostic.number(TITLE_REFRESH_FAILURES, match.refreshFailures);
                    diagnostic.number(EXACT_TITLES, match.exact);
                    if (!match.complete) throw NotificationExpandDiagnostics.reject(TITLE_TREE_INCOMPLETE);
                    if (match.exact != 1 || match.selected == null) throw NotificationExpandDiagnostics.reject(EXACT_TITLE_NOT_UNIQUE);
                    snapshot.title = match.selected;
                    match.selected = null; // Ownership transfers to Snapshot; all nonmatching text stayed in RAM.
                } finally { match.close(TITLE_TREE); }
                diagnostic.stage = NotificationExpandDiagnostics.Stage.TITLE_FILTER;
                if (!knownVisibleTitle(snapshot.title)) throw NotificationExpandDiagnostics.reject(EXACT_TITLE_NOT_UNIQUE);
                diagnostic.stage = NotificationExpandDiagnostics.Stage.ROW_ANCESTORS;
                AccessibilityNodeInfo current = AccessibilityNodeInfo.obtain(snapshot.title);
                try {
                    for (int depth = 0; depth < 20; depth++) {
                        diagnostic.number(ANCESTOR_DEPTH, depth);
                        if (NotificationExpandPolicy.isStackId(current.getViewIdResourceName())) break;
                        AccessibilityNodeInfo parent = current.getParent();
                        boolean stackChild = parent != null && NotificationExpandPolicy.isStackId(parent.getViewIdResourceName())
                            && NotificationExpandPolicy.SYSTEM_UI.equals(packageName(parent));
                        diagnostic.number(STACK_PARENT_SEEN, stackChild ? 1 : 0);
                        diagnostic.number(EXPLICIT_ROW_SEEN, explicitRow(current) ? 1 : 0);
                        if (explicitRow(current) || stackChild) {
                            snapshot.row = AccessibilityNodeInfo.obtain(current);
                            snapshot.selection = stackChild ? "single-card-direct-child-of-notification-stack" : "explicit-expandable-notification-row";
                            if (parent != null) parent.recycle();
                            break;
                        }
                        current.recycle();
                        current = parent;
                        if (current == null) break;
                    }
                } finally { if (current != null) current.recycle(); }
                if (snapshot.row == null) throw NotificationExpandDiagnostics.reject(ROW_BOUNDARY_UNRECOGNIZED);
                diagnostic.stage = NotificationExpandDiagnostics.Stage.ROW_REFRESH;
                boolean rowRefreshed = snapshot.row.refresh(); diagnostic.number(ROW_REFRESH_OK, rowRefreshed ? 1 : 0);
                if (!rowRefreshed) throw NotificationExpandDiagnostics.reject(ROW_REFRESH_FAILED);
                snapshot.validateNodes();
                return snapshot;
            } catch (RuntimeException error) {
                snapshot.close();
                throw error;
            }
        }

        void validateNodes() {
            diagnostic.stage = NotificationExpandDiagnostics.Stage.ROW_VISIBILITY;
            if (!NotificationExpandPolicy.SYSTEM_UI.equals(packageName(row))) throw NotificationExpandDiagnostics.reject(ROOT_NOT_SYSTEM_UI);
            diagnostic.number(ROW_VISIBLE, row.isVisibleToUser() ? 1 : 0); diagnostic.number(ROW_ENABLED, row.isEnabled() ? 1 : 0);
            diagnostic.number(TITLE_VISIBLE, title.isVisibleToUser() ? 1 : 0);
            diagnostic.number(ROW_WINDOW_MATCHES, row.getWindowId() == root.getWindowId() ? 1 : 0);
            diagnostic.number(TITLE_WINDOW_MATCHES, title.getWindowId() == root.getWindowId() ? 1 : 0);
            if (row.getWindowId() != root.getWindowId() || title.getWindowId() != root.getWindowId()) throw NotificationExpandDiagnostics.reject(ROW_WINDOW_MISMATCH);
            if (!row.isVisibleToUser() || !row.isEnabled() || !title.isVisibleToUser()) throw NotificationExpandDiagnostics.reject(ROW_NOT_VISIBLE_ENABLED);
            diagnostic.stage = NotificationExpandDiagnostics.Stage.ROW_COUNTS;
            counts = new Counts(); counts.visit(row, 0);
            diagnostic.number(ROW_VISITED_NODES, counts.visited); diagnostic.number(ROW_TITLE_FIELDS, counts.titles);
            diagnostic.number(ROW_CONTENT_CONTAINERS, counts.contents); diagnostic.number(ROW_NESTED_ROWS, counts.nestedRows);
            diagnostic.number(ROW_SCAN_COMPLETE, counts.complete ? 1 : 0);
            try { counts.requireSingle(); }
            catch (IllegalArgumentException rejected) { throw NotificationExpandDiagnostics.reject(ROW_NOT_SINGLE_CARD); }
            diagnostic.stage = NotificationExpandDiagnostics.Stage.ROW_GEOMETRY;
            row.getBoundsInScreen(bounds); title.getBoundsInScreen(titleBounds); root.getBoundsInScreen(windowBounds);
            try { NotificationExpandPolicy.plan(box(bounds), box(titleBounds), box(windowBounds)); }
            catch (IllegalArgumentException rejected) { throw NotificationExpandDiagnostics.reject(ROW_GEOMETRY_REFUSED); }
            requireFreshAge();
        }

        void requireFreshAge() {
            diagnostic.stage = NotificationExpandDiagnostics.Stage.SNAPSHOT_FRESHNESS;
            long age = SystemClock.uptimeMillis() - checkedAt; diagnostic.number(SNAPSHOT_AGE_MS, age);
            try { NotificationExpandPolicy.requireFresh(age); }
            catch (IllegalArgumentException rejected) { throw NotificationExpandDiagnostics.reject(STALE_SNAPSHOT); }
        }

        void requireSame(Snapshot other) {
            diagnostic.stage = NotificationExpandDiagnostics.Stage.SNAPSHOT_COMPARE;
            if (root.getWindowId() != other.root.getWindowId() || !title.equals(other.title) || !row.equals(other.row)
                    || !bounds.equals(other.bounds) || !titleBounds.equals(other.titleBounds) || !windowBounds.equals(other.windowBounds)) {
                throw NotificationExpandDiagnostics.reject(SNAPSHOT_CHANGED);
            }
        }

        void requireFresh(UiAutomation automation) {
            try (Snapshot fresh = capture(automation, diagnostic)) {
                requireSame(fresh);
                diagnostic.stage = NotificationExpandDiagnostics.Stage.TARGET_REFRESH;
                if (!row.refresh()) throw NotificationExpandDiagnostics.reject(ROW_REFRESH_FAILED);
                if (!title.refresh()) throw NotificationExpandDiagnostics.reject(TITLE_REFRESH_FAILED);
                if (!knownVisibleTitle(title) || !row.isVisibleToUser() || !row.isEnabled()
                        || !NotificationExpandPolicy.SYSTEM_UI.equals(packageName(row))
                        || row.getWindowId() != fresh.root.getWindowId() || title.getWindowId() != fresh.root.getWindowId()) {
                    throw NotificationExpandDiagnostics.reject(TARGET_IDENTITY_CHANGED);
                }
                Rect now = new Rect(), titleNow = new Rect();
                row.getBoundsInScreen(now); title.getBoundsInScreen(titleNow);
                if (!now.equals(bounds) || !titleNow.equals(titleBounds)) throw NotificationExpandDiagnostics.reject(TARGET_GEOMETRY_CHANGED);
                checkedAt = fresh.checkedAt;
                requireFreshAge();
            }
        }

        List<Integer> actionIds() {
            List<Integer> ids = new ArrayList<>();
            for (AccessibilityNodeInfo.AccessibilityAction action : row.getActionList()) ids.add(action.getId());
            return ids;
        }
        boolean supportsExpand() { return actionIds().contains(AccessibilityNodeInfo.ACTION_EXPAND); }
        @Override public void close() {
            if (row != null) { row.recycle(); row = null; }
            if (title != null) { title.recycle(); title = null; }
            if (root != null) { root.recycle(); root = null; }
        }
    }

    private static void injectOneTwoFingerDrag(UiAutomation automation, NotificationExpandPolicy.Plan plan, long checkedAt) {
        NotificationExpandPolicy.requireFresh(SystemClock.uptimeMillis() - checkedAt);
        long downTime = SystemClock.uptimeMillis();
        int active = 0;
        int y = plan.startY;
        try {
            // Mark before injection: even a false return might have partially delivered a DOWN.
            active = 1;
            inject(automation, downTime, MotionEvent.ACTION_DOWN, 1, plan, y);
            SystemClock.sleep(20);
            active = 2;
            inject(automation, downTime, MotionEvent.ACTION_POINTER_DOWN | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2, plan, y);
            for (int step = 1; step <= NotificationExpandPolicy.STEPS; step++) {
                if (SystemClock.uptimeMillis() - downTime > 1500) {
                    throw NotificationExpandDiagnostics.reject(GESTURE_DEADLINE_EXCEEDED);
                }
                SystemClock.sleep(NotificationExpandPolicy.STEP_MS);
                y = plan.y(step);
                inject(automation, downTime, MotionEvent.ACTION_MOVE, 2, plan, y);
            }
            requireGestureDeadline(downTime);
            inject(automation, downTime, MotionEvent.ACTION_POINTER_UP | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2, plan, y);
            active = 1;
            requireGestureDeadline(downTime);
            inject(automation, downTime, MotionEvent.ACTION_UP, 1, plan, y);
            active = 0;
        } finally {
            if (active > 0) {
                try { inject(automation, downTime, MotionEvent.ACTION_CANCEL, active, plan, y); }
                catch (RuntimeException ignored) { /* No UP/click fallback after partial injection. */ }
            }
        }
    }

    private static void requireGestureDeadline(long downTime) {
        if (SystemClock.uptimeMillis() - downTime > 1500) {
            throw NotificationExpandDiagnostics.reject(GESTURE_DEADLINE_EXCEEDED);
        }
    }

    private static void inject(UiAutomation automation, long downTime, int action, int count,
                               NotificationExpandPolicy.Plan plan, int y) {
        MotionEvent.PointerProperties[] properties = new MotionEvent.PointerProperties[count];
        MotionEvent.PointerCoords[] coords = new MotionEvent.PointerCoords[count];
        for (int index = 0; index < count; index++) {
            properties[index] = new MotionEvent.PointerProperties();
            properties[index].id = index;
            properties[index].toolType = MotionEvent.TOOL_TYPE_FINGER;
            coords[index] = new MotionEvent.PointerCoords();
            coords[index].x = index == 0 ? plan.x0 : plan.x1;
            coords[index].y = y;
            coords[index].pressure = 1; coords[index].size = 1;
        }
        MotionEvent event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, count,
            properties, coords, 0, 0, 1, 1, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
        try {
            if (!automation.injectInputEvent(event, true)) throw NotificationExpandDiagnostics.reject(INPUT_INJECTION_REFUSED);
        } finally { event.recycle(); }
    }
}
