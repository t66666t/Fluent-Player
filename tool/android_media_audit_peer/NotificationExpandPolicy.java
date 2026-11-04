package com.fluentplayer.audit.controls;

/** Pure geometry/selection policy; runnable on the host without Android stubs. */
final class NotificationExpandPolicy {
    static final String SYSTEM_UI = "com.android.systemui";
    static final String TITLE = "Fluent Player 模型中心";
    static final int MAX_DRAG_PX = 360; // Deliberately strictly below 500 pixels.
    static final int STEPS = 20;
    static final int STEP_MS = 18;
    static final long MAX_FRESH_AGE_MS = 500;

    private NotificationExpandPolicy() {}

    static void requireSystemUi(String packageName) {
        if (!SYSTEM_UI.equals(packageName)) throw new IllegalArgumentException("Active window must be SystemUI");
    }

    static boolean isTitleId(String id) {
        return "com.android.systemui:id/title".equals(id) || "android:id/title".equals(id);
    }

    static boolean isContentId(String id) {
        return "com.android.systemui:id/status_bar_latest_event_content".equals(id)
            || "android:id/status_bar_latest_event_content".equals(id);
    }

    static boolean isStackId(String id) {
        return "com.android.systemui:id/notification_stack_scroller".equals(id);
    }

    static boolean isExplicitRow(String className, String id) {
        return (className != null && className.endsWith(".ExpandableNotificationRow"))
            || "com.android.systemui:id/notification_row".equals(id)
            || "com.android.systemui:id/expandableNotificationRow".equals(id);
    }

    static void requireSingleCard(int exactTitles, int titleFields, int contentContainers,
                                  int nestedRows, boolean complete) {
        if (!complete || exactTitles != 1 || titleFields != 1 || contentContainers != 1 || nestedRows != 0) {
            throw new IllegalArgumentException("Single-card check refused: exactTitles=" + exactTitles
                + ", titleFields=" + titleFields + ", contentContainers=" + contentContainers
                + ", nestedRows=" + nestedRows + ", scanComplete=" + complete);
        }
    }

    static void requireFresh(long elapsedMs) {
        if (elapsedMs < 0 || elapsedMs > MAX_FRESH_AGE_MS) throw new IllegalArgumentException("Notification geometry is stale");
    }

    static final class Box {
        final int left, top, right, bottom;
        Box(int left, int top, int right, int bottom) {
            this.left = left; this.top = top; this.right = right; this.bottom = bottom;
        }
        int width() { return right - left; }
        int height() { return bottom - top; }
        boolean contains(int x, int y) { return x >= left && x < right && y >= top && y < bottom; }
        boolean contains(Box value) {
            return value.left >= left && value.top >= top && value.right <= right && value.bottom <= bottom
                && value.width() > 0 && value.height() > 0;
        }
    }

    static final class Plan {
        final int x0, x1, startY, endY;
        Plan(int x0, int x1, int startY, int endY) {
            this.x0 = x0; this.x1 = x1; this.startY = startY; this.endY = endY;
        }
        int distance() { return endY - startY; }
        int y(int step) {
            if (step < 0 || step > STEPS) throw new IllegalArgumentException("Invalid gesture step");
            return startY + distance() * step / STEPS;
        }
    }

    static Plan plan(Box row, Box title, Box window) {
        if (window.width() <= 0 || window.height() <= 0 || !window.contains(row) || !row.contains(title)
                || row.width() < 160 || row.height() < 48
                || (long)row.height() * 4 > (long)window.height() * 3) {
            throw new IllegalArgumentException("Notification must be a visible, bounded single card inside the active window");
        }
        int x0 = row.left + row.width() * 2 / 5;
        int x1 = row.left + row.width() * 3 / 5;
        int startY = row.top + Math.min(24, row.height() / 4);
        int endY = Math.min(startY + MAX_DRAG_PX, window.bottom - 16);
        Plan result = new Plan(x0, x1, startY, endY);
        if (!row.contains(x0, startY) || !row.contains(x1, startY) || x1 - x0 < 24
                || result.distance() < 80 || result.distance() >= 500
                || !window.contains(x0, endY) || !window.contains(x1, endY)) {
            throw new IllegalArgumentException("No safe bounded two-finger downward gesture fits this card/window");
        }
        return result;
    }
}
