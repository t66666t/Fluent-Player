package com.fluentplayer.audit.controls;

/** Bounded complete-tree search. Nonmatching title values are compared in RAM, never retained. */
final class NotificationTitleSearch {
    static final int MAX_NODES = 10000;
    static final int MAX_DEPTH = 80;
    static final long MAX_MS = 400;
    interface Tree<N> {
        long now();
        String viewId(N node);
        String packageName(N node);
        boolean visible(N node);
        boolean refresh(N node);
        CharSequence text(N node);
        int childCount(N node);
        N child(N node, int index);
        N retain(N node);
        void release(N node);
    }
    static final class Result<N> {
        int visited, titleFields, refreshFailures, exact;
        boolean complete = true;
        N selected;
        void close(Tree<N> tree) {
            if (selected != null) { tree.release(selected); selected = null; }
        }
    }
    static <N> Result<N> find(Tree<N> tree, N root) {
        return find(tree, root, MAX_NODES, MAX_DEPTH, MAX_MS);
    }
    static <N> Result<N> find(Tree<N> tree, N root, int maxNodes, int maxDepth, long maxMs) {
        Result<N> result = new Result<>();
        long started = tree.now();
        try {
            visit(tree, root, result, 0, maxNodes, maxDepth, maxMs, started);
            return result;
        } catch (RuntimeException error) {
            result.close(tree);
            throw error;
        }
    }
    private static <N> void visit(Tree<N> tree, N node, Result<N> result, int depth,
                                  int maxNodes, int maxDepth, long maxMs, long started) {
        if (++result.visited > maxNodes || depth > maxDepth || tree.now() - started > maxMs) {
            result.complete = false;
            return;
        }
        if (NotificationExpandPolicy.isTitleId(tree.viewId(node))
                && NotificationExpandPolicy.SYSTEM_UI.equals(tree.packageName(node))) {
            result.titleFields++;
            if (!tree.refresh(node)) {
                result.refreshFailures++;
                result.complete = false;
                return;
            }
            if (tree.visible(node)) {
                // Deliberately do not retain, log, hash or stringify nonmatching title text.
                CharSequence text = tree.text(node);
                if (text != null && NotificationExpandPolicy.TITLE.contentEquals(text)) {
                    result.exact++;
                    if (result.selected == null) result.selected = tree.retain(node);
                }
            }
        }
        int children = tree.childCount(node);
        for (int index = 0; index < children && result.complete; index++) {
            N child = tree.child(node, index);
            if (child == null) { result.complete = false; return; }
            try { visit(tree, child, result, depth + 1, maxNodes, maxDepth, maxMs, started); }
            finally { tree.release(child); }
        }
    }
}
