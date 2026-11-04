package com.fluentplayer.audit.controls;

import java.util.EnumMap;

/** Fixed stage/reason vocabulary and numeric metadata only; no framework messages. */
final class NotificationExpandDiagnostics {
    enum Stage {
        IDENTITY, ARGUMENTS, AUTOMATION, ROOT_FETCH, ROOT_REFRESH, ROOT_IDENTITY,
        TITLE_QUERY, TITLE_TREE_SCAN, TITLE_FILTER, ROW_ANCESTORS, ROW_REFRESH, ROW_VISIBILITY,
        ROW_COUNTS, ROW_GEOMETRY, SNAPSHOT_FRESHNESS, SNAPSHOT_COMPARE,
        TARGET_REFRESH, ACTION_INSPECT, ACTION_EXPAND, GESTURE_PLAN, GESTURE_INJECT, COMPLETE
    }
    enum Reason {
        OK, FRAMEWORK_EXCEPTION, HELPER_IDENTITY_REFUSED, ARGUMENTS_REFUSED,
        AUTOMATION_UNAVAILABLE, ROOT_ABSENT, ROOT_REFRESH_FAILED, ROOT_NOT_SYSTEM_UI,
        WINDOW_ID_UNAVAILABLE, TITLE_TREE_INCOMPLETE, EXACT_TITLE_NOT_UNIQUE, ROW_BOUNDARY_UNRECOGNIZED,
        ROW_REFRESH_FAILED, ROW_NOT_VISIBLE_ENABLED, ROW_WINDOW_MISMATCH,
        ROW_NOT_SINGLE_CARD, ROW_GEOMETRY_REFUSED, STALE_SNAPSHOT,
        SNAPSHOT_CHANGED, TITLE_REFRESH_FAILED, TARGET_IDENTITY_CHANGED,
        TARGET_GEOMETRY_CHANGED, EXPAND_ACTION_REFUSED, INPUT_INJECTION_REFUSED,
        GESTURE_DEADLINE_EXCEEDED
    }
    enum Counter {
        CAPTURE_ROUND, WINDOW_ID, ROOT_REFRESH_OK, QUERY_RESULTS, TITLE_ID_MATCHES,
        TITLE_REFRESH_FAILURES, EXACT_TITLES, TREE_VISITED_NODES, TREE_SCAN_COMPLETE, QUERY_FAILED,
        ANCESTOR_DEPTH, STACK_PARENT_SEEN,
        EXPLICIT_ROW_SEEN, ROW_REFRESH_OK, ROW_VISIBLE, ROW_ENABLED, TITLE_VISIBLE,
        ROW_WINDOW_MATCHES, TITLE_WINDOW_MATCHES, ROW_VISITED_NODES, ROW_TITLE_FIELDS,
        ROW_CONTENT_CONTAINERS, ROW_NESTED_ROWS, ROW_SCAN_COMPLETE, SNAPSHOT_AGE_MS
    }
    static final class Rejected extends IllegalStateException {
        final Reason reason;
        Rejected(Reason reason) { super(reason.name()); this.reason = reason; }
    }
    Stage stage = Stage.IDENTITY;
    Reason reason = Reason.OK;
    private final EnumMap<Counter, Long> values = new EnumMap<>(Counter.class);
    void number(Counter key, long value) { values.put(key, value); }
    long number(Counter key) { return values.getOrDefault(key, 0L); }
    String numericMetadata() { return values.toString(); }
    static Rejected reject(Reason reason) { return new Rejected(reason); }
    void failure(Throwable error) {
        reason = error instanceof Rejected ? ((Rejected)error).reason : Reason.FRAMEWORK_EXCEPTION;
    }
}
