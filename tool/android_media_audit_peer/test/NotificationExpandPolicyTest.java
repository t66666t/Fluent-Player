package com.fluentplayer.audit.controls;

/** These tests exercise real policy decisions, not source-text assertions. */
public final class NotificationExpandPolicyTest {
    private static int checks;
    private static void check(boolean value) {
        checks++;
        if (!value) throw new AssertionError("Notification policy check " + checks + " failed");
    }
    private static void rejects(Runnable value) {
        checks++;
        try { value.run(); } catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Notification policy check " + checks + " should reject");
    }
    private static NotificationExpandPolicy.Box b(int l, int t, int r, int d) {
        return new NotificationExpandPolicy.Box(l, t, r, d);
    }
    public static void main(String[] args) {
        NotificationExpandPolicy.requireSystemUi("com.android.systemui");
        rejects(() -> NotificationExpandPolicy.requireSystemUi(null));
        rejects(() -> NotificationExpandPolicy.requireSystemUi("com.example.video_player_app"));
        check(NotificationExpandPolicy.isTitleId("com.android.systemui:id/title"));
        check(NotificationExpandPolicy.isTitleId("android:id/title"));
        check(!NotificationExpandPolicy.isTitleId("com.android.systemui:id/text"));
        check(NotificationExpandPolicy.isStackId("com.android.systemui:id/notification_stack_scroller"));
        check(!NotificationExpandPolicy.isStackId("com.android.systemui:id/shade"));
        check(NotificationExpandPolicy.isContentId("com.android.systemui:id/status_bar_latest_event_content"));
        check(!NotificationExpandPolicy.isContentId("com.android.systemui:id/notification_main_column"));
        check(NotificationExpandPolicy.isExplicitRow("com.android.systemui.statusbar.notification.row.ExpandableNotificationRow", ""));
        check(!NotificationExpandPolicy.isExplicitRow("android.view.ViewGroup", "com.android.systemui:id/expanded"));
        NotificationExpandPolicy.requireSingleCard(1, 1, 1, 0, true);
        rejects(() -> NotificationExpandPolicy.requireSingleCard(0, 1, 1, 0, true));
        rejects(() -> NotificationExpandPolicy.requireSingleCard(2, 2, 2, 1, true));
        rejects(() -> NotificationExpandPolicy.requireSingleCard(1, 2, 1, 0, true));
        rejects(() -> NotificationExpandPolicy.requireSingleCard(1, 1, 2, 0, true));
        rejects(() -> NotificationExpandPolicy.requireSingleCard(1, 1, 1, 1, true));
        rejects(() -> NotificationExpandPolicy.requireSingleCard(1, 1, 1, 0, false));
        NotificationExpandPolicy.requireFresh(0);
        NotificationExpandPolicy.requireFresh(500);
        rejects(() -> NotificationExpandPolicy.requireFresh(501));
        rejects(() -> NotificationExpandPolicy.requireFresh(-1));
        NotificationExpandPolicy.Box row = b(845, 807, 2035, 964);
        NotificationExpandPolicy.Box title = b(985, 832, 1845, 883);
        NotificationExpandPolicy.Box window = b(0, 0, 2880, 1800);
        NotificationExpandPolicy.Plan plan = NotificationExpandPolicy.plan(row, title, window);
        check(row.contains(plan.x0, plan.startY));
        check(row.contains(plan.x1, plan.startY));
        check(plan.x0 != plan.x1 && plan.distance() == 360 && plan.distance() < 500);
        for (int i = 0; i <= NotificationExpandPolicy.STEPS; i++) {
            check(window.contains(plan.x0, plan.y(i)) && window.contains(plan.x1, plan.y(i)));
            if (i > 0) check(plan.y(i) > plan.y(i - 1));
        }
        rejects(() -> plan.y(-1));
        rejects(() -> plan.y(21));
        rejects(() -> NotificationExpandPolicy.plan(b(0, 0, 400, 1700), b(10, 10, 200, 40), window));
        rejects(() -> NotificationExpandPolicy.plan(b(-1, 10, 400, 200), b(10, 20, 200, 50), window));
        rejects(() -> NotificationExpandPolicy.plan(row, b(0, 0, 10, 10), window));
        rejects(() -> NotificationExpandPolicy.plan(b(100, 100, 150, 200), b(105, 110, 145, 130), window));
        rejects(() -> NotificationExpandPolicy.plan(b(100, 1740, 500, 1800), b(120, 1750, 400, 1770), window));
        NotificationExpandPolicy.Plan bottom = NotificationExpandPolicy.plan(b(100, 1550, 500, 1730), b(120, 1570, 450, 1610), window);
        check(bottom.endY == 1784 && bottom.distance() < 360);
        System.out.println("NotificationExpandPolicy: " + checks + " checks passed; no Android runtime/device accessed.");
    }
}
