package com.fluentplayer.audit.controls;

/** Offline JVM checks. Android constants in AuditPolicy are compile-time literals. */
public final class AuditPolicyTest {
    private static int checks;
    private static void check(boolean value) {
        checks++;
        if (!value) throw new AssertionError("Policy check " + checks + " failed");
    }
    private static void rejects(Runnable value) {
        checks++;
        try { value.run(); } catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Policy check " + checks + " should reject");
    }
    public static void main(String[] args) {
        AuditPolicy.requireTarget(null, null, null);
        AuditPolicy.requireTarget(AuditPolicy.TARGET, AuditPolicy.TARGET_PACKAGE, AuditPolicy.TARGET_RECEIVER);
        rejects(() -> AuditPolicy.requireTarget("com.example.video_player_app/anything", null, null));
        rejects(() -> AuditPolicy.requireTarget(null, "com.example.video_player_app", null));
        rejects(() -> AuditPolicy.requireTarget(null, null, "other.Receiver"));
        rejects(() -> AuditPolicy.requireTarget("", null, null));
        check(AuditPolicy.mediaKey("play") == 126);
        check(AuditPolicy.mediaKey("pause") == 127);
        check(AuditPolicy.mediaKey("next") == 87);
        check(AuditPolicy.mediaKey("previous") == 88);
        check(AuditPolicy.mediaKey("play_pause") == 85);
        rejects(() -> AuditPolicy.mediaKey(null));
        rejects(() -> AuditPolicy.mediaKey("PLAY"));
        rejects(() -> AuditPolicy.mediaKey("volume_up"));
        check(AuditPolicy.focusGain("transient") == 2);
        check(AuditPolicy.focusGain("gain") == 1);
        rejects(() -> AuditPolicy.focusGain("duck"));
        rejects(() -> AuditPolicy.focusGain(null));
        check(AuditPolicy.holdSeconds(1) == 1);
        check(AuditPolicy.holdSeconds(30) == 30);
        check(AuditPolicy.DEFAULT_HOLD_SECONDS == 5);
        rejects(() -> AuditPolicy.holdSeconds(0));
        rejects(() -> AuditPolicy.holdSeconds(-1));
        rejects(() -> AuditPolicy.holdSeconds(31));
        check("latest.xml".equals(AuditPolicy.uiDumpFilename(null)));
        check("Page1.xml".equals(AuditPolicy.uiDumpFilename("Page1.xml")));
        rejects(() -> AuditPolicy.uiDumpFilename("../latest.xml"));
        rejects(() -> AuditPolicy.uiDumpFilename("/sdcard/latest.xml"));
        rejects(() -> AuditPolicy.uiDumpFilename("..xml"));
        rejects(() -> AuditPolicy.uiDumpFilename(""));
        rejects(() -> AuditPolicy.uiDumpFilename("a b.xml"));
        rejects(() -> AuditPolicy.uiDumpFilename("a/b.xml"));
        rejects(() -> AuditPolicy.uiDumpFilename("a\\b.xml"));
        rejects(() -> AuditPolicy.uiDumpFilename("a.xml.partial"));
        rejects(() -> AuditPolicy.uiDumpFilename("A".repeat(65) + ".xml"));
        check(AuditPolicy.textInputBytes("").length == 0);
        check(AuditPolicy.textInputBytes("https://example.org/?x=1&y=2\n中文😀").length > 0);
        check(AuditPolicy.textInputBytes("a".repeat(65536)).length == 65536);
        check(AuditPolicy.textInputBytes("中".repeat(21845)).length == 65535);
        rejects(() -> AuditPolicy.textInputBytes(null));
        rejects(() -> AuditPolicy.textInputBytes("a".repeat(65537)));
        rejects(() -> AuditPolicy.textInputBytes("中".repeat(21846)));
        rejects(() -> AuditPolicy.textInputBytes("😀".repeat(16385)));
        AuditPolicy.requireTextInputPackage(AuditPolicy.TARGET_PACKAGE);
        rejects(() -> AuditPolicy.requireTextInputPackage("com.example.video_player_app"));
        rejects(() -> AuditPolicy.requireTextInputPackage("com.example.video_player_app.sidebar_profile.other"));
        rejects(() -> AuditPolicy.requireTextInputPackage("com.android.systemui"));
        rejects(() -> AuditPolicy.requireTextInputPackage(null));
        System.out.println("AuditPolicy: " + checks + " checks passed; no Android runtime/device accessed.");
    }
}
