package com.fluentplayer.audit.controls;

public final class NotificationExpandDiagnosticsTest {
    private static int checks;
    private static void check(boolean value) {
        checks++;
        if (!value) throw new AssertionError("Notification diagnostics check " + checks + " failed");
    }
    public static void main(String[] args) {
        NotificationExpandDiagnostics d = new NotificationExpandDiagnostics();
        check(d.reason == NotificationExpandDiagnostics.Reason.OK);
        d.stage = NotificationExpandDiagnostics.Stage.ROW_COUNTS;
        d.number(NotificationExpandDiagnostics.Counter.ROW_TITLE_FIELDS, 2);
        d.failure(NotificationExpandDiagnostics.reject(NotificationExpandDiagnostics.Reason.ROW_NOT_SINGLE_CARD));
        check(d.stage == NotificationExpandDiagnostics.Stage.ROW_COUNTS);
        check(d.reason == NotificationExpandDiagnostics.Reason.ROW_NOT_SINGLE_CARD);
        check(d.number(NotificationExpandDiagnostics.Counter.ROW_TITLE_FIELDS) == 2);
        d.failure(new IllegalStateException("private third-party framework message must not escape"));
        check(d.reason == NotificationExpandDiagnostics.Reason.FRAMEWORK_EXCEPTION);
        check(!d.numericMetadata().contains("private"));
        check(!d.numericMetadata().contains("framework"));
        check(d.numericMetadata().equals("{ROW_TITLE_FIELDS=2}"));
        check(d.number(NotificationExpandDiagnostics.Counter.EXACT_TITLES) == 0);
        for (NotificationExpandDiagnostics.Stage stage : NotificationExpandDiagnostics.Stage.values()) {
            check(stage.name().matches("[A-Z_]+"));
        }
        for (NotificationExpandDiagnostics.Reason reason : NotificationExpandDiagnostics.Reason.values()) {
            d.failure(NotificationExpandDiagnostics.reject(reason));
            check(d.reason == reason);
            check(d.reason.name().matches("[A-Z_]+"));
        }
        System.out.println("NotificationExpandDiagnostics: " + checks + " checks passed; fixed enums/numeric data only, no Android runtime/device accessed.");
    }
}
